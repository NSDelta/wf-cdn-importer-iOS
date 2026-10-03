#!/usr/bin/env node
/**
 * lint-objc.mjs —— ios/importer 的静态自检（在 Windows 上也能跑，无需 clang）。
 *
 * 为什么需要它：本机没有 Xcode/clang，ObjC 代码只能在 CI 上编译；这个脚本把「编译期才会发现」的
 * 一大类低级错误提前到本地：
 *   · 注释 / 字符串 / 字符字面量未闭合（跨文件串味最常见的形态）
 *   · 花括号 / 小括号 / 方括号不配对
 *   · `@interface` / `@implementation` / `@protocol` 与 `@end` 不配对
 *   · 头文件里声明了、实现文件里没实现的方法（**运行期才会炸**）
 *   · `#import "xxx.h"` 指向不存在的文件
 *   · `.m` 没有同名 `.h`（除非在 ALLOW_NO_HEADER 白名单里）
 *   · 残留的占位标记（TODO / FIXME / XXX / <#…#>）
 *
 * 用法：node ios/importer/tools/lint-objc.mjs [目录] [--quiet]
 * 退出码：0 = 干净，1 = 有问题（逐条打印）
 */

import { readdirSync, readFileSync, existsSync, statSync } from "node:fs"
import path from "node:path"
import { fileURLToPath, pathToFileURL } from "node:url"

const HERE = path.dirname(fileURLToPath(import.meta.url))
const DEFAULT_DIR = path.resolve(HERE, "..")

/// 纯构造器 / 无公开接口的实现文件，允许没有同名头文件
const ALLOW_NO_HEADER = new Set(["CdnImporterEntry.m"])

/// 定义在别处（UIKit 协议等），头文件里不会出现——不参与「声明↔实现」比对
const IGNORED_HEADERS = new Set(["CdnImportPlan.generated.h"])

/// 覆盖窗口等级上限：登录插件 SpLogin 的悬浮层是 `UIWindowLevelStatusBar + 100`，
/// 谁高谁就把球压在对方身上（README 4.1「同层规则」）。
const MAX_OVERLAY_LEVEL_OFFSET = 100

function stripCommentsAndLiterals(text, { keepLiterals = false } = {}) {
    const problems = []
    let out = ""
    let index = 0
    let line = 1
    const push = (char) => { out += char === "\n" ? "\n" : " " }
    const emit = keepLiterals ? (char) => { out += char } : push
    while (index < text.length) {
        const char = text[index]
        const next = text[index + 1]
        if (char === "\n") { line += 1; out += "\n"; index += 1; continue }
        if (char === "/" && next === "/") {                    // 行注释
            while (index < text.length && text[index] !== "\n") { push(text[index]); index += 1 }
            continue
        }
        if (char === "/" && next === "*") {                    // 块注释
            const startLine = line
            index += 2
            let closed = false
            while (index < text.length) {
                if (text[index] === "\n") line += 1
                if (text[index] === "*" && text[index + 1] === "/") { index += 2; closed = true; break }
                push(text[index]); index += 1
            }
            if (!closed) problems.push(`第 ${startLine} 行：块注释 /* 未闭合`)
            continue
        }
        if (char === '"' || char === "'") {                    // 字符串 / 字符字面量
            const quote = char
            const startLine = line
            emit(char); index += 1
            let closed = false
            while (index < text.length) {
                const inner = text[index]
                if (inner === "\\") { emit(inner); emit(text[index + 1] ?? ""); index += 2; continue }
                if (inner === "\n") break
                if (inner === quote) { emit(inner); index += 1; closed = true; break }
                emit(inner); index += 1
            }
            if (!closed) problems.push(`第 ${startLine} 行：字面量 ${quote} 未闭合`)
            continue
        }
        out += char
        index += 1
    }
    return { code: out, problems }
}

