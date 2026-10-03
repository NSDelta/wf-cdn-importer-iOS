"use strict"

// ZIP 中央目录解析：Node 参考实现（ios/importer/tools/verify-plan.mjs）的畸形输入护栏。
// Objective-C 侧 ios/importer/CdnZipArchive.m 用同一套解析策略与同一批护栏，
// 这里用合成 ZIP 把「合法能读、畸形必须报错」钉死，避免解析器把崩溃带进宿主游戏进程。

const assert = require("node:assert/strict")
const test = require("node:test")
const fs = require("node:fs")
const os = require("node:os")
const path = require("node:path")
const zlib = require("node:zlib")
const { pathToFileURL } = require("node:url")

const REPO_ROOT = path.resolve(__dirname, "..")
const VERIFY_PLAN = pathToFileURL(path.join(REPO_ROOT, "ios/importer/tools/verify-plan.mjs")).href

const SIG_LOCAL = 0x04034b50
const SIG_CENTRAL = 0x02014b50
const SIG_EOCD = 0x06054b50

/** 造一个真实 ZIP（stored + deflate 各一条 + 一条目录项），返回 Buffer。 */
function buildZip() {
    const files = [
        { name: "production/upload/00/aaa", data: Buffer.from("hello world"), method: 0 },
        { name: "production/medium_upload/00/bbb", data: Buffer.from("x".repeat(5000)), method: 8 },
        { name: "production/upload/00/", data: Buffer.alloc(0), method: 0 },
    ]
    const locals = []
    const centrals = []
    let offset = 0
    for (const file of files) {
        const raw = file.method === 8 ? zlib.deflateRawSync(file.data, { level: 9 }) : file.data
        const crc = zlib.crc32 ? zlib.crc32(file.data) : crc32(file.data)
        const nameBuffer = Buffer.from(file.name, "utf8")

        const local = Buffer.alloc(30 + nameBuffer.length)
        local.writeUInt32LE(SIG_LOCAL, 0)
        local.writeUInt16LE(20, 4)
        local.writeUInt16LE(0, 6)
        local.writeUInt16LE(file.method, 8)
        local.writeUInt16LE(0, 10)
        local.writeUInt16LE(0, 12)
        local.writeUInt32LE(crc, 14)
        local.writeUInt32LE(raw.length, 18)
        local.writeUInt32LE(file.data.length, 22)
        local.writeUInt16LE(nameBuffer.length, 26)
        local.writeUInt16LE(0, 28)
        nameBuffer.copy(local, 30)

        const central = Buffer.alloc(46 + nameBuffer.length)
        central.writeUInt32LE(SIG_CENTRAL, 0)
        central.writeUInt16LE(20, 4)
        central.writeUInt16LE(20, 6)
        central.writeUInt16LE(0, 8)
        central.writeUInt16LE(file.method, 10)
        central.writeUInt16LE(0, 12)
        central.writeUInt16LE(0, 14)
        central.writeUInt32LE(crc, 16)
        central.writeUInt32LE(raw.length, 20)
        central.writeUInt32LE(file.data.length, 24)
        central.writeUInt16LE(nameBuffer.length, 28)
        central.writeUInt16LE(0, 30)
        central.writeUInt16LE(0, 32)
        central.writeUInt16LE(0, 34)
        central.writeUInt16LE(0, 36)
        central.writeUInt32LE(0o100644 << 16 >>> 0, 38)
        central.writeUInt32LE(offset, 42)
        nameBuffer.copy(central, 46)

        locals.push(local, raw)
        centrals.push(central)
        offset += local.length + raw.length
    }

    const centralBuffer = Buffer.concat(centrals)
    const eocd = Buffer.alloc(22)
    eocd.writeUInt32LE(SIG_EOCD, 0)
    eocd.writeUInt16LE(0, 4)
    eocd.writeUInt16LE(0, 6)
    eocd.writeUInt16LE(files.length, 8)
    eocd.writeUInt16LE(files.length, 10)
    eocd.writeUInt32LE(centralBuffer.length, 12)
    eocd.writeUInt32LE(offset, 16)
    eocd.writeUInt16LE(0, 20)
    return { buffer: Buffer.concat([...locals, centralBuffer, eocd]), files }
}

