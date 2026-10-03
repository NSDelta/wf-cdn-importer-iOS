"use strict"

const assert = require("node:assert/strict")
const fs = require("node:fs")
const os = require("node:os")
const path = require("node:path")
const test = require("node:test")
const { pathToFileURL } = require("node:url")

// iOS 导入器（ios/importer）是纯 ObjC 工程，本机没有 Xcode，编译只能发生在 CI 的 macOS 上。
// 因此把「编译期才会暴露」的低级错误提前到静态自检里，并在这里保证自检本身没坏。
const IMPORTER_DIR = path.resolve(__dirname, "../ios/importer")
const LINT_URL = pathToFileURL(path.join(IMPORTER_DIR, "tools/lint-objc.mjs")).href

async function loadLint() {
    const module = await import(LINT_URL)
    return module.run
}

test("ios/importer 的 ObjC 源码通过静态自检", async () => {
    const run = await loadLint()
    const { problems, stats } = run(IMPORTER_DIR, { quiet: true })

    assert.deepEqual(problems, [])
    assert.ok(stats.files >= 20, `参与自检的文件太少：${stats.files}`)
    assert.ok(stats.headers >= 10, `头文件太少：${stats.headers}`)
    assert.ok(stats.interfaces >= 40, `@interface/@implementation 太少：${stats.interfaces}`)
    assert.ok(stats.declaredSelectors >= 20, `头文件声明的方法太少：${stats.declaredSelectors}`)
})

test("静态自检能抓出未闭合注释、未实现方法与缺失头文件", async () => {
    const run = await loadLint()
    const dir = fs.mkdtempSync(path.join(os.tmpdir(), "cdn-lint-bad-"))
    try {
        fs.writeFileSync(path.join(dir, "Bad.h"), [
            "#import <Foundation/Foundation.h>",
            "",
            "@interface Bad : NSObject",
            "- (void)declaredButMissing;",
            "@end",
            "",
        ].join("\n"))
        fs.writeFileSync(path.join(dir, "Bad.m"), [
            "#import \"Bad.h\"",
            "",
            "@implementation Bad",
            "/* 未闭合的块注释",
            "@end",
            "",
        ].join("\n"))
        fs.writeFileSync(path.join(dir, "Orphan.m"), [
            "@implementation Orphan",
            "@end",
            "",
        ].join("\n"))

        const { problems } = run(dir, { quiet: true })
        const text = problems.join("\n")

        assert.match(text, /块注释 \/\* 未闭合/)
        assert.match(text, /声明的方法未在任何 \.m 里实现/)
        assert.match(text, /没有同名头文件 Orphan\.h/)
    } finally {
        fs.rmSync(dir, { recursive: true, force: true })
    }
})

test("静态自检能抓出「窗口等级压过别的悬浮插件」", async () => {
    const run = await loadLint()
    const dir = fs.mkdtempSync(path.join(os.tmpdir(), "cdn-lint-level-"))
    try {
        fs.writeFileSync(path.join(dir, "Overlay.h"), [
            "#import <Foundation/Foundation.h>",
            "",
            "@interface Overlay : NSObject",
            "@end",
            "",
        ].join("\n"))
        fs.writeFileSync(path.join(dir, "Overlay.m"), [
            "#import \"Overlay.h\"",
            "#import <UIKit/UIKit.h>",
            "",
            "@implementation Overlay",
            "- (void)raise {",
            "    self.window.windowLevel = UIWindowLevelStatusBar + 120.0;",
            "}",
            "@end",
            "",
        ].join("\n"))

        const { problems } = run(dir, { quiet: true })
        assert.match(problems.join("\n"), /高于其它悬浮插件的 100/)
    } finally {
        fs.rmSync(dir, { recursive: true, force: true })
    }
})

test("静态自检能抓出「读可用空间前没有先找已存在目录」", async () => {
    const run = await loadLint()
    const dir = fs.mkdtempSync(path.join(os.tmpdir(), "cdn-lint-space-"))
    try {
        fs.writeFileSync(path.join(dir, "Space.h"), [
            "#import <Foundation/Foundation.h>",
            "",
            "@interface Space : NSObject",
            "@end",
            "",
        ].join("\n"))
        fs.writeFileSync(path.join(dir, "Space.m"), [
            "#import \"Space.h\"",
            "",
            "@implementation Space",
            "- (unsigned long long)freeAt:(NSString *)path {",
            "    NSDictionary *attributes = [[NSFileManager defaultManager] attributesOfFileSystemForPath:path error:NULL];",
            "    return [attributes[NSFileSystemFreeSize] unsignedLongLongValue];",
            "}",
            "@end",
            "",
        ].join("\n"))

        const { problems } = run(dir, { quiet: true })
        assert.match(problems.join("\n"), /CdnImporterNearestExistingPath/)
    } finally {
        fs.rmSync(dir, { recursive: true, force: true })
    }
})

test("静态自检能抓出「逐条目解压却没有 autorelease 池」", async () => {
    const run = await loadLint()
    const dir = fs.mkdtempSync(path.join(os.tmpdir(), "cdn-lint-pool-"))
    try {
        fs.writeFileSync(path.join(dir, "Loop.h"), [
            "#import <Foundation/Foundation.h>",
            "",
            "@interface Loop : NSObject",
            "@end",
            "",
        ].join("\n"))
        // 有池 / 没池各写一份：没池必须被抓出来，有池必须放行（证明这条检查不是恒真）
        const body = (pooled) => [
            "#import \"Loop.h\"",
            "",
            "@implementation Loop",
            "- (void)runWithArchive:(id)archive entries:(NSArray *)entries",
            "{",
            "    for (id entry in entries) {",
            pooled ? "        @autoreleasepool {" : "        {",
            "            uint64_t written = 0;",
            "            (void)[archive extractEntry:entry toPath:@\"/tmp/x\" writtenBytes:&written error:NULL];",
            "        }",
            "    }",
            "}",
            "@end",
            "",
        ].join("\n")

        fs.writeFileSync(path.join(dir, "Loop.m"), body(false))
        assert.match(run(dir, { quiet: true }).problems.join("\n"), /没有 @autoreleasepool/)

        fs.writeFileSync(path.join(dir, "Loop.m"), body(true))
        assert.deepEqual(run(dir, { quiet: true }).problems, [])
    } finally {
        fs.rmSync(dir, { recursive: true, force: true })
    }
})

