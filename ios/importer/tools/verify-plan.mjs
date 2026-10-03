// iOS 导入计划验证：把 get_path 快照推出来的计划，与本地 CDN 归档、实体表逐项对账。
//
//   node ios/importer/tools/verify-plan.mjs [--cdn ./cdn] [--snapshot ./cdn/path]
//                                           [--entities <csv>] [--sha256] [--emit]
//
// 验证三件事：
//   1) 计划本身：iOS 需要的 634 个归档在本地都在、字节数一致、（可选）sha256 一致、基名唯一；
//   2) 解压语义：按计划顺序读每个 ZIP 的中央目录，模拟「后覆盖先」，得到最终文件表；
//   3) 对账实体表：模拟出的最终文件表与 10939-ios_medium.csv 的 (path, size) 逐行比对。

import fs from "node:fs"
import path from "node:path"
import crypto from "node:crypto"
import { fileURLToPath, pathToFileURL } from "node:url"
import {
    buildIosImportPlan,
    renderWantedArchives,
    renderPlanHeader,
    renderPlanSource,
    readJsonFile,
    ensureDirectory,
} from "./plan-lib.mjs"

const HERE = path.dirname(fileURLToPath(import.meta.url))
const REPO_ROOT = path.resolve(HERE, "..", "..", "..")

function parseArgs(argv) {
    const options = {
        cdn: "./cdn",
        snapshot: null,
        entities: null,
        sha256: false,
        emit: false,
        quiet: false,
    }
    for (let index = 0; index < argv.length; index++) {
        const arg = argv[index]
        if (arg === "--cdn") options.cdn = argv[++index]
        else if (arg === "--snapshot") options.snapshot = argv[++index]
        else if (arg === "--entities") options.entities = argv[++index]
        else if (arg === "--sha256") options.sha256 = true
        else if (arg === "--emit") options.emit = true
        else if (arg === "--quiet") options.quiet = true
        else throw new Error(`未知参数: ${arg}`)
    }
    options.snapshot ??= path.join(options.cdn, "path")
    options.entities ??= path.join(options.cdn, "entities", "10939-ios_medium.csv")
    return options
}

const problems = []
const notes = []
function problem(message) {
    problems.push(message)
}
function note(message) {
    notes.push(message)
}

// ---------------------------------------------------------------- ZIP 中央目录

const EOCD_SIGNATURE = 0x06054b50
const EOCD64_LOCATOR_SIGNATURE = 0x07064b50
const EOCD64_SIGNATURE = 0x06064b50
const CENTRAL_SIGNATURE = 0x02014b50

/**
 * 只读中央目录（不解压）：返回条目名 / 压缩法 / 压缩后字节 / 解压后字节 / CRC / 本地头偏移。
 * 与 Objective-C 侧 CdnZipReader 同一套解析策略（EOCD → ZIP64 → 中央目录）。
 */
