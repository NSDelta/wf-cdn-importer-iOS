//
//  CdnZipArchive.m
//

#import "CdnZipArchive.h"

#import <errno.h>
#import <fcntl.h>
#import <string.h>
#import <unistd.h>
#import <zlib.h>

static const uint32_t kEOCDSignature = 0x06054b50;
static const uint32_t kEOCD64LocatorSignature = 0x07064b50;
static const uint32_t kEOCD64Signature = 0x06064b50;
static const uint32_t kCentralSignature = 0x02014b50;
static const uint32_t kLocalSignature = 0x04034b50;

/// EOCD 最小 22 字节 + 最大 65535 注释；再留 64 字节给 ZIP64 定位器回溯。
static const uint64_t kEOCDSearchLength = 65557 + 64;
static const NSUInteger kInputChunk = 256 * 1024;
static const NSUInteger kOutputChunk = 256 * 1024;

BOOL CdnZipIsSkippedEntryName(NSString *name) {
    // 与参考 APK 的 extractZip 规则一致：目录项、.empty、.hash 不落盘。
    return [name hasSuffix:@"/"] || [name hasSuffix:@".empty"] || [name hasSuffix:@".hash"];
}

#pragma mark - 条目

@interface CdnZipEntry ()
- (instancetype)initWithName:(NSString *)name
                      method:(uint16_t)method
              compressedSize:(uint64_t)compressedSize
            uncompressedSize:(uint64_t)uncompressedSize
                       crc32:(uint32_t)crc32
           localHeaderOffset:(uint64_t)localHeaderOffset;
@end

@implementation CdnZipEntry

- (instancetype)initWithName:(NSString *)name
                      method:(uint16_t)method
              compressedSize:(uint64_t)compressedSize
            uncompressedSize:(uint64_t)uncompressedSize
                       crc32:(uint32_t)crc32
           localHeaderOffset:(uint64_t)localHeaderOffset {
    self = [super init];
    if (self != nil) {
        _name = [name copy];
        _method = method;
        _compressedSize = compressedSize;
        _uncompressedSize = uncompressedSize;
        _crc32 = crc32;
        _localHeaderOffset = localHeaderOffset;
    }
    return self;
}

- (NSString *)description {
    return [NSString stringWithFormat:@"<CdnZipEntry %@ method=%u %llu→%llu>",
            _name, _method, _compressedSize, _uncompressedSize];
}

@end

#pragma mark - ZIP

@implementation CdnZipArchive

