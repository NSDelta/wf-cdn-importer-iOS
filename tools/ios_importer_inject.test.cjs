"use strict"

const assert = require("node:assert/strict")
const fs = require("node:fs")
const os = require("node:os")
const path = require("node:path")
const test = require("node:test")
const { pathToFileURL } = require("node:url")

const REPO = path.resolve(__dirname, "..")
const INJECT_URL = pathToFileURL(path.join(REPO, "ios/importer/tools/inject-dylib.mjs")).href
// 本仓库自带一份 zip-ipa.mjs（ios/importer/tools/lib/），测试直接用它当 ZIP 参考实现。
const ZIP_LIB_URL = pathToFileURL(path.join(REPO, "ios/importer/tools/lib/zip-ipa.mjs")).href

// 官方 IPA 有 139MB，CI 里不该依赖它，仓库里也不放这么大的固件。
// 这里按 Mach-O / zip 的真实布局合成一个迷你 IPA，覆盖注入器的断言与失败路径。
const MH_MAGIC_64 = 0xfeedfacf
const CPU_TYPE_ARM64 = 0x0100000c
const LC_SEGMENT_64 = 0x19
const SEGMENT_COMMAND_SIZE = 72
const SECTION_64_SIZE = 80
// segment_command_64 的 cmdsize 含其 section_64（真实 Mach-O 的 sizeofcmds 就是这么算的）
const SEGMENT_WITH_ONE_SECTION = SEGMENT_COMMAND_SIZE + SECTION_64_SIZE
const COMMANDS_END = 32 + SEGMENT_WITH_ONE_SECTION
const LOAD_DYLIB_SIZE = 72
const DEFAULT_TEXT_OFFSET = 0x4000

let tools = null

async function loadTools() {
    if (tools === null) {
        const [inject, zipLib] = await Promise.all([import(INJECT_URL), import(ZIP_LIB_URL)])
        tools = { inject, ...zipLib }
    }
    return tools
}

function buildMachO({
    filetype = 2,
    textOffset = DEFAULT_TEXT_OFFSET,
    padByte = 0,
    totalSize = 0x10000,
    bodyBytes = 0x1000,
} = {}) {
    const buffer = Buffer.alloc(totalSize, padByte)

    // 段内容先填，再写头部与命令区：命令区永远覆盖段内容（模拟真实布局里命令区在最前）。
    for (let index = textOffset; index < Math.min(textOffset + bodyBytes, totalSize); index++) {
        buffer[index] = (index * 31 + 7) & 0xff
    }

    buffer.writeUInt32LE(MH_MAGIC_64, 0)
    buffer.writeUInt32LE(CPU_TYPE_ARM64, 4)
    buffer.writeUInt32LE(0, 8)
    buffer.writeUInt32LE(filetype, 12)
    buffer.writeUInt32LE(1, 16) // ncmds
    buffer.writeUInt32LE(SEGMENT_WITH_ONE_SECTION, 20) // sizeofcmds
    buffer.writeUInt32LE(0x00200085, 24)
    buffer.writeUInt32LE(0, 28)

    const segment = 32
    buffer.writeUInt32LE(LC_SEGMENT_64, segment)
    buffer.writeUInt32LE(SEGMENT_WITH_ONE_SECTION, segment + 4)
    buffer.write("__TEXT", segment + 8, "ascii")
    buffer.writeBigUInt64LE(0x100000000n, segment + 24) // vmaddr
    buffer.writeBigUInt64LE(BigInt(textOffset + bodyBytes), segment + 32) // vmsize
    buffer.writeBigUInt64LE(0n, segment + 40) // fileoff
    buffer.writeBigUInt64LE(BigInt(totalSize), segment + 48) // filesize
    buffer.writeUInt32LE(5, segment + 56) // maxprot
    buffer.writeUInt32LE(5, segment + 60) // initprot
    buffer.writeUInt32LE(1, segment + 64) // nsects
    buffer.writeUInt32LE(0, segment + 68)

    const section = segment + SEGMENT_COMMAND_SIZE
    buffer.write("__text", section, "ascii")
    buffer.write("__TEXT", section + 16, "ascii")
    buffer.writeBigUInt64LE(0x100000000n + BigInt(textOffset), section + 32) // addr
    buffer.writeBigUInt64LE(BigInt(bodyBytes), section + 40) // size
    buffer.writeUInt32LE(textOffset, section + 48) // offset（uint32）
    buffer.writeUInt32LE(2, section + 52) // align
    for (let index = 0; index < 4; index++) buffer.writeUInt32LE(0, section + 56 + index * 4)

    assert.ok(COMMANDS_END <= textOffset, `固件自检：命令区 ${COMMANDS_END} 超出 section 起点 ${textOffset}`)
    return buffer
}

