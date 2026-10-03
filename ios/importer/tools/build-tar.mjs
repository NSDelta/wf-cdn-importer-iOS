#!/usr/bin/env node
// 把 CDN 归档打成分卷 tar，便于一次性传到设备（文件 App / SMB / iCloud Drive）。
//
// 为什么用 tar：归档本身已经是压缩态，再套一层 zip/deflate 只浪费时间；tar 可以只写 512 字节头 +
// 原样数据，设备侧导入器只读头建索引、按需 seek 取归档，**不需要先整体解包**。
//
// 用法：
//   node ios/importer/tools/build-tar.mjs --cdn ./cdn --out ./cdn-tar
//        [--snapshot <path 快照>] [--layer ios|medium|common|all] [--name ios-cdn]
//        [--volume-bytes 2000000000] [--verify-sha256] [--quiet]
//
// 产物：`<out>/<name>.tar.part.NN`（每卷 ≤ --volume-bytes，每卷长度是 512 的整数倍，只在**最后一卷**
// 末尾写两个全零块作为结束标记 —— 导入器把各卷按序号拼成一条逻辑流后再解析）。
// 另外写 `<out>/<name>.tar-manifest.json`，记录每个成员的名字/大小/sha256 与所在卷。
import { createReadStream, createWriteStream } from "node:fs"
import { mkdir, open, readFile, stat, writeFile } from "node:fs/promises"
import path from "node:path"
import { pathToFileURL } from "node:url"
import { createHash } from "node:crypto"
import { buildIosImportPlan, readJsonFile } from "./plan-lib.mjs"

const BLOCK = 512
const DEFAULT_VOLUME_BYTES = 2_000_000_000
// 默认值只是本机开发时方便，实际用 --cdn / --snapshot 指定（相对当前目录解析）
const DEFAULT_SNAPSHOT = "./cdn/path"
const DEFAULT_CDN = "./cdn"

function pad(value, size) {
    const buffer = Buffer.alloc(size, 0)
    Buffer.from(String(value), "utf8").copy(buffer, 0, 0, size)
    return buffer
}

function octal(value, size) {
    // tar 的数值字段：八进制 + 结尾 NUL（size 用 11 位 + NUL）
    const text = value.toString(8).padStart(size - 1, "0")
    return pad(text, size)
}

/** ustar 头（name ≤ 100 字节；更长的名字走 GNU 长名条目不够用，这里直接拒绝并要求改名）。 */
function tarHeader(name, size, mtimeSeconds) {
    const nameBytes = Buffer.from(name, "utf8")
    if (nameBytes.length > 100) throw new Error(`tar 成员名超过 100 字节，请改短：${name}`)
    const header = Buffer.alloc(BLOCK, 0)
    nameBytes.copy(header, 0)
    octal(0o644, 8).copy(header, 100) // mode
    octal(0, 8).copy(header, 108) // uid
    octal(0, 8).copy(header, 116) // gid
    octal(size, 12).copy(header, 124) // size
    octal(mtimeSeconds, 12).copy(header, 136) // mtime
    header.write("        ", 148, "ascii") // checksum 占位（8 空格）
    header.write("0", 156, "ascii") // typeflag：普通文件
    header.write("ustar", 257, "ascii")
    header.write("00", 263, "ascii")
    header.write("cdn", 265, "ascii") // uname
    header.write("cdn", 297, "ascii") // gname
    let sum = 0
    for (const byte of header) sum += byte
    header.write(`${sum.toString(8).padStart(6, "0")}\0 `, 148, "ascii")
    return header
}

function planEntriesForLayer(plan, layer) {
    if (!layer || layer === "all") return plan.entries
    const wanted = new Set(layer.split(",").map(item => item.trim()).filter(Boolean))
    const entries = plan.entries.filter(entry => wanted.has(entry.layer))
    if (entries.length === 0) throw new Error(`层过滤后没有条目：${layer}`)
    return entries
}

