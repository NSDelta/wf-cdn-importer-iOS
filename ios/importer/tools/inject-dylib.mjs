#!/usr/bin/env node
/**
 * inject-dylib.mjs —— 非越狱注入器：往 iOS IPA 的主二进制塞一条 LC_LOAD_DYLIB，并把 dylib 放进
 * `Payload/<App>.app/Frameworks/`，最后按原属性重建 IPA。
 *
 * 为什么这样做：非越狱设备上没有任何第三方进程能写进 `com.leiting.wf` 的
 * `Library/Application Support`，唯一办法是让代码在游戏进程内运行。参考 APK 的做法（独立 App 写
 * 共享存储）在 iOS 上不成立，所以这里改走「往官方 IPA 里加一条加载命令 + 重签侧载」。
 *
 * 与 client-patch 的分工（重要）：
 *   `client-patch/build/patch-ipa.mjs` 断言「ncmds / sizeofcmds 不变」，本工具**必须最后跑**：
 *       node client-patch/build/patch-ipa.mjs --ipa <官方.ipa> --host <ip:port> --out a.ipa
 *       node ios/importer/tools/inject-dylib.mjs --ipa a.ipa --dylib CdnImporter.dylib --out b.ipa
 *   然后再由 Sideloadly 侧载（它会重签整个 bundle，包括嵌套 dylib）。
 *
 * 断言（任何一条失败即中止，不产出文件）：
 *   · 主二进制是 64 位 Mach-O，且能定位到 `Payload/<App>.app/<App>`
 *   · 新命令要占据的 72 字节在原文件里全为 0（头部余量），且不与任何 section 重叠
 *   · 写入后：文件长度不变、所有 section 偏移不变、原有 load command 逐字节不变
 *   · ncmds +1 / sizeofcmds +cmdsize，且恰好等于预期值
 *   · IPA 条目总数 +1（新增 dylib 条目），其余条目数据逐字节不变
 */

import { readFileSync, writeFileSync } from "node:fs"
import path from "node:path"
import crypto from "node:crypto"
import { pathToFileURL } from "node:url"
import { deflateRawSync } from "node:zlib"

import {
    readZipEntries,
    writeZipEntries,
    readEntryData,
    replaceEntryData,
    crc32,
} from "./lib/zip-ipa.mjs"
import { parseMachOHeader, findMainBinaryEntry, OFFICIAL_IOS_184 } from "./lib/ios-macho.mjs"

const LC_LOAD_DYLIB = 0x0c
const LC_SEGMENT_64 = 0x19
const SECTION_64_SIZE = 80
const DEFAULT_INSTALL_NAME = "@executable_path/Frameworks/CdnImporter.dylib"

// ─── 参数 ────────────────────────────────────────────────────────────────────

function parseArgs(argv) {
    const options = {
        ipa: "",
        dylib: "",
        out: "",
        app: "worldflipper",
        installName: DEFAULT_INSTALL_NAME,
        report: "",
        dryRun: false,
        quiet: false,
    }
    const wantsValue = {
        "--ipa": "ipa",
        "--dylib": "dylib",
        "--out": "out",
        "--app": "app",
        "--install-name": "installName",
        "--report": "report",
    }
    for (let index = 0; index < argv.length; index += 1) {
        const arg = argv[index]
        let key = arg
        let value = ""
        const equals = arg.indexOf("=")
        if (arg.startsWith("--") && equals > 0) {
            key = arg.slice(0, equals)
            value = arg.slice(equals + 1)
        }
        if (wantsValue[key] !== undefined) {
            if (value === "") {
                index += 1
                value = argv[index] ?? ""
            }
            options[wantsValue[key]] = value
        } else if (arg === "--dry-run") options.dryRun = true
        else if (arg === "--quiet") options.quiet = true
        else if (arg === "--help" || arg === "-h") {
            console.log(`用法：
  node ios/importer/tools/inject-dylib.mjs --ipa <输入.ipa> --dylib <CdnImporter.dylib> [选项]

选项：
  --out=<路径>            输出 IPA（默认 <输入>-cdn.ipa）
  --app=<名>              应用名（默认 worldflipper，用于定位 Payload/<名>.app/<名>）
  --install-name=<路径>   LC_LOAD_DYLIB 路径（默认 ${DEFAULT_INSTALL_NAME}）
  --report=<路径>         报告 JSON（默认 <输出>.build-report.json）
  --dry-run               只做检查与内存改写，不写文件
  --quiet                 少打印
（--key=value 与 --key value 两种写法都支持）
`)
            process.exit(0)
        } else if (arg.startsWith("--")) {
            console.error(`未知参数：${arg}（--help 看用法）`)
            process.exit(2)
        }
    }
    if (!options.ipa || !options.dylib) {
        console.error("缺少参数：--ipa 与 --dylib 都是必需的（--help 看用法）")
        process.exit(2)
    }
    return options
}