+ (nullable instancetype)archiveWithSource:(id<CdnArchiveSource>)source error:(NSError **)error {
    if (source == nil) {
        if (error != NULL) *error = CdnError(CdnImporterErrorIO, @"空数据源");
        return nil;
    }
    uint64_t size = source.length;
    if (size < 22) {
        if (error != NULL) *error = CdnError(CdnImporterErrorFormat, @"文件太小，不可能是 ZIP（%llu 字节）", size);
        return nil;
    }

    // ---- 1. 尾部找 EOCD
    uint64_t tailLength = MIN(size, kEOCDSearchLength);
    NSData *tail = CdnReadData(source, size - tailLength, (NSUInteger)tailLength, error);
    if (tail == nil) return nil;
    const uint8_t *tailBytes = tail.bytes;
    NSInteger eocd = -1;
    if (tail.length >= 22) {
        for (NSInteger index = (NSInteger)tail.length - 22; index >= 0; index--) {
            if (CdnReadLE32(tailBytes, (NSUInteger)index) != kEOCDSignature) continue;
            // 注释里也可能出现 PK\x05\x06：只有「注释长度正好顶到文件尾」的那条才是真 EOCD
            uint64_t commentLength = CdnReadLE16(tailBytes, (NSUInteger)index + 20);
            if ((uint64_t)index + 22 + commentLength != tail.length) continue;
            eocd = index;
            break;
        }
    }
    if (eocd < 0) {
        if (error != NULL) *error = CdnError(CdnImporterErrorFormat, @"找不到 EOCD（不是合法 ZIP）");
        return nil;
    }

    uint64_t entryCount = CdnReadLE16(tailBytes, (NSUInteger)eocd + 10);
    uint64_t centralSize = CdnReadLE32(tailBytes, (NSUInteger)eocd + 12);
    uint64_t centralOffset = CdnReadLE32(tailBytes, (NSUInteger)eocd + 16);

    // ---- 2. 必要时走 ZIP64 EOCD
    // 条目数 0xffff 单独出现时不足以断定 ZIP64（合法的 65535 条目 ZIP 也长这样），
    // 找不到定位器就沿用 EOCD 里的值，而不是直接判错。
    BOOL needsZip64 = centralOffset == 0xffffffffULL || centralSize == 0xffffffffULL || entryCount == 0xffffULL;
    if (needsZip64) {
        NSInteger locator = -1;
        for (NSInteger index = eocd - 20; index >= 0; index--) {
            if (CdnReadLE32(tailBytes, (NSUInteger)index) == kEOCD64LocatorSignature) {
                locator = index;
                break;
            }
        }
        if (locator < 0) {
            if (centralOffset == 0xffffffffULL || centralSize == 0xffffffffULL) {
                if (error != NULL) *error = CdnError(CdnImporterErrorFormat, @"需要 ZIP64 但找不到 ZIP64 定位器");
                return nil;
            }
        } else {
            uint64_t recordOffset = CdnReadLE64(tailBytes, (NSUInteger)locator + 8);
            NSData *record = CdnReadData(source, recordOffset, 56, error);
            if (record == nil) return nil;
            if (CdnReadLE32(record.bytes, 0) != kEOCD64Signature) {
                if (error != NULL) *error = CdnError(CdnImporterErrorFormat, @"ZIP64 EOCD 记录签名不符");
                return nil;
            }
            entryCount = CdnReadLE64(record.bytes, 32);
            centralSize = CdnReadLE64(record.bytes, 40);
            centralOffset = CdnReadLE64(record.bytes, 48);
        }
    }

    if (centralSize == 0) {
        if (error != NULL) *error = CdnError(CdnImporterErrorFormat, @"中央目录为空");
        return nil;
    }
    // 用减法比较，避免 centralOffset + centralSize 在 uint64 里回绕后骗过检查
    if (centralSize > size || centralOffset > size - centralSize) {
        if (error != NULL) {
            *error = CdnError(CdnImporterErrorFormat, @"中央目录越界（off=%llu size=%llu 文件=%llu）",
                              centralOffset, centralSize, size);
        }
        return nil;
    }
    // 条目数不能超过中央目录的物理容量（每条至少 46 字节），否则后面的 arrayWithCapacity 会巨量分配
    if (entryCount > centralSize / 46) {
        if (error != NULL) {
            *error = CdnError(CdnImporterErrorFormat, @"条目数 %llu 与中央目录容量 %llu 不符",
                              entryCount, centralSize);
        }
        return nil;
    }

    NSData *central = CdnReadData(source, centralOffset, (NSUInteger)centralSize, error);
    if (central == nil) return nil;
    const uint8_t *bytes = central.bytes;

    NSMutableArray<CdnZipEntry *> *entries = [NSMutableArray arrayWithCapacity:(NSUInteger)entryCount];
    NSUInteger cursor = 0;
    for (uint64_t index = 0; index < entryCount; index++) {
        if (cursor + 46 > central.length) {
            if (error != NULL) *error = CdnError(CdnImporterErrorFormat, @"中央目录在第 %llu 条截断", index);
            return nil;
        }
        if (CdnReadLE32(bytes, cursor) != kCentralSignature) {
            if (error != NULL) {
                *error = CdnError(CdnImporterErrorFormat, @"中央目录第 %llu 条签名不符（偏移 %lu）",
                                  index, (unsigned long)cursor);
            }
            return nil;
        }
        uint16_t method = CdnReadLE16(bytes, cursor + 10);
        uint64_t compressedSize = CdnReadLE32(bytes, cursor + 20);
        uint64_t uncompressedSize = CdnReadLE32(bytes, cursor + 24);
        uint16_t nameLength = CdnReadLE16(bytes, cursor + 28);
        uint16_t extraLength = CdnReadLE16(bytes, cursor + 30);
        uint16_t commentLength = CdnReadLE16(bytes, cursor + 32);
        uint64_t localOffset = CdnReadLE32(bytes, cursor + 42);
        uint32_t crc = CdnReadLE32(bytes, cursor + 16);
        if (cursor + 46 + nameLength > central.length) {
            if (error != NULL) *error = CdnError(CdnImporterErrorFormat, @"条目名越界（第 %llu 条）", index);
            return nil;
        }
        NSData *nameData = [central subdataWithRange:NSMakeRange(cursor + 46, nameLength)];
        NSString *name = [[NSString alloc] initWithData:nameData encoding:NSUTF8StringEncoding];
        if (name == nil) name = [[NSString alloc] initWithData:nameData encoding:NSISOLatin1StringEncoding];
        if (name == nil) name = @"";

        // ZIP64 扩展字段（id = 0x0001）：顺序为 uncompressed / compressed / localOffset
        if (uncompressedSize == 0xffffffffULL || compressedSize == 0xffffffffULL || localOffset == 0xffffffffULL) {
            NSUInteger extraStart = cursor + 46 + nameLength;
            NSUInteger extraEnd = extraStart + extraLength;
            NSUInteger extraCursor = extraStart;
            while (extraCursor + 4 <= extraEnd && extraEnd <= central.length) {
                uint16_t headerID = CdnReadLE16(bytes, extraCursor);
                uint16_t dataSize = CdnReadLE16(bytes, extraCursor + 2);
                if (headerID == 0x0001) {
                    NSUInteger dataCursor = extraCursor + 4;
                    NSUInteger limit = extraCursor + 4 + dataSize;
                    if (limit > extraEnd) limit = extraEnd;
                    if (uncompressedSize == 0xffffffffULL && dataCursor + 8 <= limit) {
                        uncompressedSize = CdnReadLE64(bytes, dataCursor);
                        dataCursor += 8;
                    }
                    if (compressedSize == 0xffffffffULL && dataCursor + 8 <= limit) {
                        compressedSize = CdnReadLE64(bytes, dataCursor);
                        dataCursor += 8;
                    }
                    if (localOffset == 0xffffffffULL && dataCursor + 8 <= limit) {
                        localOffset = CdnReadLE64(bytes, dataCursor);
                    }
                    break;
                }
                extraCursor += 4 + dataSize;
            }
        }

        CdnZipEntry *entry = [[CdnZipEntry alloc] initWithName:name
                                                       method:method
                                               compressedSize:compressedSize
                                             uncompressedSize:uncompressedSize
                                                        crc32:crc
                                            localHeaderOffset:localOffset];
        [entries addObject:entry];
        cursor += 46 + nameLength + extraLength + commentLength;
    }

    CdnZipArchive *archive = [[CdnZipArchive alloc] init];
    archive->_source = source;
    archive->_entries = [entries copy];
    return archive;
}