/** 打包：返回 { volumes: [...], manifest }。逐成员流式读入写出，同时算 sha256。 */
async function writeTarVolumes(options) {
    const {
        entries, cdnRoot, outDir, name, volumeBytes = DEFAULT_VOLUME_BYTES,
    } = options
    await mkdir(outDir, { recursive: true })
    const mtimeSeconds = Math.floor((options.mtime ?? Date.now()) / 1000)
    const volumes = []
    let current = null
    let currentBytes = 0
    const manifest = { name, volumeBytes, createdAt: new Date(mtimeSeconds * 1000).toISOString(), members: [] }

    const openVolume = () => {
        const index = volumes.length
        const file = path.join(outDir, `${name}.tar.part.${String(index).padStart(2, "0")}`)
        current = createWriteStream(file)
        volumes.push(file)
        currentBytes = 0
        return file
    }
    const write = async (buffer) => {
        await new Promise((resolve, reject) => {
            current.write(buffer, (error) => (error ? reject(error) : resolve()))
        })
        currentBytes += buffer.length
    }
    const writeFully = async (buffer) => {
        let offset = 0
        while (offset < buffer.length) {
            const room = volumeBytes - currentBytes
            if (room <= 0) {
                await new Promise((resolve) => current.end(resolve))
                openVolume()
                continue
            }
            const chunk = buffer.subarray(offset, offset + Math.min(room, buffer.length - offset))
            await write(chunk)
            offset += chunk.length
        }
    }

    openVolume()
    for (const entry of entries) {
        const source = path.join(cdnRoot, entry.relativePath)
        const info = await stat(source)
        if (info.size !== entry.size) {
            throw new Error(`字节数不符：${source} 实际 ${info.size}，计划 ${entry.size}`)
        }
        const memberName = entry.basename
        // 头可能与上一个成员的最后一块挤在同一卷里；头本身不跨卷（512 ≤ volumeBytes 前提）
        if (volumeBytes - currentBytes < BLOCK * 3) {
            await new Promise((resolve) => current.end(resolve))
            openVolume()
        }
        const headerOffset = currentBytes
        const headerVolume = volumes.length - 1
        await writeFully(tarHeader(memberName, info.size, mtimeSeconds))
        const hash = createHash("sha256")
        let written = 0
        const stream = createReadStream(source, { highWaterMark: 1 << 20 })
        for await (const chunk of stream) {
            hash.update(chunk)
            await writeFully(chunk)
            written += chunk.length
        }
        if (written !== info.size) throw new Error(`读取不完整：${source}`)
        const padding = (BLOCK - (info.size % BLOCK)) % BLOCK
        if (padding > 0) await writeFully(Buffer.alloc(padding, 0))
        manifest.members.push({
            name: memberName,
            basename: entry.basename,
            layer: entry.layer,
            kind: entry.kind,
            size: info.size,
            sha256: hash.digest("base64"),
            headerVolume,
            headerOffset,
        })
        if (!options.quiet) {
            process.stdout.write(`\r已写入 ${manifest.members.length}/${entries.length} 个成员，当前第 ${volumes.length} 卷（${currentBytes} B）`)
        }
    }
    // 只在最后一卷末尾写结束标记（导入器把各卷拼起来读，逐卷写会提前截断）
    await writeFully(Buffer.alloc(BLOCK * 2, 0))
    await new Promise((resolve) => current.end(resolve))
    if (!options.quiet) process.stdout.write("\n")

    const manifestPath = path.join(outDir, `${name}.tar-manifest.json`)
    await writeFile(manifestPath, `${JSON.stringify(manifest, null, 2)}\n`, "utf8")
    return { volumes, manifest, manifestPath }
}

/**
 * 回读校验：把各卷当成一条逻辑流，按 512 字节头逐成员解析（只读头 + seek 跳过数据），
 * 返回成员清单。这与设备侧 CdnConcatSource + CdnTarIndex 的做法一致。
 */
async function readTarVolumes(volumePaths, { verifySha256 = false } = {}) {
    const handles = []
    const sizes = []
    for (const volumePath of volumePaths) {
        handles.push(await open(volumePath, "r"))
        sizes.push((await stat(volumePath)).size)
    }
    const total = sizes.reduce((sum, value) => sum + value, 0)
    const locate = (offset) => {
        let remaining = offset
        for (let index = 0; index < sizes.length; index++) {
            if (remaining < sizes[index]) return { index, offset: remaining }
            remaining -= sizes[index]
        }
        return null
    }
    const readAt = async (offset, length) => {
        const where = locate(offset)
        if (!where) return Buffer.alloc(0)
        const room = Math.min(length, sizes[where.index] - where.offset)
        const buffer = Buffer.alloc(room)
        await handles[where.index].read(buffer, 0, room, where.offset)
        return buffer
    }
    const readExactly = async (offset, length) => {
        const buffer = Buffer.alloc(length)
        let filled = 0
        while (filled < length) {
            const chunk = await readAt(offset + filled, length - filled)
            if (chunk.length === 0) break
            chunk.copy(buffer, filled)
            filled += chunk.length
        }
        return buffer.subarray(0, filled)
    }

    const members = []
    let offset = 0
    let pendingLongName = null
    while (offset + BLOCK <= total) {
        const header = await readExactly(offset, BLOCK)
        if (header.length < BLOCK) break
        const allZero = header.every((byte) => byte === 0)
        if (allZero) break
        let name = header.subarray(0, 100).toString("utf8").replace(/\0.*$/, "")
        const size = Number.parseInt(header.subarray(124, 136).toString("ascii").replace(/\0.*$/, "").trim() || "0", 8)
        const typeFlag = String.fromCharCode(header[156])
        const prefix = header.subarray(345, 500).toString("utf8").replace(/\0.*$/, "")
        if (prefix) name = `${prefix}/${name}`
        if (typeFlag === "L") { // GNU 长名
            const data = await readExactly(offset + BLOCK, size)
            pendingLongName = data.toString("utf8").replace(/\0.*$/, "")
        } else if (typeFlag === "0" || typeFlag === "\0") {
            const finalName = pendingLongName ?? name
            pendingLongName = null
            const member = { name: finalName, size, headerOffset: offset }
            if (verifySha256) {
                const hash = createHash("sha256")
                let read = 0
                while (read < size) {
                    const chunk = await readAt(offset + BLOCK + read, Math.min(1 << 20, size - read))
                    if (chunk.length === 0) break
                    hash.update(chunk)
                    read += chunk.length
                }
                member.sha256 = hash.digest("base64")
            }
            members.push(member)
        }
        offset += BLOCK + Math.ceil(size / BLOCK) * BLOCK
    }
    for (const handle of handles) await handle.close()
    return { members, totalBytes: total }
}