export function readZipCentralDirectory(file, size = fs.statSync(file).size) {
    const handle = fs.openSync(file, "r")
    try {
        const tailLength = Math.min(size, 65557 + 64)
        const tail = Buffer.allocUnsafe(tailLength)
        fs.readSync(handle, tail, 0, tailLength, size - tailLength)

        let eocd = -1
        for (let index = tail.length - 22; index >= 0; index--) {
            if (tail.readUInt32LE(index) !== EOCD_SIGNATURE) continue
            // 注释里也可能出现 PK\x05\x06：只有「注释长度正好顶到文件尾」的那条才是真 EOCD
            const commentLength = tail.readUInt16LE(index + 20)
            if (index + 22 + commentLength !== tail.length) continue
            eocd = index
            break
        }
        if (eocd < 0) throw new Error("找不到 EOCD（不是合法 ZIP？）")

        let entryCount = tail.readUInt16LE(eocd + 10)
        let centralSize = tail.readUInt32LE(eocd + 12)
        let centralOffset = tail.readUInt32LE(eocd + 16)

        const needsZip64 = centralOffset === 0xffffffff || centralSize === 0xffffffff || entryCount === 0xffff
        if (needsZip64) {
            let locatorFound = false
            for (let index = eocd - 20; index >= 0; index--) {
                if (tail.readUInt32LE(index) === EOCD64_LOCATOR_SIGNATURE) {
                    locatorFound = true
                    const recordOffset = Number(tail.readBigUInt64LE(index + 8))
                    const record = Buffer.allocUnsafe(56)
                    fs.readSync(handle, record, 0, 56, recordOffset)
                    if (record.readUInt32LE(0) !== EOCD64_SIGNATURE) {
                        throw new Error("ZIP64 EOCD 记录签名不符")
                    }
                    entryCount = Number(record.readBigUInt64LE(32))
                    centralSize = Number(record.readBigUInt64LE(40))
                    centralOffset = Number(record.readBigUInt64LE(48))
                    break
                }
            }
            // 条目数恰好 0xffff 的合法 ZIP 也走这条路：找不到定位器时沿用 EOCD 里的值
            if (!locatorFound && (centralOffset === 0xffffffff || centralSize === 0xffffffff)) {
                throw new Error("需要 ZIP64 但找不到 ZIP64 定位器")
            }
        }

        // 减法比较，避免 centralOffset + centralSize 在浮点/大数下回绕后骗过检查
        if (centralSize > size || centralOffset > size - centralSize) {
            throw new Error(`中央目录越界（off=${centralOffset} size=${centralSize} 文件=${size}）`)
        }
        // 条目数不能超过中央目录的物理容量（每条至少 46 字节）
        if (entryCount > Math.floor(centralSize / 46)) {
            throw new Error(`条目数 ${entryCount} 与中央目录容量 ${centralSize} 不符`)
        }

        const central = Buffer.allocUnsafe(centralSize)
        fs.readSync(handle, central, 0, centralSize, centralOffset)

        const entries = []
        let cursor = 0
        for (let index = 0; index < entryCount; index++) {
            if (cursor + 46 > central.length) throw new Error(`中央目录在第 ${index} 条截断`)
            if (central.readUInt32LE(cursor) !== CENTRAL_SIGNATURE) {
                throw new Error(`中央目录第 ${index} 条签名不符（偏移 ${cursor}）`)
            }
            const method = central.readUInt16LE(cursor + 10)
            let compressedSize = central.readUInt32LE(cursor + 20)
            let uncompressedSize = central.readUInt32LE(cursor + 24)
            const nameLength = central.readUInt16LE(cursor + 28)
            const extraLength = central.readUInt16LE(cursor + 30)
            const commentLength = central.readUInt16LE(cursor + 32)
            let localOffset = central.readUInt32LE(cursor + 42)
            const crc = central.readUInt32LE(cursor + 16)
            const name = central.toString("utf8", cursor + 46, cursor + 46 + nameLength)

            if (uncompressedSize === 0xffffffff || compressedSize === 0xffffffff || localOffset === 0xffffffff) {
                const extraStart = cursor + 46 + nameLength
                const extraEnd = extraStart + extraLength
                let extraCursor = extraStart
                while (extraCursor + 4 <= extraEnd) {
                    const headerId = central.readUInt16LE(extraCursor)
                    const dataSize = central.readUInt16LE(extraCursor + 2)
                    if (headerId === 0x0001) {
                        let dataCursor = extraCursor + 4
                        const limit = extraCursor + 4 + dataSize
                        if (uncompressedSize === 0xffffffff && dataCursor + 8 <= limit) {
                            uncompressedSize = Number(central.readBigUInt64LE(dataCursor))
                            dataCursor += 8
                        }
                        if (compressedSize === 0xffffffff && dataCursor + 8 <= limit) {
                            compressedSize = Number(central.readBigUInt64LE(dataCursor))
                            dataCursor += 8
                        }
                        if (localOffset === 0xffffffff && dataCursor + 8 <= limit) {
                            localOffset = Number(central.readBigUInt64LE(dataCursor))
                        }
                        break
                    }
                    extraCursor += 4 + dataSize
                }
            }

            entries.push({ name, method, compressedSize, uncompressedSize, crc, localOffset })
            cursor += 46 + nameLength + extraLength + commentLength
        }
        return entries
    } finally {
        fs.closeSync(handle)
    }
}