let crcTable = null
function crc32(buffer) {
    if (crcTable === null) {
        crcTable = new Int32Array(256)
        for (let index = 0; index < 256; index++) {
            let value = index
            for (let bit = 0; bit < 8; bit++) value = value & 1 ? 0xedb88320 ^ (value >>> 1) : value >>> 1
            crcTable[index] = value
        }
    }
    let crc = -1
    for (const byte of buffer) crc = crcTable[(crc ^ byte) & 0xff] ^ (crc >>> 8)
    return (crc ^ -1) >>> 0
}

function withTempZip(buffer, callback) {
    const dir = fs.mkdtempSync(path.join(os.tmpdir(), "cdn-zip-"))
    const file = path.join(dir, "sample.zip")
    fs.writeFileSync(file, buffer)
    try {
        return callback(file)
    } finally {
        fs.rmSync(dir, { recursive: true, force: true })
    }
}

test("合法 ZIP：中央目录逐条可读，stored/deflate 与目录项都在", async () => {
    const { readZipCentralDirectory } = await import(VERIFY_PLAN)
    const { buffer, files } = buildZip()
    withTempZip(buffer, (file) => {
        const entries = readZipCentralDirectory(file)
        assert.equal(entries.length, files.length)
        assert.deepEqual(entries.map((entry) => entry.name), files.map((entry) => entry.name))
        assert.deepEqual(entries.map((entry) => entry.method), files.map((entry) => entry.method))
        assert.deepEqual(entries.map((entry) => entry.uncompressedSize),
            files.map((file_) => file_.data.length))
        for (const entry of entries) assert.ok(entry.localOffset >= 0 && entry.localOffset < buffer.length)
    })
})

test("条目名含 PK\\x05\\x06 的注释：不校验注释长度就会取到假 EOCD", async () => {
    const { readZipCentralDirectory } = await import(VERIFY_PLAN)
    const { buffer } = buildZip()
    // 在真 EOCD 之后追加一段注释，注释里再塞一个假 EOCD
    const comment = Buffer.concat([Buffer.from("note:"), Buffer.from([0x50, 0x4b, 0x05, 0x06]), Buffer.alloc(16)])
    const withComment = Buffer.concat([buffer, comment])
    withComment.writeUInt16LE(comment.length, buffer.length - 22 + 20)
    withTempZip(withComment, (file) => {
        const entries = readZipCentralDirectory(file)
        assert.equal(entries.length, 3)
    })
})

test("中央目录越界（回绕）必须报错，而不是分配巨量内存", async () => {
    const { readZipCentralDirectory } = await import(VERIFY_PLAN)
    const { buffer } = buildZip()
    const eocdOffset = buffer.length - 22
    const broken = Buffer.from(buffer)
    broken.writeUInt32LE(0xffffff00, eocdOffset + 16)   // centralOffset
    broken.writeUInt32LE(0x00000100, eocdOffset + 12)   // centralSize：相加超过文件长度
    withTempZip(broken, (file) => {
        assert.throws(() => readZipCentralDirectory(file), /中央目录越界/)
    })
})

test("条目数与中央目录容量不符必须报错", async () => {
    const { readZipCentralDirectory } = await import(VERIFY_PLAN)
    const { buffer } = buildZip()
    const eocdOffset = buffer.length - 22
    const broken = Buffer.from(buffer)
    broken.writeUInt16LE(0xffff, eocdOffset + 10)       // 65535 条，但中央目录只有几百字节
    withTempZip(broken, (file) => {
        assert.throws(() => readZipCentralDirectory(file), /条目数|中央目录容量/)
    })
})

test("跳过规则与参考 APK 一致：目录项 / .empty / .hash", async () => {
    const { isSkippedEntry } = await import(VERIFY_PLAN)
    for (const name of ["production/upload/00/", "x/y.empty", "a/b.hash", "nested/dir/"]) {
        assert.equal(isSkippedEntry(name), true, name)
    }
    for (const name of ["production/upload/00/00401ec4", "x/y.emptyhash", "dummy.txt", "a/b.hashx"]) {
        assert.equal(isSkippedEntry(name), false, name)
    }
})