- (nullable CdnZipEntry *)entryNamed:(NSString *)name {
    for (CdnZipEntry *entry in _entries) {
        if ([entry.name isEqualToString:name]) return entry;
    }
    return nil;
}

- (BOOL)dataOffsetOfEntry:(CdnZipEntry *)entry offset:(uint64_t *)offset error:(NSError **)error {
    uint64_t headerOffset = entry.localHeaderOffset;
    if (headerOffset + 30 > _source.length) {
        if (error != NULL) {
            *error = CdnError(CdnImporterErrorFormat, @"本地头越界: %@ (%llu)", entry.name, headerOffset);
        }
        return NO;
    }
    NSData *header = CdnReadData(_source, headerOffset, 30, error);
    if (header == nil) return NO;
    const uint8_t *bytes = header.bytes;
    if (CdnReadLE32(bytes, 0) != kLocalSignature) {
        if (error != NULL) *error = CdnError(CdnImporterErrorFormat, @"本地头签名不符: %@", entry.name);
        return NO;
    }
    uint16_t nameLength = CdnReadLE16(bytes, 26);
    uint16_t extraLength = CdnReadLE16(bytes, 28);
    uint64_t dataOffset = headerOffset + 30 + nameLength + extraLength;
    if (dataOffset + entry.compressedSize > _source.length) {
        if (error != NULL) {
            *error = CdnError(CdnImporterErrorFormat, @"条目数据越界: %@ (data=%llu+%llu 文件=%llu)",
                              entry.name, dataOffset, entry.compressedSize, _source.length);
        }
        return NO;
    }
    if (offset != NULL) *offset = dataOffset;
    return YES;
}

