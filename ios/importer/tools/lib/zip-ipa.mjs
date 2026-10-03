// 最小零依赖 ZIP 引擎（IPA 专用）：读中央目录 → 逐条保留原始属性与原始压缩字节 → 原样重写。
//
// 为什么不用 `jar uf0`（实测教训，2026-08 复现）：
//   JDK 的 `jar uf0` 会把整包重写成 STORED/madeBy=0x000a(FAT,MSDOS)/externalAttr=0，
//   等于**丢掉主二进制的 Unix 可执行位**（0o100755 → 0o0）与全部条目的属性。
//   Sideloadly 尚能容忍，但 AltStore/AltServer 的严格 IPA 解析会直接拒绝：
//   "The app is in an invalid format." ⇒ 装机路线会被堵死。
// 本引擎的做法：未被改动的条目**逐字节搬运**其原始压缩数据 + versionMadeBy/externalAttr，
//   只对被打补丁的主二进制重新 deflate，且**保留它原有的 versionMadeBy/externalAttr**。
//
// 约束：只支持 < 4 GB 的普通 zip（无 zip64、无加密）——IPA 场景足够。

import { deflateRawSync, inflateRawSync } from "node:zlib"

const CRC_TABLE = (() => {
    const table = new Uint32Array(256)
    for (let n = 0; n < 256; n += 1) {
        let c = n
        for (let k = 0; k < 8; k += 1) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1
        table[n] = c >>> 0
    }
    return table
})()

export function crc32(buffer) {
    let c = 0xffffffff
    for (let i = 0; i < buffer.length; i += 1) c = CRC_TABLE[(c ^ buffer[i]) & 0xff] ^ (c >>> 8)
    return (c ^ 0xffffffff) >>> 0
}

export const SIG_LOCAL = 0x04034b50
export const SIG_CENTRAL = 0x02014b50
export const SIG_EOCD = 0x06054b50

/** 解析 zip：返回逐条 entry（含原始压缩字节 raw）。 */
export function readZipEntries(buffer) {
    let eocd = -1
    const floor = Math.max(0, buffer.length - 22 - 65536)
    for (let i = buffer.length - 22; i >= floor; i -= 1) {
        if (buffer.readUInt32LE(i) === SIG_EOCD) {
            eocd = i
            break
        }
    }
    if (eocd < 0) throw new Error("ZIP EOCD not found（不是 zip/IPA？）")
    const total = buffer.readUInt16LE(eocd + 10)
    let cd = buffer.readUInt32LE(eocd + 16)
    const entries = []
    for (let n = 0; n < total; n += 1) {
        if (buffer.readUInt32LE(cd) !== SIG_CENTRAL) throw new Error(`central directory 损坏 @${cd}`)
        const versionMadeBy = buffer.readUInt16LE(cd + 4)
        const flags = buffer.readUInt16LE(cd + 8)
        const method = buffer.readUInt16LE(cd + 10)
        const mtime = buffer.readUInt16LE(cd + 12)
        const mdate = buffer.readUInt16LE(cd + 14)
        const crc = buffer.readUInt32LE(cd + 16)
        const csize = buffer.readUInt32LE(cd + 20)
        const usize = buffer.readUInt32LE(cd + 24)
        const nameLen = buffer.readUInt16LE(cd + 28)
        const extraLen = buffer.readUInt16LE(cd + 30)
        const commentLen = buffer.readUInt16LE(cd + 32)
        const externalAttr = buffer.readUInt32LE(cd + 38)
        const lho = buffer.readUInt32LE(cd + 42)
        const name = buffer.toString("latin1", cd + 46, cd + 46 + nameLen)
        if (csize === 0xffffffff || usize === 0xffffffff) throw new Error(`zip64 不受支持：${name}`)
        const lnameLen = buffer.readUInt16LE(lho + 26)
        const lextraLen = buffer.readUInt16LE(lho + 28)
        const dataStart = lho + 30 + lnameLen + lextraLen
        // raw 显式拷贝：避免后续 Buffer 复用/改写把源数据带脏
        const raw = Buffer.from(buffer.subarray(dataStart, dataStart + csize))
        entries.push({ name, method, flags, mtime, mdate, crc, csize, usize, versionMadeBy, externalAttr, raw })
        cd += 46 + nameLen + extraLen + commentLen
    }
    return entries
}

