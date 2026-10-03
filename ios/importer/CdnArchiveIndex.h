//
//  CdnArchiveIndex.h
//  CdnImporter
//
//  把用户从「文件」App 选进来的东西，映射成「计划里的 634 个归档 zip 各自的随机访问源」。
//  支持三种交付形态：
//    1) 散装 zip（最直接，每个文件就是一个计划归档）
//    2) tar / tar 分卷（*.tar、*.tar.part.NN …；tar 里的成员即计划归档）
//    3) 整包 zip（一个 zip 里装着很多 zip；stored 成员直接开窗口，deflate 成员懒物化到临时文件）
//  另有一条兜底：基名没命中计划、但字节数与某个未被认领的计划归档完全一致且能解析成合法 zip → 认领（改名场景）。
//
//  线程约定：索引构建与后续 acquire/release 都由同一个后台线程串行使用，不加锁。
//

#import <Foundation/Foundation.h>
#import "CdnArchiveSource.h"
#import "CdnImportPlan.h"

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, CdnArchiveHandleKind) {
    CdnArchiveHandleKindLooseZip = 0,        ///< 独立 zip 文件
    CdnArchiveHandleKindTarMember,           ///< tar 成员（可能是分卷拼接出来的窗口）
    CdnArchiveHandleKindZipMemberStored,     ///< 整包 zip 里的 stored 成员（窗口）
    CdnArchiveHandleKindZipMemberDeflated,   ///< 整包 zip 里的 deflate 成员（懒物化）
};

@interface CdnArchiveHandle : NSObject

@property (nonatomic, readonly, copy) NSString *basename;      ///< 与计划表对齐的基名
@property (nonatomic, readonly) uint64_t expectedSize;         ///< 计划里的字节数
@property (nonatomic, readonly) CdnArchiveHandleKind kind;
@property (nonatomic, readonly, copy) NSString *origin;        ///< 人类可读来源（路径 / tar 名 / 整包 zip 名）
@property (nonatomic, readonly, copy) NSString *note;          ///< 认领说明（改名、按字节数认领等），可为空串

/// 取得整个归档 zip 的随机访问源；调用方用完必须调用 -releaseSource（物化过的要删临时文件）。
- (nullable id<CdnArchiveSource>)acquireSourceWithError:(NSError **)error;
- (void)releaseSource;

@end

@interface CdnArchiveIndex : NSObject

/// 输入 URL 必须已经由调用方开启 security scope（`startAccessingSecurityScopedResource`）并保持到导入结束。
+ (instancetype)indexWithInputURLs:(NSArray<NSURL *> *)urls
                              plan:(CdnImportPlan *)plan
                        logHandler:(void (^ _Nullable)(NSString *line))logHandler;

@property (nonatomic, readonly, copy) NSDictionary<NSString *, CdnArchiveHandle *> *handles;  ///< 键 = 计划基名
@property (nonatomic, readonly, copy) NSArray<NSString *> *problems;    ///< 硬问题（文件不可用 / 结构损坏）
@property (nonatomic, readonly, copy) NSArray<NSString *> *warnings;    ///< 可疑但可用（字节数不符、改写名认领等）
@property (nonatomic, readonly, copy) NSArray<NSString *> *notes;       ///< 过程说明
@property (nonatomic, readonly, copy) NSArray<NSString *> *unrecognizedInputs;  ///< 完全没参与的文件
@property (nonatomic, readonly) NSUInteger inputFileCount;
@property (nonatomic, readonly) uint64_t recognizedBytes;

- (nullable CdnArchiveHandle *)handleForBasename:(NSString *)basename;

@end

NS_ASSUME_NONNULL_END