function checkPairs(code, file, problems) {
    const pairs = [["{", "}"], ["(", ")"], ["[", "]"]]
    for (const [open, close] of pairs) {
        let depth = 0
        let firstNegative = -1
        let index = 0
        let line = 1
        for (const char of code) {
            if (char === "\n") line += 1
            if (char === open) depth += 1
            else if (char === close) {
                depth -= 1
                if (depth < 0 && firstNegative < 0) firstNegative = line
            }
            index += 1
        }
        if (firstNegative > 0) problems.push(`${file}:${firstNegative} 出现多余的 ${close}`)
        if (depth !== 0) problems.push(`${file}: ${open}${close} 不配对（差 ${depth}）`)
    }
    const stack = []
    const directive = /@(interface|implementation|protocol|end)\b/g
    let match
    while ((match = directive.exec(code)) !== null) {
        const kind = match[1]
        const line = code.slice(0, match.index).split("\n").length
        if (kind === "end") {
            if (stack.length === 0) problems.push(`${file}:${line} 多余的 @end`)
            else stack.pop()
        } else {
            stack.push({ kind, line })
        }
    }
    for (const item of stack) problems.push(`${file}:${item.line} @${item.kind} 没有配对的 @end`)
}

function methodSelectorsIn(code, { includeProperties = false } = {}) {
    const selectors = []
    const lines = code.split("\n")
    let optional = false
    for (const line of lines) {
        if (/^\s*@optional\b/.test(line)) { optional = true; continue }
        if (/^\s*@required\b/.test(line)) { optional = false; continue }
        const match = /^\s*([-+])\s*\(([^)]*)\)\s*([A-Za-z_][A-Za-z0-9_]*)/.exec(line)
        if (match === null) continue
        if (optional) continue
        const returnsBlock = /\(\s*\^/.test(line) || /\^\s*\(/.test(line)
        if (returnsBlock && !includeProperties) {
            // 返回 block 的声明形如 - (void (^)(void))handler; 选择器仍可取到，正常处理
        }
        const name = match[3]
        const after = line.slice(match.index + match[0].length)
        const hasArgument = after.trimStart().startsWith(":")
        selectors.push({ name, hasArgument, line: line.trim(), isClass: match[1] === "+" })
    }
    return selectors
}

function run(directory, { quiet = false } = {}) {
    const problems = []
    const stats = { files: 0, headers: 0, implementations: 0, interfaces: 0, declaredSelectors: 0 }
    const files = readdirSync(directory)
        .filter((name) => name.endsWith(".h") || name.endsWith(".m"))
        .sort()
    const stripped = new Map()
    const scanText = new Map() // 保留字面量（#import "x.h" 的目标藏在字符串里，剥掉字面量就找不到了）
    for (const name of files) {
        const text = readFileSync(path.join(directory, name), "utf8")
        stats.files += 1
        if (name.endsWith(".h")) stats.headers += 1
        else stats.implementations += 1
        stats.interfaces += (text.match(/@(interface|implementation|protocol)\b/g) ?? []).length
        const { code, problems: literalProblems } = stripCommentsAndLiterals(text)
        for (const problem of literalProblems) problems.push(`${name}: ${problem}`)
        stripped.set(name, code)
        scanText.set(name, stripCommentsAndLiterals(text, { keepLiterals: true }).code)
        checkPairs(code, name, problems)
        if (/<#[^#]*#>/.test(text)) problems.push(`${name}: 残留 Xcode 占位符 <#…#>`)
        for (const marker of ["TODO", "FIXME", "XXX"]) {
            const line = text.split("\n").findIndex((item) => item.includes(marker))
            if (line >= 0) problems.push(`${name}:${line + 1} 残留 ${marker}`)
        }
        // 悬浮层等级纪律：绝不能高过别的悬浮插件（登录插件 SpLogin 是 UIWindowLevelStatusBar + 100）。
        // 等级高的一方会把球压在对方球身上，对方就点不动了 —— 见 ios/importer/README.md 4.1。
        for (const match of code.matchAll(/UIWindowLevelStatusBar\s*\+\s*([0-9]+(?:\.[0-9]+)?)/g)) {
            if (Number(match[1]) > MAX_OVERLAY_LEVEL_OFFSET) {
                problems.push(`${name}: windowLevel 用了 UIWindowLevelStatusBar + ${match[1]}，` +
                    `高于其它悬浮插件的 ${MAX_OVERLAY_LEVEL_OFFSET}（见 README 4.1「同层规则」）`)
            }
        }
        // 空间检查纪律：attributesOfFileSystemForPath: 对**不存在**的路径直接报错，
        // 而「清空目标目录」正好会把那个目录删掉 —— 必须先用 CdnImporterNearestExistingPath 探测。
        if (name.endsWith(".m") && code.includes("attributesOfFileSystemForPath:") &&
            !code.includes("CdnImporterNearestExistingPath")) {
            problems.push(`${name}: 用了 attributesOfFileSystemForPath: 但没有先经过 ` +
                `CdnImporterNearestExistingPath —— 目标目录不存在时这个调用会直接失败` +
                `（真机曾因此报「未能打开文件“download”，因为它不存在。」）`)
        }
        // 长循环内存纪律：每次 readAtOffset: 都产生一个 autoreleased 分块，
        // 逐条目解压十几万次却不排空 autorelease 池，就会一路攒到分配失败
        // （真机表现为 pread 拿到 NULL 缓冲区后的 EFAULT「Bad address」）。
        if (name.endsWith(".m") && code.includes("extractEntry:") &&
            !/-\s*\(BOOL\)\s*extractEntry:/.test(code) && !code.includes("@autoreleasepool")) {
            problems.push(`${name}: 调用 extractEntry: 解压却没有 @autoreleasepool —— ` +
                `逐条目的 autoreleased 分块会攒满内存、分配失败后报「读 … 失败: Bad address」`)
        }
    }

    // #import "xxx.h" 必须存在
    for (const name of files) {
        const code = scanText.get(name)
        for (const match of code.matchAll(/#\s*import\s+"([^"]+)"/g)) {
            const target = match[1]
            if (target.includes("/")) continue
            if (!existsSync(path.join(directory, target))) {
                problems.push(`${name}: #import "${target}" 指向不存在的文件`)
            }
        }
    }

    // .m 必须有同名 .h
    for (const name of files.filter((item) => item.endsWith(".m"))) {
        const header = `${name.slice(0, -2)}.h`
        if (!existsSync(path.join(directory, header)) && !ALLOW_NO_HEADER.has(name)) {
            problems.push(`${name}: 没有同名头文件 ${header}（若是纯实现文件请加进 ALLOW_NO_HEADER）`)
        }
    }

    // 声明 ↔ 实现
    const implementations = new Map()
    for (const name of files.filter((item) => item.endsWith(".m"))) {
        implementations.set(name, stripped.get(name))
    }
    const allImplementationText = [...implementations.values()].join("\n")
    for (const name of files.filter((item) => item.endsWith(".h") && !IGNORED_HEADERS.has(item))) {
        const code = stripped.get(name)
        for (const selector of methodSelectorsIn(code)) {
            stats.declaredSelectors += 1
            const needle = selector.hasArgument ? `${selector.name}:` : selector.name
            const pattern = new RegExp(`(^|[^A-Za-z0-9_])${needle.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")}`, "m")
            if (!pattern.test(allImplementationText)) {
                problems.push(`${name}: 声明的方法未在任何 .m 里实现 → ${selector.line}`)
            }
        }
    }

    // 用了类但没引入声明它的头（CI 上必炸，本地提前抓）
    checkClassImports(directory, files, stripped, scanText, problems)
    return { problems, stats }
}

/**
 * 「用了类但没引入声明它的头」检查（本机没有 clang，这一类错误只有 CI 才会暴露）。
 * 规则：文件用到的项目内类，必须由 本文件/直接或间接 import 的头/同文件的 @class 前置声明 提供。
 */
function checkClassImports(directory, files, stripped, scanText, problems) {
    const declares = new Map() // 类名 → 声明它的文件
    const forward = new Map() // 文件 → 前置声明的类名集合
    const imports = new Map() // 文件 → 直接 import 的项目头
    for (const name of files) {
        const code = scanText.get(name)
        for (const match of code.matchAll(/@\s*(?:interface|implementation)\s+([A-Za-z_][A-Za-z0-9_]*)/g)) {
            if (!declares.has(match[1])) declares.set(match[1], name)
        }
        const forwardNames = new Set()
        for (const match of code.matchAll(/@\s*(?:class|protocol)\s+([A-Za-z_][A-Za-z0-9_]*)/g)) {
            forwardNames.add(match[1])
        }
        forward.set(name, forwardNames)
        const targets = []
        for (const match of code.matchAll(/#\s*import\s+"([^"]+)"/g)) {
            if (!match[1].includes("/") && files.includes(match[1])) targets.push(match[1])
        }
        imports.set(name, targets)
    }

    const closureCache = new Map()
    const closureOf = (name, seen = new Set()) => {
        if (seen.has(name)) return seen
        seen.add(name)
        const cached = closureCache.get(name)
        if (cached) {
            // 命中缓存必须把缓存内容并进 seen：否则父文件的闭包会漏掉整棵已缓存子树
            for (const item of cached) seen.add(item)
            return seen
        }
        for (const target of imports.get(name) ?? []) closureOf(target, seen)
        closureCache.set(name, new Set(seen))
        return seen
    }

    for (const name of files) {
        const code = stripped.get(name)
        const available = new Set([name, ...closureOf(name)])
        const localForward = new Set()
        for (const reached of available) {
            for (const forwardName of forward.get(reached) ?? []) localForward.add(forwardName)
        }
        const used = new Set()
        for (const match of code.matchAll(/\[\s*([A-Z][A-Za-z0-9_]*)[\s\]]/g)) used.add(match[1])
        for (const match of code.matchAll(/(?:^|[^A-Za-z0-9_])([A-Z][A-Za-z0-9_]*)\s*\*/gm)) used.add(match[1])
        for (const className of used) {
            const declaredIn = declares.get(className)
            if (!declaredIn) continue // 系统类（NSArray/NSString…）或 C 类型，交给 clang
            if (available.has(declaredIn)) continue
            if (localForward.has(className)) continue // 只有指针/返回值的用法可以由 @class 前置声明满足
            problems.push(`${name}: 用到 ${className} 但没有（直接或间接）import 声明它的 ${declaredIn}`
                + `（在 ${name} 或其引入链里加 #import "${declaredIn}"，或加 @class ${className};）`)
        }
    }
}

function cli() {
    const args = process.argv.slice(2)
    const directory = args.find((item) => !item.startsWith("--")) ?? DEFAULT_DIR
    const quiet = args.includes("--quiet")
    if (!existsSync(directory) || !statSync(directory).isDirectory()) {
        console.error(`不是目录：${directory}`)
        process.exit(2)
    }
    const { problems, stats } = run(directory, { quiet })
    if (args.includes("--stats")) {
        console.log(`统计：${stats.files} 个文件（${stats.headers} .h / ${stats.implementations} .m），`
            + `${stats.interfaces} 个 @interface|@implementation|@protocol，头文件声明方法 ${stats.declaredSelectors} 个`)
    }
    if (problems.length === 0) {
        if (!quiet) console.log(`✓ ios/importer 静态自检通过（${directory}）`)
        process.exit(0)
    }
    console.error(`✗ ios/importer 静态自检发现 ${problems.length} 个问题：`)
    for (const problem of problems) console.error(`  · ${problem}`)
    process.exit(1)
}

export { run, stripCommentsAndLiterals, methodSelectorsIn }

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
    cli()
}
