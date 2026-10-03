#!/usr/bin/env node
// 合成迷你 IPA：给「注入器端到端验证」用。
//
// 为什么需要它：官方 iOS-1.8.4.ipa 有 139MB 且是版权数据，不能进仓库、也不该进 CI；
// 而注入器只关心「主二进制头部余量 + zip 结构」，所以用一个小号合成包就能覆盖同样的路径。
// 生成的包结构与真包同形：Payload/<App>.app/<App> + Info.plist。
//
// 用法：
//   node ios/importer/tools/make-mini-ipa.mjs --out out/tools/mini.ipa [--app TestApp]
//        [--text-offset 0x4000] [--total-size 0x8000] [--pad-byte 0x00]
//
// 主二进制形态：Mach-O 64（arm64）+ 1 条 LC_SEGMENT_64（含 1 个 section_64）。
//   - sizeofcmds = 72(segment_command_64) + 80(section_64) = 152 ⇒ 命令区结束 @184
//   - section_64 的 offset 决定「首个有数据的 section」位置 ⇒ 头部余量 = textOffset - 184
//   - [184, textOffset) 必须是 0（注入器会把新的 LC_LOAD_DYLIB 写在这一段里）
import { mkdirSync, writeFileSync } from "node:fs"
import path from "node:path"
import { pathToFileURL } from "node:url"
import { crc32, writeZipEntries } from "./lib/zip-ipa.mjs"

const MH_MAGIC_64 = 0xfeedfacf
const CPU_TYPE_ARM64 = 0x0100000c
const MH_EXECUTE = 2
const LC_SEGMENT_64 = 0x19
const SEGMENT_COMMAND_SIZE = 72
const SECTION_64_SIZE = 80
const SEGMENT_WITH_ONE_SECTION = SEGMENT_COMMAND_SIZE + SECTION_64_SIZE
const COMMANDS_END = 32 + SEGMENT_WITH_ONE_SECTION

function parseInteger(text, fallback) {
    if (text === undefined) return fallback
    const value = Number(text.startsWith("0x") || text.startsWith("0X") ? Number.parseInt(text.slice(2), 16) : Number(text))
    if (!Number.isFinite(value) || value <= 0) throw new Error(`不是合法的正整数：${text}`)
    return value
}

function buildMachO({ textOffset, totalSize, padByte }) {
    const buffer = Buffer.alloc(totalSize, padByte)
    // 段内容先填：头部与命令随后覆盖，保证命令区不残留段模式的字节
    for (let index = textOffset; index < buffer.length; index++) buffer[index] = (index * 31 + 7) & 0xff

    buffer.writeUInt32LE(MH_MAGIC_64, 0)
    buffer.writeUInt32LE(CPU_TYPE_ARM64, 4)
    buffer.writeUInt32LE(0, 8)
    buffer.writeUInt32LE(MH_EXECUTE, 12)
    buffer.writeUInt32LE(1, 16) // ncmds
    buffer.writeUInt32LE(SEGMENT_WITH_ONE_SECTION, 20) // sizeofcmds
    buffer.writeUInt32LE(0x00200085, 24)
    buffer.writeUInt32LE(0, 28)

    const segment = 32
    buffer.writeUInt32LE(LC_SEGMENT_64, segment)
    buffer.writeUInt32LE(SEGMENT_WITH_ONE_SECTION, segment + 4)
    buffer.write("__TEXT", segment + 8, "ascii")
    buffer.writeBigUInt64LE(0x100000000n, segment + 24) // vmaddr
    buffer.writeBigUInt64LE(BigInt(textOffset), segment + 32) // vmsize
    buffer.writeBigUInt64LE(0n, segment + 40) // fileoff
    buffer.writeBigUInt64LE(BigInt(totalSize), segment + 48) // filesize
    buffer.writeUInt32LE(7, segment + 56) // maxprot
    buffer.writeUInt32LE(5, segment + 60) // initprot
    buffer.writeUInt32LE(1, segment + 64) // nsects
    buffer.writeUInt32LE(0, segment + 68)

    const section = segment + SEGMENT_COMMAND_SIZE
    buffer.write("__text", section, "ascii")
    buffer.write("__TEXT", section + 16, "ascii")
    buffer.writeBigUInt64LE(0x100000000n + BigInt(textOffset), section + 32) // addr
    buffer.writeBigUInt64LE(BigInt(totalSize - textOffset), section + 40) // size
    buffer.writeUInt32LE(textOffset, section + 48) // offset（uint32！）
    buffer.writeUInt32LE(2, section + 52) // align
    buffer.writeUInt32LE(0, section + 56)
    buffer.writeUInt32LE(0, section + 60)
    buffer.writeUInt32LE(0x80000400, section + 64)
    buffer.writeUInt32LE(0, section + 68)
    buffer.writeUInt32LE(0, section + 72)
    buffer.writeUInt32LE(0, section + 76)

    if (textOffset < COMMANDS_END) {
        throw new Error(`textOffset(${textOffset}) 必须 >= 命令区结束(${COMMANDS_END})，否则合成包自身就不合法`)
    }
    return buffer
}