function storedEntry(name, data, mode = 0o100644) {
    return {
        name,
        method: 0,
        flags: 0,
        mtime: 0x4c7c,
        mdate: 0x5b09,
        crc: tools.crc32(data),
        csize: data.length,
        usize: data.length,
        versionMadeBy: 0x031e,
        externalAttr: ((mode * 0x10000) >>> 0),
        raw: Buffer.from(data),
    }
}

function makeFixture({ textOffset = DEFAULT_TEXT_OFFSET, padByte = 0, dylibFiletype = 6 } = {}) {
    const main = buildMachO({ filetype: 2, textOffset, padByte })
    const dylib = buildMachO({ filetype: dylibFiletype, totalSize: 0x8000 })
    const plist = Buffer.from(
        "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<plist version=\"1.0\"><dict>"
        + "<key>CFBundleExecutable</key><string>TestApp</string></dict></plist>\n")
    const ipa = tools.writeZipEntries([
        storedEntry("Payload/TestApp.app/TestApp", main, 0o100755),
        storedEntry("Payload/TestApp.app/Info.plist", plist),
        storedEntry("Payload/TestApp.app/extra.bin", Buffer.from("cdn importer fixture\n")),
    ])
    return { main, dylib, ipa }
}

function withTempDir(body) {
    const dir = fs.mkdtempSync(path.join(os.tmpdir(), "cdn-inject-"))
    try {
        return body(dir)
    } finally {
        fs.rmSync(dir, { recursive: true, force: true })
    }
}

function runInjection(dir, fixture, overrides = {}) {
    const ipaPath = path.join(dir, "in.ipa")
    const dylibPath = path.join(dir, "CdnImporter.dylib")
    fs.writeFileSync(ipaPath, fixture.ipa)
    fs.writeFileSync(dylibPath, fixture.dylib)
    const outPath = overrides.out ?? path.join(dir, "out.ipa")
    return tools.inject.injectDylib({
        ipa: ipaPath,
        dylib: dylibPath,
        out: outPath,
        app: "TestApp",
        installName: tools.inject.DEFAULT_INSTALL_NAME,
        report: path.join(dir, "report.json"),
        dryRun: false,
        quiet: true,
        ...overrides,
    })
}

test("注入器：迷你 IPA 上全部断言通过，改动可逐字节回读验证", async () => {
    await loadTools()
    const fixture = makeFixture()

    withTempDir((dir) => {
        const { report, outBuffer, outPath } = runInjection(dir, fixture)

        const failed = report.assertions.filter((item) => !item.ok)
        assert.deepEqual(failed, [])
        assert.ok(report.assertions.length >= 15, `断言太少：${report.assertions.length}`)
        assert.ok(fs.existsSync(outPath))
        assert.ok(fs.existsSync(path.join(dir, "report.json")))
        assert.equal(outBuffer.length, fs.readFileSync(outPath).length)

        assert.equal(report.input.entryCount, 3)
        assert.equal(report.injection.ncmdsBefore, 1)
        assert.equal(report.injection.ncmdsAfter, 2)
        assert.equal(report.injection.sizeofcmdsAfter - report.injection.sizeofcmdsBefore, LOAD_DYLIB_SIZE)
        assert.equal(report.injection.minSectionOffset, DEFAULT_TEXT_OFFSET)
        assert.equal(report.injection.dylibEntryName, "Payload/TestApp.app/Frameworks/CdnImporter.dylib")
        assert.equal(report.output.entryCount, 4)

        // 直接把产物拆开：主二进制只应多出那 72 字节，其余字节逐字节相同
        const entries = tools.readZipEntries(fs.readFileSync(outPath))
        const mainAfter = tools.readEntryData(entries.find((entry) => entry.name === "Payload/TestApp.app/TestApp"))
        assert.equal(mainAfter.length, fixture.main.length)

        let diffCount = 0
        for (let index = 0; index < mainAfter.length; index++) {
            if (mainAfter[index] === fixture.main[index]) continue
            diffCount += 1
            // 允许变化的只有：头里的 ncmds/sizeofcmds（偏移 16..24）与新增的那条加载命令
            const inHeaderCounters = index >= 16 && index < 24
            const inNewCommand = index >= COMMANDS_END && index < COMMANDS_END + LOAD_DYLIB_SIZE
            assert.ok(inHeaderCounters || inNewCommand, `不应改动偏移 ${index} 的字节`)
        }
        // 变化的字节只能落在上面两段里（余量本身是 0，所以实际变化数 ≤ 8 + 72）
        assert.ok(diffCount > 0 && diffCount <= 8 + LOAD_DYLIB_SIZE, `改动字节数异常：${diffCount}`)
        assert.deepEqual(mainAfter.subarray(COMMANDS_END + LOAD_DYLIB_SIZE),
            fixture.main.subarray(COMMANDS_END + LOAD_DYLIB_SIZE))

        const loadCommand = mainAfter.subarray(COMMANDS_END, COMMANDS_END + LOAD_DYLIB_SIZE)
        assert.equal(loadCommand.readUInt32LE(0), 0x0c) // LC_LOAD_DYLIB
        assert.equal(loadCommand.readUInt32LE(4), LOAD_DYLIB_SIZE)
        assert.equal(mainAfter.readUInt32LE(16), 2) // ncmds
        assert.equal(mainAfter.readUInt32LE(20), SEGMENT_WITH_ONE_SECTION + LOAD_DYLIB_SIZE)
        assert.equal(loadCommand.subarray(24, 24 + tools.inject.DEFAULT_INSTALL_NAME.length).toString("utf8"),
            tools.inject.DEFAULT_INSTALL_NAME)

        // dylib 条目紧跟主二进制，且可执行位保留
        assert.equal(entries[1].name, "Payload/TestApp.app/Frameworks/CdnImporter.dylib")
        assert.equal(tools.readEntryData(entries[1]).length, fixture.dylib.length)
        assert.equal((entries[1].externalAttr >>> 16) & 0o777, 0o755)
    })
})

