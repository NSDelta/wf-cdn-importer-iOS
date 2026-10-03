//
//  CdnImportEngine.h
//  CdnImporter
//
//  导入引擎：索引输入 → 校验归档 → 按计划顺序解压到 <dummy>/download/ → 写 info.json 并清 partial 文件。
//  同步阻塞执行（10 GB 级别），调用方放后台队列；进度与日志通过 block 回调。
//

#import <Foundation/Foundation.h>
#import "CdnArchiveIndex.h"
#import "CdnImportPlan.h"

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, CdnImportStage) {
    CdnImportStageIdle = 0,
    CdnImportStageIndexing,
    CdnImportStageExtracting,
    CdnImportStageFinalizing,
    CdnImportStageFinished,
    CdnImportStageCancelled,
    CdnImportStageFailed,
};

/// 阶段名（日志与面板展示用）。
NSString *CdnImportStageName(CdnImportStage stage);

@interface CdnImportProgress : NSObject
@property (nonatomic, readonly) CdnImportStage stage;
@property (nonatomic, readonly, copy) NSString *statusText;
@property (nonatomic, readonly) NSUInteger archivesDone;
@property (nonatomic, readonly) NSUInteger archivesTotal;
@property (nonatomic, readonly) NSUInteger filesWritten;
@property (nonatomic, readonly) uint64_t compressedDone;   ///< 已处理归档的压缩态字节
@property (nonatomic, readonly) uint64_t compressedTotal;  ///< 计划压缩态合计
@property (nonatomic, readonly) NSTimeInterval elapsed;
@property (nonatomic, readonly) NSTimeInterval remaining;  ///< 估算，未知为 -1
@property (nonatomic, readonly) double fraction;
@end

@interface CdnImportResult : NSObject
@property (nonatomic, readonly) NSUInteger archiveCount;          ///< 实际导入的归档数
@property (nonatomic, readonly) NSUInteger expectedArchiveCount;  ///< 计划归档数（634）
@property (nonatomic, readonly, copy) NSArray<NSString *> *missingArchives;
@property (nonatomic, readonly, copy) NSArray<NSString *> *warnings;
@property (nonatomic, readonly, copy) NSArray<NSString *> *problems;
@property (nonatomic, readonly) uint64_t finalBytes;              ///< 写出后 <download> 的终态字节数
@property (nonatomic, readonly) uint64_t finalFiles;              ///< 终态文件数
@property (nonatomic, readonly) BOOL totalsMatch;                 ///< 与实体表口径（10,191,161,030 / 137,820）一致
@property (nonatomic, readonly) NSTimeInterval duration;
@property (nonatomic, readonly, copy) NSString *infoJsonPath;
@property (nonatomic, readonly, copy) NSString *summaryText;
@end

@interface CdnImportEngine : NSObject

/// 缺归档时是否继续（默认 NO：缺一个就报 CdnImporterErrorMissingArchives，且不动 <download>）。
@property (nonatomic) BOOL allowMissingArchives;
/// 开始解压前是否清空 <download>（默认 YES；清空才能保证终态统计与覆盖语义正确）。
@property (nonatomic) BOOL clearDownloadDirectoryFirst;
/// 是否对被导入的归档整包做 sha256 深度校验（默认取 CdnImporterDeepVerifyEnabled()）。
@property (nonatomic) BOOL deepVerify;
/// 只做阶段①②（索引 + 缺包检查），一个字节都不写 —— 选完文件先「预检」用。
@property (nonatomic) BOOL dryRun;

@property (nonatomic, copy, nullable) void (^progressHandler)(CdnImportProgress *progress);
@property (nonatomic, copy, nullable) void (^logHandler)(NSString *line);

- (void)cancel;
@property (nonatomic, readonly) BOOL isCancelled;

/// 同步执行；成功返回结果，失败返回 nil 并填 error。取消 → CdnImporterErrorCancelled。
- (nullable CdnImportResult *)runWithInputURLs:(NSArray<NSURL *> *)inputURLs error:(NSError **)error;

@end

NS_ASSUME_NONNULL_END
