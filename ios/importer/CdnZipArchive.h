//
//  CdnZipArchive.h
//  CdnImporter
//
//  只读 ZIP：中央目录解析 + 逐条目流式解压（zlib inflate）。
//  解析策略与 Node 参考实现 ios/importer/tools/verify-plan.mjs 的 readZipCentralDirectory
//  逐条对齐（EOCD → ZIP64 EOCD → 中央目录），因为那份实现已在本机 634 个真实归档 /
//  140,417 条条目上验证过。
//

#import <Foundation/Foundation.h>
#import "CdnArchiveSource.h"

NS_ASSUME_NONNULL_BEGIN

@interface CdnZipEntry : NSObject

@property (nonatomic, readonly, copy) NSString *name;
@property (nonatomic, readonly) uint16_t method;              ///< 0 = stored，8 = deflate
@property (nonatomic, readonly) uint64_t compressedSize;
@property (nonatomic, readonly) uint64_t uncompressedSize;
@property (nonatomic, readonly) uint32_t crc32;
@property (nonatomic, readonly) uint64_t localHeaderOffset;

@end

@interface CdnZipArchive : NSObject

/// 解析中央目录；失败（找不到 EOCD / 签名不符 / 越界）时返回 nil 并写 error。
+ (nullable instancetype)archiveWithSource:(id<CdnArchiveSource>)source error:(NSError **)error;

@property (nonatomic, readonly) id<CdnArchiveSource> source;
@property (nonatomic, readonly, copy) NSArray<CdnZipEntry *> *entries;

- (nullable CdnZipEntry *)entryNamed:(NSString *)name;

/// 本地头之后的数据区偏移。任何一步越界/签名不符都会返回 NO。
- (BOOL)dataOffsetOfEntry:(CdnZipEntry *)entry offset:(uint64_t *)offset error:(NSError **)error;

/// 流式解压单条到 path（父目录必须先存在）。CRC32 与解压长度都会和中央目录比对，不符即失败。
- (BOOL)extractEntry:(CdnZipEntry *)entry
              toPath:(NSString *)path
        writtenBytes:(uint64_t *)writtenBytes
               error:(NSError **)error;

/// 仅 method == 0（stored）可用：直接把成员数据当作随机访问窗口（整包 zip 免解压）。
- (nullable id<CdnArchiveSource>)rawSourceForEntry:(CdnZipEntry *)entry error:(NSError **)error;

/// deflate 成员：解到临时文件再给文件源（调用方负责收尾删除）。
- (nullable CdnFileSource *)materializeEntry:(CdnZipEntry *)entry
                                      toPath:(NSString *)path
                                 writtenBytes:(uint64_t *)writtenBytes
                                       error:(NSError **)error;

@end

/// 参考 APK extractZip 的跳过规则：目录项、`.empty`、`.hash` 不落盘。
BOOL CdnZipIsSkippedEntryName(NSString *name);

NS_ASSUME_NONNULL_END