// ─── 断言与报告 ──────────────────────────────────────────────────────────────

const report = {
    tool: "ios/importer/tools/inject-dylib.mjs",
    generatedAt: new Date().toISOString(),
    input: {},
    injection: {},
    output: {},
    assertions: [],
}

function check(name, condition, detail = "") {
    const entry = { name, ok: Boolean(condition), detail: String(detail ?? "") }
    report.assertions.push(entry)
    return entry.ok
}

function require_(name, condition, detail = "") {
    if (!check(name, condition, detail)) {
        throw new Error(`断言失败：${name}${detail ? `（${detail}）` : ""}`)
    }
}

function sha256(buffer) {
    return crypto.createHash("sha256").update(buffer).digest("hex")
}

// ─── Mach-O ─────────────────────────────────────────────────────────────────

/** 遍历 LC_SEGMENT_64 的 section_64（每节 80 字节，offset 在 +48 是 uint32）。 */
function readSections(buffer, header) {
    const sections = []
    for (const command of header.commands) {
        if (command.cmd !== LC_SEGMENT_64) continue
        const nsects = buffer.readUInt32LE(command.offset + 64)
        for (let index = 0; index < nsects; index += 1) {
            const base = command.offset + 72 + index * SECTION_64_SIZE
            if (base + SECTION_64_SIZE > command.offset + command.cmdsize) break
            const sectname = buffer.toString("latin1", base, base + 16).replace(/\0.*$/s, "")
            const segname = buffer.toString("latin1", base + 16, base + 32).replace(/\0.*$/s, "")
            const size = Number(buffer.readBigUInt64LE(base + 40))
            const offset = buffer.readUInt32LE(base + 48)
            sections.push({ segname, sectname, offset, size })
        }
    }
    return sections
}

/** 已有 LC_LOAD_DYLIB 的 install name 列表。 */
function readDylibPaths(buffer, header) {
    const paths = []
    for (const command of header.commands) {
        if (command.cmd !== LC_LOAD_DYLIB && command.cmd !== 0x18 /* LC_LOAD_WEAK_DYLIB */) continue
        const nameOffset = buffer.readUInt32LE(command.offset + 8)
        const start = command.offset + nameOffset
        const end = command.offset + command.cmdsize
        paths.push(buffer.toString("latin1", start, end).replace(/\0.*$/s, ""))
    }
    return paths
}

/** 构造一条 LC_LOAD_DYLIB。 */
function buildLoadDylib(installName) {
    const nameBytes = Buffer.from(`${installName}\0`, "latin1")
    const cmdsize = (24 + nameBytes.length + 7) & ~7
    const command = Buffer.alloc(cmdsize)
    command.writeUInt32LE(LC_LOAD_DYLIB, 0)
    command.writeUInt32LE(cmdsize, 4)
    command.writeUInt32LE(24, 8)          // dylib.name.offset
    command.writeUInt32LE(0, 12)          // timestamp
    command.writeUInt32LE(0x00010000, 16) // current_version 1.0.0
    command.writeUInt32LE(0x00010000, 20) // compatibility_version 1.0.0
    nameBytes.copy(command, 24)
    return command
}

