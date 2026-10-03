//
//  CdnArchiveSource.h
//  CdnImporter
//
//  随机访问抽象：ZIP 中央目录 / TAR 头扫描 / 成员窗口都只依赖这一个协议，
//  因此「散装 zip」「tar 分卷」「整包 zip 里的 zip」可以走同一套解析与解压代码。
//

#import <Foundation/Foundation.h>
#import "CdnImporterConfig.h"

NS_ASSUME_NONNULL_BEGIN

@protocol CdnArchiveSource <NSObject>

/// 逻辑流总字节数
@property (nonatomic, readonly) uint64_t length;

/// 读 [offset, offset+length)；到 EOF 时允许短读（返回更短的 NSData，不报错）。
/// 返回 nil = 真错误（IO 失败），错误写进 error。
- (nullable NSData *)readAtOffset:(uint64_t)offset length:(NSUInteger)length error:(NSError **)error;

@end

#pragma mark - 文件源

@interface CdnFileSource : NSObject <CdnArchiveSource>

+ (nullable instancetype)sourceWithPath:(NSString *)path error:(NSError **)error;

@property (nonatomic, readonly, copy) NSString *path;
- (void)close;

@end

#pragma mark - 内存源

@interface CdnMemorySource : NSObject <CdnArchiveSource>

+ (instancetype)sourceWithData:(NSData *)data;

@end

#pragma mark - 拼接源（tar 分卷 / 多文件一条逻辑流）

@interface CdnConcatSource : NSObject <CdnArchiveSource>

/// sources 顺序即逻辑顺序；空数组会得到长度为 0 的源。
+ (instancetype)sourceWithSources:(NSArray<id<CdnArchiveSource>> *)sources;

@property (nonatomic, readonly, copy) NSArray<id<CdnArchiveSource>> *sources;

@end

#pragma mark - 窗口源（tar 成员 / well-formed 情形下的 ZIP 成员）

@interface CdnSubrangeSource : NSObject <CdnArchiveSource>

/// length 会被裁剪到 source 剩余长度；越界返回 nil。
+ (nullable instancetype)sourceWithSource:(id<CdnArchiveSource>)source
                                   offset:(uint64_t)offset
                                   length:(uint64_t)length;

@property (nonatomic, readonly) uint64_t offset;

@end

#pragma mark - 工具

/// 反复读直到读满 length 或到 EOF；outRead 返回实际读到的字节数。
BOOL CdnReadExactly(id<CdnArchiveSource> source,
                    uint64_t offset,
                    void *buffer,
                    NSUInteger length,
                    NSUInteger * _Nullable outRead,
                    NSError **error);

/// 按需读一段（失败返回 nil），等价于 readAtOffset 但带上「至少要 length 字节」的检查。
NSData * _Nullable CdnReadData(id<CdnArchiveSource> source, uint64_t offset, NSUInteger length, NSError **error);

uint16_t CdnReadLE16(const uint8_t *bytes, NSUInteger offset);
uint32_t CdnReadLE32(const uint8_t *bytes, NSUInteger offset);
uint64_t CdnReadLE64(const uint8_t *bytes, NSUInteger offset);

/// 整源 sha256 的 base64（与 /asset/get_path 快照里的 sha256 字段同口径），用于深度校验。
NSString * _Nullable CdnSHA256Base64OfSource(id<CdnArchiveSource> source, NSError **error);

NS_ASSUME_NONNULL_END