#pragma mark - 解压

static BOOL CdnWriteAll(int fd, const uint8_t *bytes, NSUInteger length, NSError **error) {
    NSUInteger written = 0;
    while (written < length) {
        ssize_t count = write(fd, bytes + written, length - written);
        if (count < 0) {
            if (errno == EINTR) continue;
            if (error != NULL) *error = CdnError(CdnImporterErrorIO, @"写文件失败: %s", strerror(errno));
            return NO;
        }
        written += (NSUInteger)count;
    }
    return YES;
}

- (BOOL)extractEntry:(CdnZipEntry *)entry
              toPath:(NSString *)path
        writtenBytes:(uint64_t *)writtenBytes
               error:(NSError **)error {
    uint64_t dataOffset = 0;
    if (![self dataOffsetOfEntry:entry offset:&dataOffset error:error]) return NO;

    int fd = open(path.fileSystemRepresentation, O_WRONLY | O_CREAT | O_TRUNC, 0644);
    if (fd < 0) {
        if (error != NULL) *error = CdnError(CdnImporterErrorIO, @"建不了文件 %@: %s", path, strerror(errno));
        return NO;
    }

    BOOL ok = YES;
    uint64_t produced = 0;
    uint32_t crc = (uint32_t)crc32(0L, Z_NULL, 0);
    NSData *chunk = nil;   // 循环外持有：zlib 里 next_in 指向它的 bytes，必须活到 inflate 返回

    if (entry.method == 0) {
        uint64_t consumed = 0;
        while (consumed < entry.compressedSize) {
            NSUInteger want = (NSUInteger)MIN((uint64_t)kInputChunk, entry.compressedSize - consumed);
            chunk = [_source readAtOffset:dataOffset + consumed length:want error:error];
            if (chunk == nil) {
                ok = NO;
                break;
            }
            if (chunk.length == 0) {
                if (error != NULL) *error = CdnError(CdnImporterErrorFormat, @"stored 数据提前结束: %@", entry.name);
                ok = NO;
                break;
            }
            consumed += chunk.length;
            if (!CdnWriteAll(fd, chunk.bytes, chunk.length, error)) {
                ok = NO;
                break;
            }
            crc = (uint32_t)crc32(crc, chunk.bytes, (uInt)chunk.length);
            produced += chunk.length;
        }
    } else if (entry.method == 8) {
        z_stream stream;
        memset(&stream, 0, sizeof(stream));
        int status = inflateInit2(&stream, -MAX_WBITS);
        if (status != Z_OK) {
            close(fd);
            unlink(path.fileSystemRepresentation);
            if (error != NULL) *error = CdnError(CdnImporterErrorFormat, @"inflateInit2 失败: %d", status);
            return NO;
        }
        uint8_t *outBuffer = malloc(kOutputChunk);
        if (outBuffer == NULL) {
            inflateEnd(&stream);
            close(fd);
            unlink(path.fileSystemRepresentation);
            if (error != NULL) *error = CdnError(CdnImporterErrorIO, @"分配解压缓冲失败");
            return NO;
        }
        uint64_t inputOffset = 0;
        BOOL finished = NO;
        while (!finished) {
            if (stream.avail_in == 0) {
                if (inputOffset >= entry.compressedSize) break;
                NSUInteger want = (NSUInteger)MIN((uint64_t)kInputChunk, entry.compressedSize - inputOffset);
                chunk = [_source readAtOffset:dataOffset + inputOffset length:want error:error];
                if (chunk == nil) {
                    ok = NO;
                    break;
                }
                if (chunk.length == 0) break;
                inputOffset += chunk.length;
                stream.next_in = (Bytef *)chunk.bytes;
                stream.avail_in = (uInt)chunk.length;
            }
            stream.next_out = outBuffer;
            stream.avail_out = (uInt)kOutputChunk;
            status = inflate(&stream, Z_NO_FLUSH);
            if (status != Z_OK && status != Z_STREAM_END && status != Z_BUF_ERROR) {
                NSString *detail = stream.msg != NULL ? [NSString stringWithUTF8String:stream.msg] : @"";
                if (error != NULL) {
                    *error = CdnError(CdnImporterErrorFormat, @"inflate 失败(%d): %@ %@", status, entry.name, detail);
                }
                ok = NO;
                break;
            }
            NSUInteger count = kOutputChunk - stream.avail_out;
            if (count > 0) {
                if (!CdnWriteAll(fd, outBuffer, count, error)) {
                    ok = NO;
                    break;
                }
                crc = (uint32_t)crc32(crc, outBuffer, (uInt)count);
                produced += count;
            }
            if (status == Z_STREAM_END) finished = YES;
        }
        inflateEnd(&stream);
        free(outBuffer);
        if (ok && !finished) {
            if (error != NULL) *error = CdnError(CdnImporterErrorFormat, @"deflate 流异常结束: %@", entry.name);
            ok = NO;
        }
    } else {
        if (error != NULL) *error = CdnError(CdnImporterErrorFormat, @"不支持的压缩法 %u: %@", entry.method, entry.name);
        ok = NO;
    }

    close(fd);

    if (ok) {
        if (produced != entry.uncompressedSize) {
            if (error != NULL) {
                *error = CdnError(CdnImporterErrorFormat, @"解压长度不符: %@ 期望 %llu 实际 %llu",
                                  entry.name, entry.uncompressedSize, produced);
            }
            ok = NO;
        } else if (crc != entry.crc32) {
            if (error != NULL) {
                *error = CdnError(CdnImporterErrorFormat, @"CRC32 不符: %@ 期望 %08x 实际 %08x",
                                  entry.name, entry.crc32, crc);
            }
            ok = NO;
        }
    }
    if (!ok) {
        unlink(path.fileSystemRepresentation);
        return NO;
    }
    if (writtenBytes != NULL) *writtenBytes = produced;
    return YES;
}

- (nullable id<CdnArchiveSource>)rawSourceForEntry:(CdnZipEntry *)entry error:(NSError **)error {
    if (entry.method != 0) {
        if (error != NULL) *error = CdnError(CdnImporterErrorFormat, @"条目不是 stored，不能直接当窗口源: %@", entry.name);
        return nil;
    }
    uint64_t dataOffset = 0;
    if (![self dataOffsetOfEntry:entry offset:&dataOffset error:error]) return nil;
    return [CdnSubrangeSource sourceWithSource:_source offset:dataOffset length:entry.compressedSize];
}

- (nullable CdnFileSource *)materializeEntry:(CdnZipEntry *)entry
                                      toPath:(NSString *)path
                                writtenBytes:(uint64_t *)writtenBytes
                                       error:(NSError **)error {
    if (![self extractEntry:entry toPath:path writtenBytes:writtenBytes error:error]) return nil;
    return [CdnFileSource sourceWithPath:path error:error];
}

@end