function storedEntry(name, data, mode) {
    return {
        name,
        method: 0,
        flags: 0,
        mtime: 0x4c7c,
        mdate: 0x5b09,
        crc: crc32(data),
        csize: data.length,
        usize: data.length,
        versionMadeBy: 0x031e,
        externalAttr: ((0o100000 | mode) * 0x10000) >>> 0,
        raw: Buffer.from(data),
    }
}

function infoPlist(executable) {
    return Buffer.from([
        "<?xml version=\"1.0\" encoding=\"UTF-8\"?>",
        "<!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" \"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">",
        "<plist version=\"1.0\">",
        "<dict>",
        "    <key>CFBundleExecutable</key>",
        `    <string>${executable}</string>`,
        "    <key>CFBundleIdentifier</key>",
        `    <string>com.example.${executable.toLowerCase()}</string>`,
        "    <key>CFBundleName</key>",
        `    <string>${executable}</string>`,
        "    <key>CFBundleShortVersionString</key>",
        "    <string>1.0.0</string>",
        "</dict>",
        "</plist>",
        "",
    ].join("\n"), "utf8")
}

function parseArgs(argv) {
    const options = { app: "TestApp", textOffset: 0x4000, totalSize: 0x8000, padByte: 0, out: "" }
    for (let index = 0; index < argv.length; index++) {
        const token = argv[index]
        if (!token.startsWith("--")) continue
        const key = token.slice(2)
        const inline = key.indexOf("=")
        const name = inline === -1 ? key : key.slice(0, inline)
        const value = inline === -1 ? argv[++index] : key.slice(inline + 1)
        if (name === "out") options.out = value
        else if (name === "app") options.app = value
        else if (name === "text-offset") options.textOffset = parseInteger(value, 0x4000)
        else if (name === "total-size") options.totalSize = parseInteger(value, 0x8000)
        else if (name === "pad-byte") options.padByte = Number(value) & 0xff
        else throw new Error(`未知参数：${token}`)
    }
    if (!options.out) throw new Error("缺少 --out <输出 ipa 路径>")
    if (options.totalSize <= options.textOffset) throw new Error("--total-size 必须大于 --text-offset")
    return options
}

function makeMiniIpa(options) {
    const executable = buildMachO({
        textOffset: options.textOffset,
        totalSize: options.totalSize,
        padByte: options.padByte,
    })
    const directory = `Payload/${options.app}.app`
    const entries = [
        storedEntry(`${directory}/${options.app}`, executable, 0o755),
        storedEntry(`${directory}/Info.plist`, infoPlist(options.app), 0o644),
        storedEntry(`${directory}/en.lproj/InfoPlist.strings`, Buffer.from("\"CFBundleName\" = \"Test\";\n", "utf8"), 0o644),
    ]
    const buffer = writeZipEntries(entries)
    mkdirSync(path.dirname(path.resolve(options.out)), { recursive: true })
    writeFileSync(options.out, buffer)
    return {
        out: path.resolve(options.out),
        bytes: buffer.length,
        entryCount: entries.length,
        commandsEnd: COMMANDS_END,
        headroom: options.textOffset - COMMANDS_END,
    }
}

function main() {
    const summary = makeMiniIpa(parseArgs(process.argv.slice(2)))
    console.log(`✓ 合成迷你 IPA：${summary.out}`)
    console.log(`  ${summary.bytes} 字节 / ${summary.entryCount} 个条目；命令区结束 @${summary.commandsEnd}，头部余量 ${summary.headroom} 字节`)
}

export { makeMiniIpa, parseArgs, buildMachO, COMMANDS_END }

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) main()