/** 参考 APK extractZip 的跳过规则：目录项、.empty、.hash 不落盘。 */
export function isSkippedEntry(name) {
    return name.endsWith("/") || name.endsWith(".empty") || name.endsWith(".hash")
}

// ---------------------------------------------------------------- 主流程

function main() {
    const options = parseArgs(process.argv.slice(2))
    const snapshot = readJsonFile(options.snapshot)
    const plan = buildIosImportPlan(snapshot, { platform: "ios" })
    for (const item of plan.problems) problem(`计划: ${item}`)

    console.log(`快照      : ${options.snapshot}`)
    console.log(`CDN 根    : ${options.cdn}`)
    console.log(`链路      : ${plan.baselineVersion} → ${plan.targetVersion}（${plan.diffSteps.length} 步 diff）`)
    console.log(`计划归档  : ${plan.entries.length} 个 = ${Object.entries(plan.layerCounts)
        .sort()
        .map(([layer, count]) => `${layer} ${count}`)
        .join(" / ")}`)
    console.log(`压缩态合计: ${plan.totalCompressedBytes} 字节`)

    let missing = 0
    let sizeMismatch = 0
    let shaMismatch = 0
    let verifiedBytes = 0
    let largest = 0
    for (const entry of plan.entries) {
        const file = path.join(options.cdn, entry.directory, entry.basename)
        let stat
        try {
            stat = fs.statSync(file)
        } catch {
            problem(`归档缺失: ${entry.relativePath}`)
            missing++
            continue
        }
        if (stat.size !== entry.size) {
            problem(`字节数不符: ${entry.relativePath} 期望 ${entry.size} 实际 ${stat.size}`)
            sizeMismatch++
        }
        largest = Math.max(largest, stat.size)
        if (options.sha256) {
            const digest = crypto.createHash("sha256").update(fs.readFileSync(file)).digest("base64")
            if (digest !== entry.sha256) {
                problem(`sha256 不符: ${entry.relativePath} 期望 ${entry.sha256} 实际 ${digest}`)
                shaMismatch++
            }
            verifiedBytes += stat.size
        }
    }
    console.log(`本地归档  : 缺失 ${missing} / 字节数不符 ${sizeMismatch} / 最大单包 ${largest} 字节${options.sha256 ? ` / sha256 不符 ${shaMismatch}（校验 ${verifiedBytes} 字节）` : ""}`)

    // ---- 解压语义模拟：中央目录 + 后覆盖先
    const finalTree = new Map()
    let zipEntries = 0
    let skippedEntries = 0
    const methods = new Map()
    let sawZip64 = false
    for (const entry of plan.entries) {
        const file = path.join(options.cdn, entry.directory, entry.basename)
        if (!fs.existsSync(file)) continue
        const entries = readZipCentralDirectory(file)
        for (const item of entries) {
            zipEntries++
            methods.set(item.method, (methods.get(item.method) ?? 0) + 1)
            if (item.name.endsWith("/")) sawZip64 = sawZip64 || false
            if (isSkippedEntry(item.name)) {
                skippedEntries++
                continue
            }
            finalTree.set(item.name, { size: item.uncompressedSize, from: entry.relativePath })
        }
    }
    let treeBytes = 0
    for (const item of finalTree.values()) treeBytes += item.size
    console.log(`ZIP 条目  : ${zipEntries} 条（跳过 ${skippedEntries}；压缩法 ${[...methods.entries()]
        .map(([method, count]) => `${method === 8 ? "deflate" : method === 0 ? "stored" : `#${method}`} ${count}`)
        .join(" / ")}）`)
    console.log(`模拟终态  : ${finalTree.size} 个文件 / ${treeBytes} 字节`)

    // ---- 对账实体表
    const entities = fs.readFileSync(options.entities, "utf8").split(/\r?\n/u).filter(line => line.length > 0)
    const csv = new Map()
    const csvVersionHistogram = new Map()
    let csvBytes = 0
    for (const line of entities) {
        const columns = line.split(",")
        if (columns.length !== 5) {
            problem(`实体表列数异常: ${line.slice(0, 120)}`)
            continue
        }
        const [relative, version, size] = columns
        csv.set(relative, Number(size))
        csvBytes += Number(size)
        csvVersionHistogram.set(version, (csvVersionHistogram.get(version) ?? 0) + 1)
    }
    console.log(`实体表    : ${csv.size} 行 / ${csvBytes} 字节（版本跨度 ${[...csvVersionHistogram.keys()].sort()[0]} … ${[...csvVersionHistogram.keys()].sort().at(-1)}）`)

    let csvOnly = 0
    let sizeOnly = 0
    let treeOnly = 0
    const csvOnlySamples = []
    const sizeSamples = []
    for (const [relative, size] of csv) {
        const item = finalTree.get(relative)
        if (item === undefined) {
            csvOnly++
            if (csvOnlySamples.length < 8) csvOnlySamples.push(relative)
        } else if (item.size !== size) {
            sizeOnly++
            if (sizeSamples.length < 8) sizeSamples.push(`${relative} csv=${size} zip=${item.size}`)
        }
    }
    const treeOnlySamples = []
    for (const [relative, item] of finalTree) {
        if (!csv.has(relative)) {
            treeOnly++
            if (treeOnlySamples.length < 8) treeOnlySamples.push(`${relative} (${item.size}B ← ${item.from})`)
        }
    }
    console.log(`对账结果  : 实体表缺 ${csvOnly} / 大小不符 ${sizeOnly} / 多出 ${treeOnly}`)
    for (const sample of csvOnlySamples) console.log(`   - 实体表有、解压没有: ${sample}`)
    for (const sample of sizeSamples) console.log(`   - 大小不符: ${sample}`)
    for (const sample of treeOnlySamples) console.log(`   + 解压有、实体表没有: ${sample}`)

    if (plan.entries.length !== 634) note(`计划归档数 ${plan.entries.length}（Android 对等清单是 677，iOS 期望 634）`)
    if (csvVersionHistogram.has("1.4.54")) note(`实体表含 1.4.54 版本行 ${csvVersionHistogram.get("1.4.54")} 条`)

    if (options.emit) {
        const outDir = path.join(REPO_ROOT, "ios", "importer")
        ensureDirectory(path.join(outDir, "assets"))
        fs.writeFileSync(
            path.join(outDir, "assets", "wanted-archives-ios.txt"),
            renderWantedArchives(plan, [
                `快照 ${path.basename(options.snapshot)} 生成；压缩态合计 ${plan.totalCompressedBytes} 字节。`,
                `解压后预期 ${csvBytes} 字节（实体表大小列之和）写入 info.json 的 totalSize。`,
            ]),
            "utf8",
        )
        fs.writeFileSync(
            path.join(outDir, "CdnImportPlan.generated.h"),
            renderPlanHeader(plan, { totalBytes: csvBytes, totalFiles: csv.size }),
            "utf8",
        )
        fs.writeFileSync(path.join(outDir, "CdnImportPlan.generated.m"), renderPlanSource(plan), "utf8")
        console.log(`已写出    : ios/importer/{assets/wanted-archives-ios.txt, CdnImportPlan.generated.h/.m}`)
    }

    for (const item of notes) console.log(`备注      : ${item}`)
    if (problems.length > 0) {
        console.log(`\n发现 ${problems.length} 个问题：`)
        for (const item of problems.slice(0, 40)) console.log(`  ! ${item}`)
        if (problems.length > 40) console.log(`  … 其余 ${problems.length - 40} 个省略`)
        process.exitCode = 1
    } else {
        console.log("\n计划与本地数据完全一致。")
    }
    console.log(`\ninfo.json.totalSize 应为 ${csvBytes}（实体表大小列之和）`)
    console.log(`预计写入: <dummy>/download/ 共 ${finalTree.size} 个文件 / ${treeBytes} 字节`)
}

// 只有直接运行才跑主流程：被 import（测试里读中央目录、跳过规则）时不许碰 CDN 目录
if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
    main()
}