/** 按 entry 数组重写 zip：保留 method/mtime/mdate/versionMadeBy/externalAttr，丢弃 extra 字段（对齐填充）。 */
export function writeZipEntries(entries) {
    const locals = []
    const centrals = []
    let offset = 0
    for (const e of entries) {
        const name = Buffer.from(e.name, "latin1")
        const lh = Buffer.alloc(30)
        lh.writeUInt32LE(SIG_LOCAL, 0)
        lh.writeUInt16LE(20, 4)
        lh.writeUInt16LE(0, 6) // flags：无 data descriptor、无加密
        lh.writeUInt16LE(e.method, 8)
        lh.writeUInt16LE(e.mtime, 10)
        lh.writeUInt16LE(e.mdate, 12)
        lh.writeUInt32LE(e.crc, 14)
        lh.writeUInt32LE(e.raw.length, 18)
        lh.writeUInt32LE(e.usize, 22)
        lh.writeUInt16LE(name.length, 26)
        lh.writeUInt16LE(0, 28)
        locals.push(lh, name, e.raw)

        const ch = Buffer.alloc(46)
        ch.writeUInt32LE(SIG_CENTRAL, 0)
        ch.writeUInt16LE(e.versionMadeBy, 4)
        ch.writeUInt16LE(20, 6)
        ch.writeUInt16LE(0, 8)
        ch.writeUInt16LE(e.method, 10)
        ch.writeUInt16LE(e.mtime, 12)
        ch.writeUInt16LE(e.mdate, 14)
        ch.writeUInt32LE(e.crc, 16)
        ch.writeUInt32LE(e.raw.length, 20)
        ch.writeUInt32LE(e.usize, 24)
        ch.writeUInt16LE(name.length, 28)
        ch.writeUInt16LE(0, 30)
        ch.writeUInt16LE(0, 32)
        ch.writeUInt16LE(0, 34)
        ch.writeUInt16LE(0, 36)
        ch.writeUInt32LE(e.externalAttr, 38)
        ch.writeUInt32LE(offset, 42)
        centrals.push(ch, name)

        offset += 30 + name.length + e.raw.length
    }
    const localBuf = Buffer.concat(locals)
    const centralBuf = Buffer.concat(centrals)
    const eocd = Buffer.alloc(22)
    eocd.writeUInt32LE(SIG_EOCD, 0)
    eocd.writeUInt16LE(0, 4)
    eocd.writeUInt16LE(0, 6)
    eocd.writeUInt16LE(entries.length, 8)
    eocd.writeUInt16LE(entries.length, 10)
    eocd.writeUInt32LE(centralBuf.length, 12)
    eocd.writeUInt32LE(localBuf.length, 16)
    eocd.writeUInt16LE(0, 20)
    return Buffer.concat([localBuf, centralBuf, eocd])
}

/** 取出 entry 的解压内容（method 0 直取，method 8 inflateRaw）。 */
export function readEntryData(entry) {
    if (entry.method === 0) return Buffer.from(entry.raw)
    if (entry.method === 8) return inflateRawSync(entry.raw)
    throw new Error(`不支持的压缩方法 ${entry.method}：${entry.name}`)
}

/**
 * 用新内容替换某个 entry 的数据：**沿用该 entry 原有的压缩方法**（method 8 重新 deflate、
 * method 0 直存），并保持 versionMadeBy/externalAttr/mtime/mdate 不变。
 * 返回 { entry, method, compressedBytes }；找不到该 entry 时抛错。
 */
export function replaceEntryData(entries, name, newData) {
    const entry = entries.find(item => item.name === name)
    if (!entry) throw new Error(`IPA 里没有 entry：${name}`)
    const raw = entry.method === 8 ? deflateRawSync(newData, { level: 9 }) : Buffer.from(newData)
    entry.raw = raw
    entry.usize = newData.length
    entry.csize = raw.length
    entry.crc = crc32(newData)
    return { entry, method: entry.method, compressedBytes: raw.length }
}

/** Unix 模式位（externalAttr 高 16 位），仅对 versionMadeBy host=3(Unix)/19(OSX) 有意义。 */
export function unixMode(entry) {
    return (entry.externalAttr >>> 16) & 0xffff
}

/** versionMadeBy 的高字节 = 制作方宿主系统（3=Unix, 19=OSX, 0=FAT/MSDOS）。 */
export function madeByHost(entry) {
    return entry.versionMadeBy >> 8
}
