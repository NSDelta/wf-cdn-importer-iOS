// iOS CDN 导入计划：从 /asset/get_path 快照推导「按序解压」的归档清单。
//
// 这是 iOS 导入器的**权威计划来源**：客户端 AS3 的做法是
//   full.archive[]（基线版本，1.4.0） + 从 full.version 沿 diffMap 累加到 eventual_target_asset_version
// 后解压的同名文件覆盖先解压的（见 docs/cdn/client-flow.md）。
// 参考 APK 的 assets/wanted-archives.txt 就是这套链路的冻结版（Android 层），本模块产出 iOS 层版本。
//
// 平台过滤：iOS 设备只吃 archive-{common,medium,ios}-*，永不回退 archive-android-*（见 src/content/cdn/ios-compat.ts）。

import fs from "node:fs"
import path from "node:path"

/** 归档目录名 → 层。 */
export function layerOfArchiveDirectory(directory) {
    if (directory === "archive-common-full" || directory === "archive-common-diff") return "common"
    if (directory === "archive-medium-full" || directory === "archive-medium-diff") return "medium"
    if (directory === "archive-ios-full" || directory === "archive-ios-diff") return "ios"
    if (directory === "archive-android-full" || directory === "archive-android-diff") return "android"
    throw new Error(`未知归档目录: ${directory}`)
}

/**
 * 从归档的完整 URL 取「相对路径」= `<archive-dir>/<file>.zip`。
 * get_path 的条目只有 location（完整 URL），没有 name 字段。
 */
export function archiveRelativePathOf(location) {
    const cleaned = String(location).split("?")[0].split("#")[0]
    const match = /(archive-[a-z]+-(?:full|diff))\/[^/]+$/.exec(cleaned)
    if (match === null) throw new Error(`不是归档 URL: ${location}`)
    const file = cleaned.slice(cleaned.lastIndexOf("/") + 1)
    return `${match[1]}/${file}`
}

/** 归档的基名（服务端/文件 App 里用户看到的名字）。 */
export function archiveBasenameOf(relativePath) {
    return relativePath.slice(relativePath.lastIndexOf("/") + 1)
}

/**
 * 把 get_path 快照折成 iOS 的按序归档清单。
 *
 * @param {any} snapshot /asset/get_path 响应对象
 * @param {{ platform?: string }} [options] 平台（缺省 ios）
 * @returns {{ entries: Array<{ order: number, relativePath: string, basename: string, directory: string,
 *            layer: string, kind: "full" | "diff", size: number, sha256: string, version: string,
 *            originalVersion: string | null }>, problems: string[], baselineVersion: string,
 *            targetVersion: string, totalCompressedBytes: number, layerCounts: Record<string, number> }}
 */
export function buildIosImportPlan(snapshot, options = {}) {
    const platform = options.platform ?? "ios"
    const problems = []
    const info = snapshot?.info ?? {}
    const full = snapshot?.full
    if (full === undefined || !Array.isArray(full.archive)) throw new Error("快照缺少 full.archive")
    const diffs = Array.isArray(snapshot?.diff) ? snapshot.diff : []

    const baselineVersion = String(full.version ?? info.latest_maj_first_version ?? "")
    const targetVersion = String(info.eventual_target_asset_version ?? info.target_asset_version ?? "")

    const wanted = new Set([platform, "common", "medium"])
    const entries = []

    const push = (kind, version, originalVersion, raw) => {
        const relativePath = archiveRelativePathOf(raw.location)
        const directory = relativePath.slice(0, relativePath.indexOf("/"))
        const layer = layerOfArchiveDirectory(directory)
        if (!wanted.has(layer)) return
        entries.push({
            order: entries.length,
            relativePath,
            basename: archiveBasenameOf(relativePath),
            directory,
            layer,
            kind,
            size: Number(raw.size ?? 0),
            sha256: String(raw.sha256 ?? ""),
            version,
            originalVersion,
        })
    }

    for (const raw of full.archive) push("full", baselineVersion, null, raw)

    // diff 列表在快照里是**乱序**的（按 server 存储顺序），必须自己按 original_version 串链。
    const byOriginal = new Map()
    for (const step of diffs) {
        const key = String(step.original_version)
        if (byOriginal.has(key)) problems.push(`diff 链有重复起点: ${key}`)
        byOriginal.set(key, step)
    }
    const chain = []
    const seen = new Set()
    let cursor = baselineVersion
    while (cursor !== targetVersion) {
        if (seen.has(cursor)) {
            problems.push(`diff 链成环于 ${cursor}`)
            break
        }
        seen.add(cursor)
        const step = byOriginal.get(cursor)
        if (step === undefined) {
            problems.push(`diff 链断裂：没有 ${cursor} → ? 的步骤（目标 ${targetVersion} 不可达）`)
            break
        }
        chain.push(step)
        cursor = String(step.version)
    }
    if (chain.length !== diffs.length) {
        problems.push(`diff 链只用到 ${chain.length}/${diffs.length} 步（有多余或不可达的步骤）`)
    }
    for (const step of chain) {
        for (const raw of step.archive ?? []) push("diff", String(step.version), String(step.original_version), raw)
    }

    const layerCounts = {}
    let totalCompressedBytes = 0
    for (const entry of entries) {
        layerCounts[entry.layer] = (layerCounts[entry.layer] ?? 0) + 1
        totalCompressedBytes += entry.size
    }

    const seenBasenames = new Map()
    for (const entry of entries) {
        const previous = seenBasenames.get(entry.basename)
        if (previous !== undefined) problems.push(`基名冲突: ${entry.basename} 同时出现在 ${previous} 与 ${entry.relativePath}`)
        seenBasenames.set(entry.basename, entry.relativePath)
    }

    return {
        entries,
        problems,
        baselineVersion,
        targetVersion,
        totalCompressedBytes,
        layerCounts,
        diffSteps: chain.map(step => ({ originalVersion: String(step.original_version), version: String(step.version) })),
    }
}