function parseArgs(argv) {
    const options = {
        cdn: DEFAULT_CDN,
        snapshot: DEFAULT_SNAPSHOT,
        out: "",
        layer: "all",
        name: "ios-cdn",
        volumeBytes: DEFAULT_VOLUME_BYTES,
        verifySha256: false,
        quiet: false,
    }
    for (let index = 0; index < argv.length; index++) {
        const token = argv[index]
        if (!token.startsWith("--")) continue
        const key = token.slice(2)
        const inline = key.indexOf("=")
        const flag = inline === -1 ? key : key.slice(0, inline)
        const value = inline === -1 ? argv[++index] : key.slice(inline + 1)
        if (flag === "cdn") options.cdn = value
        else if (flag === "snapshot") options.snapshot = value
        else if (flag === "out") options.out = value
        else if (flag === "layer") options.layer = value
        else if (flag === "name") options.name = value
        else if (flag === "volume-bytes") options.volumeBytes = Number(value)
        else if (flag === "verify-sha256") { options.verifySha256 = true; index-- }
        else if (flag === "quiet") { options.quiet = true; index-- }
        else throw new Error(`未知参数：${token}`)
    }
    if (!options.out) throw new Error("缺少 --out <输出目录>")
    if (!Number.isFinite(options.volumeBytes) || options.volumeBytes < BLOCK * 8) {
        throw new Error("--volume-bytes 太小（至少 4096）")
    }
    return options
}

async function main() {
    const options = parseArgs(process.argv.slice(2))
    const plan = buildIosImportPlan(await readJsonFile(options.snapshot), { platform: "ios" })
    const entries = planEntriesForLayer(plan, options.layer)
    const totalBytes = entries.reduce((sum, entry) => sum + entry.size, 0)
    console.log(`计划 ${plan.entries.length} 个归档；本次打包 ${entries.length} 个（${options.layer}），`
        + `压缩态合计 ${totalBytes} 字节`)

    const result = await writeTarVolumes({
        entries,
        cdnRoot: options.cdn,
        outDir: options.out,
        name: options.name,
        volumeBytes: options.volumeBytes,
        quiet: options.quiet,
    })
    for (const volume of result.volumes) {
        const info = await stat(volume)
        console.log(`  卷 ${path.basename(volume)}：${info.size} 字节`)
    }
    console.log(`清单：${result.manifestPath}`)

    // 回读结构自检（只读头，不解数据），必要时再逐成员比对 sha256
    const index = await readTarVolumes(result.volumes, { verifySha256: options.verifySha256 })
    const problems = []
    if (index.members.length !== entries.length) {
        problems.push(`成员数不符：回读 ${index.members.length}，计划 ${entries.length}`)
    }
    for (let i = 0; i < Math.min(index.members.length, entries.length); i++) {
        const member = index.members[i]
        const expected = result.manifest.members[i]
        if (member.name !== expected.name) problems.push(`第 ${i} 个成员名不符：${member.name} ≠ ${expected.name}`)
        if (member.size !== expected.size) problems.push(`第 ${i} 个成员大小不符：${member.name}`)
        if (options.verifySha256 && member.sha256 !== expected.sha256) {
            problems.push(`第 ${i} 个成员 sha256 不符：${member.name}`)
        }
    }
    if (problems.length > 0) {
        for (const problem of problems) console.error(`✗ ${problem}`)
        process.exit(1)
    }
    console.log(`✓ 回读校验通过：${index.members.length} 个成员 / ${index.totalBytes} 字节`
        + `${options.verifySha256 ? "（含 sha256 逐成员比对）" : "（结构校验；要逐成员校验 sha256 加 --verify-sha256）"}`)
}

export { writeTarVolumes, readTarVolumes, tarHeader, parseArgs, planEntriesForLayer, BLOCK }

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
    main().catch((error) => {
        console.error(`✗ ${error.message}`)
        process.exit(1)
    })
}