test("静态自检能抓出「把 bundle id 写死进路径」", async () => {
    const run = await loadLint()
    const dir = fs.mkdtempSync(path.join(os.tmpdir(), "cdn-lint-bundleid-"))
    try {
        fs.writeFileSync(path.join(dir, "Paths.h"), [
            "#import <Foundation/Foundation.h>",
            "",
            "@interface Paths : NSObject",
            "@end",
            "",
        ].join("\n"))
        // 写死包名（两条常见写法）/ 从 NSBundle 现取各写一份：前者必须被抓，后者必须放行
        const body = (hardcoded) => [
            "#import \"Paths.h\"",
            "",
            "@implementation Paths",
            "- (NSString *)store",
            "{",
            hardcoded
                ? "    return [NSHomeDirectory() stringByAppendingPathComponent:@\"Library/Application Support/com.leiting.wf\"];"
                : "    NSString *bundleID = [NSBundle mainBundle].bundleIdentifier ?: @\"\";",
            hardcoded
                ? "}"
                : "    return [[NSHomeDirectory() stringByAppendingPathComponent:@\"Library/Application Support\"]"
                    + " stringByAppendingPathComponent:bundleID];\n}",
            "@end",
            "",
        ].join("\n")

        fs.writeFileSync(path.join(dir, "Paths.m"), body(true))
        assert.match(run(dir, { quiet: true }).problems.join("\n"), /把 bundle id 拼进了 Application Support 路径/)

        fs.writeFileSync(path.join(dir, "Paths.m"), body(false))
        assert.deepEqual(run(dir, { quiet: true }).problems, [])
    } finally {
        fs.rmSync(dir, { recursive: true, force: true })
    }
})

test("静态自检能抓出「用了类但没引入声明它的头」", async () => {
    const run = await loadLint()
    const dir = fs.mkdtempSync(path.join(os.tmpdir(), "cdn-lint-import-"))
    try {
        fs.writeFileSync(path.join(dir, "Helper.h"), [
            "#import <Foundation/Foundation.h>",
            "",
            "@interface Helper : NSObject",
            "+ (instancetype)shared;",
            "@end",
            "",
        ].join("\n"))
        fs.writeFileSync(path.join(dir, "Helper.m"), [
            "#import \"Helper.h\"",
            "",
            "@implementation Helper",
            "+ (instancetype)shared { return nil; }",
            "@end",
            "",
        ].join("\n"))
        // User.m 忘了 #import "Helper.h" —— CI 上会报 use of undeclared identifier / receiver type
        fs.writeFileSync(path.join(dir, "User.h"), [
            "#import <Foundation/Foundation.h>",
            "",
            "@interface User : NSObject",
            "- (void)use;",
            "@end",
            "",
        ].join("\n"))
        fs.writeFileSync(path.join(dir, "User.m"), [
            "#import \"User.h\"",
            "",
            "@implementation User",
            "- (void)use { (void)[Helper shared]; }",
            "@end",
            "",
        ].join("\n"))

        const { problems } = run(dir, { quiet: true })
        assert.ok(problems.some((problem) => problem.includes("用到 Helper 但没有")
            && problem.includes("Helper.h")), `未抓出缺失 import：\n${problems.join("\n")}`)

        // 同一份代码补上 import 后必须放行（顺带证明这条检查不是恒真）
        fs.writeFileSync(path.join(dir, "User.m"), [
            "#import \"User.h\"",
            "#import \"Helper.h\"",
            "",
            "@implementation User",
            "- (void)use { (void)[Helper shared]; }",
            "@end",
            "",
        ].join("\n"))
        const fixed = run(dir, { quiet: true })
        assert.deepEqual(fixed.problems, [])
    } finally {
        fs.rmSync(dir, { recursive: true, force: true })
    }
})

test("静态自检对干净的头文件/实现文件不报问题", async () => {
    const run = await loadLint()
    const dir = fs.mkdtempSync(path.join(os.tmpdir(), "cdn-lint-good-"))
    try {
        fs.writeFileSync(path.join(dir, "Clean.h"), [
            "#import <Foundation/Foundation.h>",
            "",
            "@interface Clean : NSObject",
            "- (BOOL)runWithInput:(NSArray<NSString *> *)inputs error:(NSError **)error;",
            "@end",
            "",
        ].join("\n"))
        fs.writeFileSync(path.join(dir, "Clean.m"), [
            "#import \"Clean.h\"",
            "",
            "@implementation Clean",
            "",
            "- (BOOL)runWithInput:(NSArray<NSString *> *)inputs error:(NSError **)error",
            "{",
            "    (void)inputs;",
            "    if (error) *error = nil;",
            "    return YES;",
            "}",
            "",
            "@end",
            "",
        ].join("\n"))

        const { problems } = run(dir, { quiet: true })
        assert.deepEqual(problems, [])
    } finally {
        fs.rmSync(dir, { recursive: true, force: true })
    }
})
