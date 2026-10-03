"use strict"

const assert = require("node:assert/strict")
const fs = require("node:fs")
const path = require("node:path")
const test = require("node:test")

const IMPORTER_DIR = path.resolve(__dirname, "../ios/importer")

// 设备侧读的是编译进 dylib 的 C 表（CdnImportPlan.generated.m），人读的是 wanted-archives-ios.txt，
// 两者由 ios/importer/tools/verify-plan.mjs --emit 一次生成 —— 这里做三方一致性检查，
// 防止有人手改生成物或漏跑生成步骤，导致「计划表与清单/实体表口径不一致」。
const HEADER_PATH = path.join(IMPORTER_DIR, "CdnImportPlan.generated.h")
const SOURCE_PATH = path.join(IMPORTER_DIR, "CdnImportPlan.generated.m")
const LIST_PATH = path.join(IMPORTER_DIR, "assets/wanted-archives-ios.txt")
const PLAN_LIB_PATH = path.join(IMPORTER_DIR, "tools/plan-lib.mjs")

const ENTRY_RE = /\{\s*"((?:[^"\\]|\\.)*)",\s*"((?:[^"\\]|\\.)*)",\s*"([a-z]+)",\s*(?:"(full|diff)"|0),\s*"([0-9.]+)",\s*(0|"(?:[0-9.]+)"),\s*(\d+)ULL,\s*"([^"]+)"\s*\}/g

function parseGeneratedEntries(source) {
    const entries = []
    for (const match of source.matchAll(ENTRY_RE)) {
        entries.push({
            relativePath: match[1],
            basename: match[2],
            layer: match[3],
            kind: match[4] ?? "full",
            version: match[5],
            originalVersionRaw: match[6],
            originalVersion: match[6] === "0" ? "1.4.0" : match[6].replace(/"/g, ""),
            size: Number(match[7]),
            sha256Base64: match[8],
        })
    }
    return entries
}

function listEntries() {
    const text = fs.readFileSync(LIST_PATH, "utf8")
    return text.split("\n")
        .map(line => line.trim())
        .filter(line => line.length > 0 && !line.startsWith("#"))
}

test("生成头里的常量与 iOS 计划规模一致", () => {
    const header = fs.readFileSync(HEADER_PATH, "utf8")

    assert.match(header, /#define CDN_IMPORT_PLAN_COUNT 634U/)
    assert.match(header, /#define CDN_IMPORT_PLAN_TARGET_VERSION "1\.4\.54"/)
    assert.match(header, /#define CDN_IMPORT_PLAN_BASELINE_VERSION "1\.4\.0"/)
    assert.match(header, /#define CDN_IMPORT_PLAN_TOTAL_BYTES 10191161030ULL/)
    assert.match(header, /#define CDN_IMPORT_PLAN_TOTAL_FILES 137820U/)

    // 字段声明顺序必须与 C 表初始化顺序一一对应（CdnImportPlan.m 按名字读字段）。
    for (const field of ["relative_path", "basename", "layer", "kind", "version", "original_version", "size", "sha256_base64"]) {
        assert.ok(header.includes(field), `结构体缺少字段 ${field}`)
    }
    assert.ok(header.includes("extern const CdnImportPlanEntry gCdnImportPlan[CDN_IMPORT_PLAN_COUNT];"))
})

test("C 表有 634 条且基名/序号全部自洽", () => {
    const entries = parseGeneratedEntries(fs.readFileSync(SOURCE_PATH, "utf8"))

    assert.equal(entries.length, 634)

    const basenames = new Set()
    const relativePaths = new Set()
    let compressedBytes = 0
    const layerCounts = {}
    for (const [index, entry] of entries.entries()) {
        assert.ok(entry.basename.startsWith("pinball-"), `第 ${index} 条基名异常：${entry.basename}`)
        assert.ok(entry.basename.endsWith(".zip"))
        assert.ok(entry.relativePath.endsWith(`/${entry.basename}`), `第 ${index} 条路径与基名不符：${entry.relativePath}`)
        assert.ok(entry.relativePath.startsWith(`archive-${entry.layer}-${entry.kind}/`),
            `第 ${index} 条目录与 layer/kind 不符：${entry.relativePath}`)
        assert.ok(entry.size > 0, `第 ${index} 条 size 非正`)
        assert.ok(entry.sha256Base64.length === 44 && entry.sha256Base64.endsWith("="),
            `第 ${index} 条 sha256 不是 base64：${entry.sha256Base64}`)
        if (entry.kind === "diff") {
            assert.notEqual(entry.originalVersionRaw, "0", `第 ${index} 条 diff 缺失 original_version`)
            assert.notEqual(entry.originalVersion, entry.version, `第 ${index} 条 diff 起点与终点相同`)
        } else {
            assert.equal(entry.originalVersionRaw, "0", `第 ${index} 条 full 不应有 original_version`)
            assert.equal(entry.version, "1.4.0", `第 ${index} 条 full 归档版本不是基线：${entry.version}`)
        }
        assert.ok(!basenames.has(entry.basename), `基名重复：${entry.basename}`)
        assert.ok(!relativePaths.has(entry.relativePath), `路径重复：${entry.relativePath}`)
        basenames.add(entry.basename)
        relativePaths.add(entry.relativePath)
        compressedBytes += entry.size
        layerCounts[entry.layer] = (layerCounts[entry.layer] ?? 0) + 1
    }

    assert.deepEqual(layerCounts, { common: 401, medium: 218, ios: 15 })
    assert.equal(compressedBytes, 10748428364)
})

test("清单文件与 C 表顺序、条目完全一致", () => {
    const entries = parseGeneratedEntries(fs.readFileSync(SOURCE_PATH, "utf8"))
    const listed = listEntries()

    assert.equal(listed.length, entries.length)
    assert.deepEqual(listed, entries.map(entry => entry.relativePath))
})

test("diff 链从基线 1.4.0 连续接到目标 1.4.54", () => {
    const entries = parseGeneratedEntries(fs.readFileSync(SOURCE_PATH, "utf8"))
    const steps = new Map()
    for (const entry of entries) {
        if (entry.kind !== "diff") continue
        const key = entry.originalVersion
        const existing = steps.get(key)
        // 同一步 diff 每个 layer 各有一条归档，起点相同、终点必须相同（否则客户端 diffMap 无解）。
        assert.ok(existing === undefined || existing === entry.version,
            `diff 链出现分叉：${key} → ${existing} / ${entry.version}`)
        steps.set(key, entry.version)
    }

    const chain = []
    let version = "1.4.0"
    while (version !== "1.4.54") {
        const next = steps.get(version)
        assert.ok(next, `diff 链在 ${version} 处断裂`)
        chain.push(next)
        version = next
        assert.ok(chain.length <= 100, "diff 链疑似成环")
    }

    assert.equal(chain.length, 54)
    assert.equal(new Set(chain).size, 54)
    assert.equal(version, "1.4.54")
})

test("计划库可从 CDN 快照重建同一份计划（本机有快照时；可用 CDN_IMPORT_SNAPSHOT 指定）", async (t) => {
    const snapshotPath = process.env.CDN_IMPORT_SNAPSHOT ?? "cdn/path"
    if (!fs.existsSync(snapshotPath)) {
        t.diagnostic(`本机没有 CDN 快照（${snapshotPath}），跳过重建比对`)
        return
    }
    const { buildIosImportPlan, readJsonFile } = await import(require("node:url").pathToFileURL(PLAN_LIB_PATH).href)
    const plan = buildIosImportPlan(readJsonFile(snapshotPath), { platform: "ios" })
    const entries = parseGeneratedEntries(fs.readFileSync(SOURCE_PATH, "utf8"))

    assert.equal(plan.problems.length, 0)
    assert.equal(plan.targetVersion, "1.4.54")
    assert.equal(plan.baselineVersion, "1.4.0")
    assert.equal(plan.entries.length, entries.length)
    assert.equal(plan.totalCompressedBytes, 10748428364)
    assert.deepEqual(
        plan.entries.map(entry => `${entry.relativePath}\t${entry.size}\t${entry.sha256}`),
        entries.map(entry => `${entry.relativePath}\t${entry.size}\t${entry.sha256Base64}`),
    )
})