test("注入器：dry-run 不落盘但报告完整", async () => {
    await loadTools()
    const fixture = makeFixture()

    withTempDir((dir) => {
        const { report, outBuffer, dryRun, outPath } = runInjection(dir, fixture, { dryRun: true })

        assert.equal(dryRun, true)
        assert.ok(outBuffer.length > 0)
        assert.equal(fs.existsSync(outPath), false)
        assert.equal(fs.existsSync(path.join(dir, "report.json")), false)
        assert.deepEqual(report.assertions.filter((item) => !item.ok), [])
        assert.equal(report.injection.skipped, undefined)
    })
})

test("注入器：对已注入的 IPA 幂等（不再写加载命令、不重复加条目）", async () => {
    await loadTools()
    const fixture = makeFixture()

    withTempDir((dir) => {
        const first = runInjection(dir, fixture)
        assert.equal(first.report.injection.ncmdsAfter, 2)

        const second = runInjection(dir, fixture, { ipa: first.outPath, out: path.join(dir, "out2.ipa") })

        assert.equal(second.report.injection.skipped, "existing-load-command")
        assert.equal(second.report.injection.ncmdsAfter, 2)
        assert.equal(second.report.output.entryCount, 4)
        assert.deepEqual(second.report.assertions.filter((item) => !item.ok), [])
    })
})

test("注入器：dylib 文件名与 install name 不一致时，条目名以 install name 为准", async () => {
    await loadTools()
    const fixture = makeFixture()

    withTempDir((dir) => {
        // dyld 按 LC_LOAD_DYLIB 的路径找库：条目名跟着本地文件名走的话，注入完的 IPA 一启动就崩
        const renamed = path.join(dir, "CdnImporter-append.dylib")
        fs.writeFileSync(renamed, fixture.dylib)

        const { report } = runInjection(dir, fixture, { dylib: renamed })

        assert.equal(report.injection.dylibUploadName, "CdnImporter-append.dylib")
        assert.equal(report.injection.dylibEntryName, "Payload/TestApp.app/Frameworks/CdnImporter.dylib")
        assert.deepEqual(report.assertions.filter((item) => !item.ok), [])

        const entries = tools.readZipEntries(fs.readFileSync(report.output.path))
        assert.equal(entries.some((entry) => entry.name.endsWith("CdnImporter-append.dylib")), false)
        assert.ok(entries.some((entry) => entry.name === "Payload/TestApp.app/Frameworks/CdnImporter.dylib"))
    })
})

test("注入器：拒绝非动态库、余量不足与非零余量", async () => {
    await loadTools()

    // dylib 的 filetype 必须是 6/8（2 = MH_EXECUTE）
    assert.throws(() => withTempDir((dir) => runInjection(dir, makeFixture({ dylibFiletype: 2 }))),
        /断言失败：dylib 是 64 位 Mach-O 动态库/)

    // 首个 section 起点落进命令区扩展范围 → 头部余量不足（需要到 @256）
    assert.throws(() => withTempDir((dir) => runInjection(dir, makeFixture({ textOffset: 0xc8 }))),
        /断言失败：有足够的头部余量放新命令/)

    // 余量字节非 0：真实 IPA 里这段是零填充，非 0 说明布局认知有误，必须停下
    assert.throws(() => withTempDir((dir) => runInjection(dir, makeFixture({ padByte: 0xff }))),
        /断言失败：待写入的 72 字节余量全为 0/)
})

test("注入器：找不到 dylib 时直接报错，不产出文件", async () => {
    await loadTools()
    const fixture = makeFixture()

    withTempDir((dir) => {
        const missing = path.join(dir, "missing.dylib")
        assert.throws(() => runInjection(dir, fixture, { dylib: missing, dryRun: false }), /ENOENT/)
        assert.equal(fs.existsSync(path.join(dir, "out.ipa")), false)
    })
})
