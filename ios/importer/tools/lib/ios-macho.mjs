// iOS Mach-O（64 位）头/load command 解析 + 官方 iOS 1.8.4 基线指纹 —— A1b 新增（lib/** 归 P10-A）。
//
// 为什么需要：A1b 的验收红线之一是"只改字节、不动结构"。`ncmds` / `sizeofcmds` / 主二进制长度
// 只要有一个变了，就说明补丁加了段或改动了 load command 区 —— 而 AIR AOT 加载器对 LC 区极度敏感
// （B0 报告的启动黑屏就是容器长度错位造成的）。把这条判定做成机器断言，而不是靠人眼看日志。

export const MH_MAGIC_64 = 0xfeedfacf

export const LC_SEGMENT_64 = 0x19
export const LC_CODE_SIGNATURE = 0x1d
export const LC_ENCRYPTION_64 = 0x2c

/**
 * 解析 64 位 Mach-O 头与 load command 表（只读）。
 * 返回 { magic, cputype, filetype, ncmds, sizeofcmds, commandsEnd, commands, encryption, codeSignature }。
 * 任何结构异常都抛错（宁可直接失败，也不要在结构可疑的文件上打补丁）。
 */
export function parseMachOHeader(buffer) {
    if (buffer.length < 32) throw new Error(`文件太小，不是 Mach-O：${buffer.length} B`)
    const magic = buffer.readUInt32LE(0)
    if (magic !== MH_MAGIC_64) {
        throw new Error(`不是 64 位 Mach-O：magic=0x${magic.toString(16)}（期望 0x${MH_MAGIC_64.toString(16)}）`)
    }
    const cputype = buffer.readUInt32LE(4)
    const filetype = buffer.readUInt32LE(12)
    const ncmds = buffer.readUInt32LE(16)
    const sizeofcmds = buffer.readUInt32LE(20)
    const commandsEnd = 32 + sizeofcmds
    if (commandsEnd > buffer.length) {
        throw new Error(`load command 区越界：32 + ${sizeofcmds} = ${commandsEnd} > ${buffer.length}`)
    }
    const commands = []
    let cursor = 32
    for (let index = 0; index < ncmds; index += 1) {
        if (cursor + 8 > commandsEnd) throw new Error(`load command #${index} 越界 @${cursor}`)
        const cmd = buffer.readUInt32LE(cursor)
        const cmdsize = buffer.readUInt32LE(cursor + 4)
        if (cmdsize < 8 || cursor + cmdsize > commandsEnd) throw new Error(`load command #${index} 尺寸非法：${cmdsize}`)
        commands.push({ cmd, cmdsize, offset: cursor })
        cursor += cmdsize
    }
    const find = (cmd) => commands.find((item) => item.cmd === cmd)
    const encryption = find(LC_ENCRYPTION_64)
    const signature = find(LC_CODE_SIGNATURE)
    return {
        magic,
        cputype,
        filetype,
        ncmds,
        sizeofcmds,
        commandsEnd,
        commands,
        encryption: encryption
            ? {
                cryptoff: buffer.readUInt32LE(encryption.offset + 8),
                cryptsize: buffer.readUInt32LE(encryption.offset + 12),
                cryptid: buffer.readUInt32LE(encryption.offset + 16),
            }
            : null,
        codeSignature: signature
            ? {
                dataoff: buffer.readUInt32LE(signature.offset + 8),
                datasize: buffer.readUInt32LE(signature.offset + 12),
            }
            : null,
    }
}

/**
 * 定位主二进制 entry：`Payload/<X>.app/<X>`（app 名与可执行名相同）。
 * 传 appName 时按 `Payload/<appName>.app/<appName>` 精确匹配。
 */
export function findMainBinaryEntry(entries, appName = "") {
    if (appName) {
        const wanted = `Payload/${appName}.app/${appName}`
        const hit = entries.find((entry) => entry.name === wanted)
        if (!hit) throw new Error(`IPA 里没有主二进制 entry：${wanted}`)
        return hit
    }
    const hits = entries.filter((entry) => /^Payload\/([^/]+)\.app\/\1$/.test(entry.name))
    if (hits.length === 0) {
        throw new Error("IPA 里找不到 `Payload/<X>.app/<X>` 形式的主二进制（可用 --app=<名> 指定）")
    }
    if (hits.length > 1) {
        throw new Error(`IPA 里有多个候选主二进制：${hits.map((entry) => entry.name).join(", ")}（用 --app= 指定）`)
    }
    return hits[0]
}

/**
 * 官方 iOS 1.8.4 原始件指纹（2026-09 实测；B0 报告 + 本次 A1b 复算一致）。
 *
 * ⚠️ 勘误：任务单/分工文档里写的 `ccf9d309e55e2824…` 是**主二进制**（Payload/worldflipper.app/
 * worldflipper，108,757,200 B）的 sha256，**不是** IPA 容器的 sha256；IPA 容器是 `5241e51b…`。
 * 两者都在此表里，输入校验按主二进制走（那才是被改写的对象）。
 */
export const OFFICIAL_IOS_184 = {
    label: "iOS 1.8.4 官方原始件（DumpDecrypter 解密 dump，cryptid=0）",
    ipaBytes: 139212360,
    ipaSha256: "5241e51b40bd9d7e2ad92bae9b85e4dc31cd19cd68a637d363c5dcca3eae0a3a",
    entries: 3568,
    binEntry: "Payload/worldflipper.app/worldflipper",
    binBytes: 108757200,
    binSha256: "ccf9d309e55e2824c636a2ef0febf38d898b83a74694a08e69ab79a1e26b3429",
    ncmds: 67,
    sizeofcmds: 7584,
    // 域名站点直方图（与 --host 无关，是官方件的固有属性）
    siteTotal: 150,
    siteRewriteable: 137,
    siteTooShort: 13,
    // host:port 必须是 18 字符（分工文档 §C2 / 冻结契约 C6 的 LAN 地址；真值只从 --host 传入）
    endpointLength: 18,
    // 补丁后整包内该 18 字符 LAN 地址的出现次数 = 137（URL 站点）+ 1（ABC 池）= 138
    endpointOccurrencesAfter: 138,
    abcPairOffset: 0x5a0e14b,
    abcPairBytes: 33,
    mainEntryAttrs: { method: 8, versionMadeBy: 0x1300, externalAttr: 0x81ed0000, unixMode: 0o100755 },
    // B0 派生物（当时的 iOS 派生脚本，现已删除）的主二进制 sha256 —— 只作对照，不是验收目标：
    // 那个派生件丢了基线六项功能补丁（见主项目里的改造记录 §2）
    b0BinSha256After: "f5ce251752a123559a5d26b95eb3cea39b4fd4f8a9cbfec4a02e7306240cdbec",
}