function locateMainBinary(entries, buffer, appName) {
    let mainEntry = null
    try {
        mainEntry = findMainBinaryEntry(entries, appName)
    } catch (error) {
        // 兜底：从 Info.plist 读 CFBundleExecutable
        const infoEntry = entries.find((entry) => /^Payload\/[^/]+\.app\/Info\.plist$/.test(entry.name))
        if (infoEntry) {
            const text = readEntryData(infoEntry).toString("utf8")
            const match = text.match(/<key>CFBundleExecutable<\/key>\s*<string>([^<]+)<\/string>/)
            if (match) {
                const wanted = `Payload/${appName}.app/${match[1]}`
                mainEntry = entries.find((entry) => entry.name === wanted) ?? null
            }
        }
        if (!mainEntry) throw error
    }
    const bin = readEntryData(mainEntry)
    return { mainEntry, bin }
}

// ─── 主流程 ─────────────────────────────────────────────────────────────────

function injectDylib(options) {
    const say = (line) => {
        if (!options.quiet) console.log(line)
    }
    // report 是模块级的（check/require_ 直接往里塞断言），重复调用前先清空
    report.input = {}
    report.injection = {}
    report.output = {}
    report.assertions = []

    const ipaBuffer = readFileSync(options.ipa)
    const dylibBuffer = readFileSync(options.dylib)
    const outPath = options.out || `${options.ipa.replace(/\.ipa$/i, "")}-cdn.ipa`
    const reportPath = options.report || `${outPath}.build-report.json`

    report.input = {
        ipa: path.resolve(options.ipa),
        ipaBytes: ipaBuffer.length,
        ipaSha256: sha256(ipaBuffer),
        dylib: path.resolve(options.dylib),
        dylibBytes: dylibBuffer.length,
        dylibSha256: sha256(dylibBuffer),
    }
    say(`输入 IPA：${options.ipa}（${ipaBuffer.length} B，sha256 ${report.input.ipaSha256.slice(0, 12)}…）`)
    say(`输入 dylib：${options.dylib}（${dylibBuffer.length} B，sha256 ${report.input.dylibSha256.slice(0, 12)}…）`)

    // dylib 自身也必须是 64 位 Mach-O（防止把 .a / 文本误当 dylib）
    const dylibHeader = parseMachOHeader(dylibBuffer)
    require_("dylib 是 64 位 Mach-O 动态库", dylibHeader.filetype === 6 || dylibHeader.filetype === 8,
        `filetype=${dylibHeader.filetype}（6=MH_DYLIB, 8=MH_BUNDLE）`)

    const entries = readZipEntries(ipaBuffer)
    const originalEntryCount = entries.length
    report.input.entryCount = originalEntryCount
    say(`IPA 条目：${entries.length}`)
    if (entries.length === OFFICIAL_IOS_184.entries) {
        say("条目数与官方 1.8.4 一致（3568）")
    }

    const { mainEntry, bin } = locateMainBinary(entries, ipaBuffer, options.app)
    say(`主二进制：${mainEntry.name}（${bin.length} B）`)

    const header = parseMachOHeader(bin)
    report.injection = {
        mainEntry: mainEntry.name,
        binBytes: bin.length,
        binSha256Before: sha256(bin),
        ncmdsBefore: header.ncmds,
        sizeofcmdsBefore: header.sizeofcmds,
        commandsEndBefore: header.commandsEnd,
        cryptid: header.encryption?.cryptid ?? 0,
        installName: options.installName,
        existingDylibPaths: readDylibPaths(bin, header),
    }
    require_("主二进制未加密（cryptid=0）", (header.encryption?.cryptid ?? 0) === 0,
        `cryptid=${header.encryption?.cryptid ?? 0}（加密二进制无法注入）`)

    const sections = readSections(bin, header)
    const dataOffsets = sections.filter((section) => section.size > 0 && section.offset > 0).map((section) => section.offset)
    const minSectionOffset = dataOffsets.length > 0 ? Math.min(...dataOffsets) : bin.length
    report.injection.minSectionOffset = minSectionOffset
    say(`头部：ncmds=${header.ncmds} sizeofcmds=${header.sizeofcmds} 命令区结束 @${header.commandsEnd}；`
        + `首个有数据的 section @${minSectionOffset}（余量 ${minSectionOffset - header.commandsEnd} B）`)

    const loadDylib = buildLoadDylib(options.installName)
    const insertOffset = header.commandsEnd
    const insertEnd = insertOffset + loadDylib.length
    const already = report.injection.existingDylibPaths.includes(options.installName)

    require_("有足够的头部余量放新命令",
        already || minSectionOffset >= insertEnd,
        `需要到 @${insertEnd}，首个 section @${minSectionOffset}`)

    if (!already) {
        const slack = bin.subarray(insertOffset, insertEnd)
        const firstNonZero = slack.findIndex((byte) => byte !== 0)
        require_(`待写入的 ${loadDylib.length} 字节余量全为 0`,
            firstNonZero === -1,
            firstNonZero === -1
                ? `余量 @${insertOffset}..${insertEnd - 1} 全为 0`
                : `首个非零字节 @${insertOffset + firstNonZero}`)
    }

    // ─── 改写主二进制 ───
    const beforeCommands = Buffer.from(bin.subarray(32, header.commandsEnd))
    const beforeSections = JSON.stringify(sections)
    const beforeLength = bin.length

    if (already) {
        say("主二进制里已存在同路径的 LC_LOAD_DYLIB，跳过加载命令写入（幂等）")
        report.injection.skipped = "existing-load-command"
    } else {
        loadDylib.copy(bin, insertOffset)
        bin.writeUInt32LE(header.ncmds + 1, 16)
        bin.writeUInt32LE(header.sizeofcmds + loadDylib.length, 20)
        say(`写入 LC_LOAD_DYLIB：cmdsize=${loadDylib.length} @${insertOffset}，`
            + `ncmds ${header.ncmds} → ${header.ncmds + 1}，sizeofcmds ${header.sizeofcmds} → ${header.sizeofcmds + loadDylib.length}`)
    }

    const after = parseMachOHeader(bin)
    const afterSections = readSections(bin, after)
    report.injection.ncmdsAfter = after.ncmds
    report.injection.sizeofcmdsAfter = after.sizeofcmds
    report.injection.binSha256After = sha256(bin)

    require_("文件长度不变", bin.length === beforeLength, `${beforeLength} → ${bin.length}`)
    require_("原有 load command 逐字节不变",
        Buffer.from(bin.subarray(32, header.commandsEnd)).equals(beforeCommands))
    require_("所有 section 偏移/尺寸不变", JSON.stringify(afterSections) === beforeSections)
    require_("ncmds 与预期一致", after.ncmds === (already ? header.ncmds : header.ncmds + 1),
        `${header.ncmds} → ${after.ncmds}`)
    require_("sizeofcmds 与预期一致",
        after.sizeofcmds === (already ? header.sizeofcmds : header.sizeofcmds + loadDylib.length),
        `${header.sizeofcmds} → ${after.sizeofcmds}`)
    require_("新命令位于命令区末尾且可解析",
        after.commands[after.commands.length - 1].offset + after.commands[after.commands.length - 1].cmdsize === after.commandsEnd)
    require_("install name 可读回",
        readDylibPaths(bin, after).includes(options.installName))

    // ─── dylib 条目 ───
    // dyld 是按 LC_LOAD_DYLIB 里的路径去找文件的，所以条目名必须跟 install name 对齐；
    // 直接把本地文件名搬进包里的话，注入出来的 IPA 一启动就会 "Library not loaded"。
    const appDir = path.posix.dirname(mainEntry.name)
    const executablePrefix = "@executable_path/"
    const relativeToApp = options.installName.startsWith(executablePrefix)
        ? options.installName.slice(executablePrefix.length)
        : `Frameworks/${path.posix.basename(options.installName)}`
    const dylibEntryName = `${appDir}/${relativeToApp}`
    const uploadBaseName = path.basename(options.dylib)
    if (uploadBaseName !== path.posix.basename(dylibEntryName)) {
        say(`注意：dylib 文件名是 ${uploadBaseName}，但 install name 指向 ${dylibEntryName}，`
            + "条目按 install name 命名（否则启动时 dyld 找不到该库）")
    }
    report.injection.dylibUploadName = uploadBaseName
    const existingEntry = entries.find((entry) => entry.name === dylibEntryName)
    if (existingEntry) {
        replaceEntryData(entries, dylibEntryName, dylibBuffer)
        say(`替换已有条目：${dylibEntryName}`)
    } else {
        const raw = deflateRawSync(dylibBuffer, { level: 9 })
        const entry = {
            name: dylibEntryName,
            method: 8,
            flags: 0,
            mtime: mainEntry.mtime,
            mdate: mainEntry.mdate,
            crc: crc32(dylibBuffer),
            csize: raw.length,
            usize: dylibBuffer.length,
            versionMadeBy: mainEntry.versionMadeBy,
            // 0o100755 << 16 会溢出成负数（JS 位运算是 int32），改乘法再 >>> 0
            externalAttr: (((0o100755 * 0x10000) | (mainEntry.externalAttr & 0xffff)) >>> 0),
            raw,
        }
        const insertAt = entries.indexOf(mainEntry) + 1
        entries.splice(insertAt, 0, entry)
        say(`新增条目：${dylibEntryName}（deflate ${raw.length} B → ${dylibBuffer.length} B，mode 0755）`)
    }
    report.injection.dylibEntryName = dylibEntryName

    // 主二进制条目按原方法重新压缩
    replaceEntryData(entries, mainEntry.name, bin)
    report.injection.mainEntryCompressedAfter = entries.find((entry) => entry.name === mainEntry.name).raw.length

    require_("IPA 条目数符合预期",
        entries.length === (existingEntry ? originalEntryCount : originalEntryCount + 1),
        `${originalEntryCount} → ${entries.length}`)

    const outBuffer = writeZipEntries(entries)
    report.output = {
        path: path.resolve(outPath),
        bytes: outBuffer.length,
        sha256: sha256(outBuffer),
        entryCount: entries.length,
        sizeDelta: outBuffer.length - ipaBuffer.length,
    }

    // 回读校验：重建后的 zip 能被解析，且主二进制与 dylib 都能取出并与内存一致
    const reread = readZipEntries(outBuffer)
    require_("重建后的 IPA 可解析", reread.length === entries.length, `${reread.length} vs ${entries.length}`)
    const rereadMain = reread.find((entry) => entry.name === mainEntry.name)
    require_("回读主二进制与内存一致", readEntryData(rereadMain).equals(bin))
    const rereadDylib = reread.find((entry) => entry.name === dylibEntryName)
    require_("回读 dylib 与输入一致", readEntryData(rereadDylib).equals(dylibBuffer))
    const otherChanged = entries.filter((entry) =>
        entry.name !== mainEntry.name && entry.name !== dylibEntryName
        && !readEntryData(reread.find((item) => item.name === entry.name)).equals(readEntryData(entry)))
    require_("其余条目内容不变", otherChanged.length === 0, otherChanged.map((entry) => entry.name).join(", "))

    for (const assertion of report.assertions) {
        say(`${assertion.ok ? "✓" : "✗"} ${assertion.name}${assertion.detail ? ` — ${assertion.detail}` : ""}`)
    }

    if (options.dryRun) {
        say(`--dry-run：未写出文件（将写出 ${outPath}，${outBuffer.length} B）`)
    } else {
        writeFileSync(outPath, outBuffer)
        writeFileSync(reportPath, `${JSON.stringify(report, null, 2)}\n`)
        say(`已写出：${outPath}（${outBuffer.length} B，Δ${report.output.sizeDelta >= 0 ? "+" : ""}${report.output.sizeDelta} B）`)
        say(`报告：${reportPath}`)
    }
    say("下一步：用 Sideloadly 侧载该 IPA（它会重签整个 bundle，包含新加的嵌套 dylib）。")
    return { report, outBuffer, outPath, reportPath, dryRun: Boolean(options.dryRun) }
}

function main() {
    injectDylib(parseArgs(process.argv.slice(2)))
}

export { parseArgs, injectDylib, buildLoadDylib, readSections, DEFAULT_INSTALL_NAME }

// 仅当作为 CLI 直接运行时才执行（被测试 import 时不跑）
if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
    main()
}