/** 计划清单文本（与参考 APK 的 assets/wanted-archives.txt 同格式，多一行版本头注释）。 */
export function renderWantedArchives(plan, extraHeaderLines = []) {
    const lines = [
        `# iOS CDN 导入计划：基线 ${plan.baselineVersion} → 目标 ${plan.targetVersion}`,
        `# 共 ${plan.entries.length} 个归档：${Object.entries(plan.layerCounts).map(([k, v]) => `${k} ${v}`).join(" / ")}`,
        `# 压缩态合计 ${plan.totalCompressedBytes} 字节；按序解压，后解压的同名文件覆盖先解压的。`,
        `# 不在本清单里的归档（android 层等）导入时会被跳过。`,
        ...extraHeaderLines.map(line => `# ${line}`),
        "",
    ]
    for (const entry of plan.entries) lines.push(entry.relativePath)
    lines.push("")
    return lines.join("\n")
}

/**
 * 计划表 → C 头文件（dylib 内嵌，避免依赖运行时文件）。
 * totals = { totalBytes, totalFiles }：完整导入后的终态规模（实体表 size 列之和 / 行数），
 * 用于 info.json.totalSize 与设备侧自检。
 */
export function renderPlanHeader(plan, totals = {}) {
    const totalBytes = Number.isFinite(totals.totalBytes) ? totals.totalBytes : 0
    const totalFiles = Number.isFinite(totals.totalFiles) ? totals.totalFiles : 0
    return [
        "// 由 ios/importer/tools/verify-plan.mjs --emit 生成，请勿手改。",
        "// 计划来源：/asset/get_path 快照（iOS 视图）+ 客户端 diff 链推导。",
        "#ifndef CDN_IMPORT_PLAN_GENERATED_H",
        "#define CDN_IMPORT_PLAN_GENERATED_H",
        "",
        "#include <stdint.h>",
        "",
        "typedef struct {",
        "    const char *relative_path;",
        "    const char *basename;",
        "    const char *layer;",
        "    const char *kind;",
        "    const char *version;",
        "    const char *original_version;",
        "    uint64_t size;",
        "    const char *sha256_base64;",
        "} CdnImportPlanEntry;",
        "",
        `#define CDN_IMPORT_PLAN_TARGET_VERSION "${plan.targetVersion}"`,
        `#define CDN_IMPORT_PLAN_BASELINE_VERSION "${plan.baselineVersion}"`,
        `#define CDN_IMPORT_PLAN_COUNT ${plan.entries.length}U`,
        "",
        "// 完整导入后的终态规模（实体表 size 列之和 / 行数），用于 info.json.totalSize 与自检。",
        `#define CDN_IMPORT_PLAN_TOTAL_BYTES ${totalBytes}ULL`,
        `#define CDN_IMPORT_PLAN_TOTAL_FILES ${totalFiles}U`,
        "",
        "extern const CdnImportPlanEntry gCdnImportPlan[CDN_IMPORT_PLAN_COUNT];",
        "",
        "#endif",
        "",
    ].join("\n")
}

function cString(value) {
    return `"${String(value).replace(/\\/g, "\\\\").replace(/"/g, '\\"')}"`
}

/** 计划表 → C 源文件。 */
export function renderPlanSource(plan) {
    const rows = plan.entries.map(entry => [
        "    { ",
        cString(entry.relativePath),
        ", ",
        cString(entry.basename),
        ", ",
        cString(entry.layer),
        ", ",
        cString(entry.kind),
        ", ",
        cString(entry.version),
        ", ",
        entry.originalVersion === null ? "0" : cString(entry.originalVersion),
        ", ",
        `${entry.size}ULL`,
        ", ",
        cString(entry.sha256),
        " },",
    ].join(""))
    return [
        "// 由 ios/importer/tools/verify-plan.mjs --emit 生成，请勿手改。",
        `#include "CdnImportPlan.generated.h"`,
        "",
        "const CdnImportPlanEntry gCdnImportPlan[CDN_IMPORT_PLAN_COUNT] = {",
        ...rows,
        "};",
        "",
    ].join("\n")
}

export function readJsonFile(file) {
    return JSON.parse(fs.readFileSync(file, "utf8"))
}

export function ensureDirectory(directory) {
    fs.mkdirSync(directory, { recursive: true })
}

export function resolveWorkspaceRoot(fromUrl) {
    return path.resolve(path.dirname(fromUrl.replace(/^file:\/\//u, "")), "..", "..")
}
