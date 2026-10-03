//
//  CdnImportEngine.m
//  CdnImporter
//
//  四阶段：①索引输入 ②严格检查缺包（缺包即退出，不做破坏性动作）
//          ③按计划顺序解压进 <dummy>/download ④收尾写 info.json + 删 partial 文件。
//
//  为什么顺序如此重要：full 基线（1.4.0）+ 54 步 diff 的语义是「后解压的同名文件覆盖先解压的」，
//  所以必须严格按计划顺序走，不能按用户选文件的顺序或文件名顺序。
//

#import "CdnImportEngine.h"

#import "CdnZipArchive.h"
#import "CdnArchiveSource.h"

static const uint64_t kCdnFreeSpaceSlack = 1ULL << 30;   // 额外留 1 GB 余量

NSString *CdnImportStageName(CdnImportStage stage) {
    switch (stage) {
        case CdnImportStageIdle:       return @"空闲";
        case CdnImportStageIndexing:   return @"索引输入";
        case CdnImportStageExtracting: return @"解压导入";
        case CdnImportStageFinalizing: return @"收尾";
        case CdnImportStageFinished:   return @"完成";
        case CdnImportStageCancelled:  return @"已取消";
        case CdnImportStageFailed:     return @"失败";
    }
    return @"未知";
}

#pragma mark - 进度 / 结果（readonly 公共属性在这里改写成 readwrite）

@interface CdnImportProgress ()
@property (nonatomic) CdnImportStage stage;
@property (nonatomic, copy) NSString *statusText;
@property (nonatomic) NSUInteger archivesDone;
@property (nonatomic) NSUInteger archivesTotal;
@property (nonatomic) NSUInteger filesWritten;
@property (nonatomic) uint64_t compressedDone;
@property (nonatomic) uint64_t compressedTotal;
@property (nonatomic) NSTimeInterval elapsed;
@property (nonatomic) NSTimeInterval remaining;
@property (nonatomic) double fraction;
@end

@implementation CdnImportProgress
@end

@interface CdnImportResult ()
@property (nonatomic) NSUInteger archiveCount;
@property (nonatomic) NSUInteger expectedArchiveCount;
@property (nonatomic, copy) NSArray<NSString *> *missingArchives;
@property (nonatomic, copy) NSArray<NSString *> *warnings;
@property (nonatomic, copy) NSArray<NSString *> *problems;
@property (nonatomic) uint64_t finalBytes;
@property (nonatomic) uint64_t finalFiles;
@property (nonatomic) BOOL totalsMatch;
@property (nonatomic) NSTimeInterval duration;
@property (nonatomic, copy) NSString *infoJsonPath;
@property (nonatomic, copy) NSString *summaryText;
@end

@implementation CdnImportResult
@end

#pragma mark - 引擎

@interface CdnImportEngine ()
@property (nonatomic) BOOL cancelled;
@property (nonatomic, strong) CdnImportPlan *plan;
@property (nonatomic, strong) NSDate *startedAt;
@property (nonatomic, strong) NSMutableArray<NSString *> *warnings;
@property (nonatomic, strong) NSMutableArray<NSString *> *problems;

// 进度状态
@property (nonatomic) CdnImportStage stage;
@property (nonatomic) NSUInteger archivesDone;
@property (nonatomic) uint64_t compressedDone;
@property (nonatomic) NSUInteger filesWritten;
@property (nonatomic) uint64_t compressedTotal;
@property (nonatomic, strong) NSDate *lastReportAt;
@end

@implementation CdnImportEngine

- (instancetype)init {
    self = [super init];
    if (self != nil) {
        _plan = [CdnImportPlan sharedPlan];
        _allowMissingArchives = NO;
        _clearDownloadDirectoryFirst = YES;
        _deepVerify = CdnImporterDeepVerifyEnabled();
        _warnings = [NSMutableArray array];
        _problems = [NSMutableArray array];
        _stage = CdnImportStageIdle;
        _compressedTotal = _plan.totalCompressedBytes;
    }
    return self;
}

- (void)cancel {
    self.cancelled = YES;
}

- (BOOL)isCancelled {
    return self.cancelled;
}

#pragma mark - 日志与进度

- (void)log:(NSString *)format, ... {
    va_list args;
    va_start(args, format);
    NSString *line = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);
    CdnImporterLog(@"[engine] %@", line);
    void (^handler)(NSString *) = self.logHandler;
    if (handler != nil) {
        dispatch_async(dispatch_get_main_queue(), ^{
            handler(line);
        });
    }
}

- (void)reportProgress:(NSString *)statusText force:(BOOL)force {
    NSDate *now = [NSDate date];
    if (!force && _lastReportAt != nil && [now timeIntervalSinceDate:_lastReportAt] < 0.4) return;
    _lastReportAt = now;

    CdnImportProgress *progress = [[CdnImportProgress alloc] init];
    progress.stage = self.stage;
    progress.statusText = statusText;
    progress.archivesDone = self.archivesDone;
    progress.archivesTotal = self.plan.items.count;
    progress.filesWritten = self.filesWritten;
    progress.compressedDone = self.compressedDone;
    progress.compressedTotal = self.compressedTotal;
    progress.elapsed = _startedAt != nil ? [now timeIntervalSinceDate:_startedAt] : 0;
    progress.fraction = self.compressedTotal > 0
        ? MIN(1.0, (double)self.compressedDone / (double)self.compressedTotal)
        : 0;
    if (self.compressedDone > 0 && self.compressedTotal > self.compressedDone) {
        double rate = (double)self.compressedDone / MAX(progress.elapsed, 0.001);
        progress.remaining = (double)(self.compressedTotal - self.compressedDone) / MAX(rate, 1.0);
    } else {
        progress.remaining = -1;
    }

    void (^handler)(CdnImportProgress *) = self.progressHandler;
    if (handler != nil) {
        dispatch_async(dispatch_get_main_queue(), ^{
            handler(progress);
        });
    }
}

#pragma mark - 前置检查

/// 目标盘是否有足够空间：终态 10.19 GB + 1 GB 余量。
/// replacingBytes = 本次导入前就会被清掉的旧资产体积（清空目标目录发生在检查之后，
/// 所以必须把它加回可用量，否则二次导入会被误判成「空间不足」）。
- (BOOL)checkFreeSpaceAtPath:(NSString *)path replacingBytes:(uint64_t)replacingBytes error:(NSError **)error {
    NSError *attributesError = nil;
    NSString *probePath = CdnImporterNearestExistingPath(path);
    if (![probePath isEqualToString:path]) {
        [self log:@"注意：%@ 不存在，按最近的已存在目录统计可用空间：%@", path, probePath];
    }
    NSDictionary<NSFileAttributeKey, id> *attributes = [[NSFileManager defaultManager] attributesOfFileSystemForPath:probePath
                                                                                                                 error:&attributesError];
    if (attributes == nil) {
        if (error != NULL) {
            *error = CdnError(CdnImporterErrorIO, @"无法读取磁盘可用空间（%@，探测路径 %@）：%@",
                              path, probePath, attributesError.localizedDescription ?: @"未知错误");
        }
        return NO;
    }
    uint64_t freeBytes = [attributes[NSFileSystemFreeSize] unsignedLongLongValue] + replacingBytes;
    uint64_t needBytes = self.plan.expectedTotalBytes + kCdnFreeSpaceSlack;
    [self log:@"可用空间 %@%@，需要 %@（终态 %@ + 余量 %@）",
          CdnImporterHumanBytes(freeBytes),
          replacingBytes > 0 ? [NSString stringWithFormat:@"（含清空目标目录后可回收的 %@）",
                                CdnImporterHumanBytes(replacingBytes)] : @"",
          CdnImporterHumanBytes(needBytes),
          CdnImporterHumanBytes(self.plan.expectedTotalBytes), CdnImporterHumanBytes(kCdnFreeSpaceSlack)];
    if (freeBytes < needBytes) {
        if (error != NULL) {
            *error = CdnError(CdnImporterErrorIO,
                              @"空间不足：可用 %@，至少需要 %@（先删掉设备上无用的东西，或把源归档移到别处）",
                              CdnImporterHumanBytes(freeBytes), CdnImporterHumanBytes(needBytes));
        }
        return NO;
    }
    return YES;
}

/// 目标目录里已有的资产体积估计：读 info.json 的 totalSize（客户端自己写的口径），
/// 读不到时按「已有 download/ 目录就当它装满」处理 —— 这个方向只会让空间检查更宽松，
/// 不会因为旧资产而误报（真正精确的检查在清空之后还会再做一次）。
- (uint64_t)accountedBytesInDownloadDirectory:(NSString *)downloadDir {
    NSDictionary<NSString *, id> *info = CdnImporterJSONFromFile(CdnImporterInfoJsonPath(), NULL);
    uint64_t totalSize = [info[@"totalSize"] unsignedLongLongValue];
    if (totalSize > 0) return totalSize;
    if ([[NSFileManager defaultManager] fileExistsAtPath:downloadDir]) return self.plan.expectedTotalBytes;
    return 0;
}

#pragma mark - 主流程

- (nullable CdnImportResult *)runWithInputURLs:(NSArray<NSURL *> *)inputURLs error:(NSError **)error {
    _startedAt = [NSDate date];
    [self.warnings removeAllObjects];
    [self.problems removeAllObjects];
    self.cancelled = NO;

    CdnImportPlan *plan = self.plan;
    [self log:@"开始导入：计划 %lu 个归档 / 压缩态 %@ / 终态 %@ %@",
          (unsigned long)plan.items.count, CdnImporterHumanBytes(plan.totalCompressedBytes),
          CdnImporterHumanCount(plan.expectedTotalFiles), CdnImporterHumanBytes(plan.expectedTotalBytes)];
    [self log:@"目标目录 %@（%@；%@）", CdnImporterAssetDownloadDir(),
          CdnImporterTargetDirectoryIsEvidenceBacked() ? @"已确证" : @"推断",
          CdnImporterTargetDirectoryNote()];
    [self log:@"Local Store %@（%@）", CdnImporterStorageRoot(), CdnImporterStorageRootNote()];

    if (inputURLs.count == 0) {
        if (error != NULL) *error = CdnError(CdnImporterErrorPlan, @"没有选择任何文件或文件夹");
        return nil;
    }

    NSString *dummyDir = CdnImporterAssetDummyDir();
    NSString *downloadDir = CdnImporterAssetDownloadDir();
    NSError *localError = nil;
    if (!CdnImporterEnsureDirectory(dummyDir, &localError)) {
        if (error != NULL) *error = localError;
        return nil;
    }
    if (![self checkFreeSpaceAtPath:dummyDir
                    replacingBytes:[self accountedBytesInDownloadDirectory:downloadDir]
                             error:error]) return nil;

    // security scope：由引擎统一开关，保证索引与解压期间都能读用户选中的位置
    NSMutableArray<NSURL *> *scopedURLs = [NSMutableArray arrayWithCapacity:inputURLs.count];
    for (NSURL *url in inputURLs) {
        if ([url startAccessingSecurityScopedResource]) {
            [scopedURLs addObject:url];
        } else {
            [self log:@"注意：%@ 未能开启 security scope（可能已在作用域内，或不是文件 App 提供的位置）", url.lastPathComponent];
        }
    }

    CdnImportResult *result = nil;
    @try {
        result = [self runLockedWithInputURLs:inputURLs
                                  downloadDir:downloadDir
                                        error:error];
    } @finally {
        for (NSURL *url in scopedURLs) {
            [url stopAccessingSecurityScopedResource];
        }
    }
    return result;
}

- (nullable CdnImportResult *)runLockedWithInputURLs:(NSArray<NSURL *> *)inputURLs
                                         downloadDir:(NSString *)downloadDir
                                               error:(NSError **)error {
    CdnImportPlan *plan = self.plan;

    // ── 阶段 ①：索引 ─────────────────────────────────────────────
    self.stage = CdnImportStageIndexing;
    self.archivesDone = 0;
    self.compressedDone = 0;
    self.filesWritten = 0;
    [self reportProgress:@"正在索引输入文件…" force:YES];

    CdnArchiveIndex *index = [CdnArchiveIndex indexWithInputURLs:inputURLs
                                                            plan:plan
                                                      logHandler:^(NSString *line) {
        [self log:@"%@", line];
    }];
    [self.warnings addObjectsFromArray:index.warnings];
    [self.problems addObjectsFromArray:index.problems];
    [self log:@"索引完成：识别 %lu/%lu 个归档（%@ / %@），输入文件 %lu 个，未识别 %lu 个",
          (unsigned long)index.handles.count, (unsigned long)plan.items.count,
          CdnImporterHumanBytes(index.recognizedBytes), CdnImporterHumanBytes(plan.totalCompressedBytes),
          (unsigned long)index.inputFileCount, (unsigned long)index.unrecognizedInputs.count];
    for (NSString *line in index.problems) [self log:@"索引问题：%@", line];
    for (NSString *line in index.warnings) [self log:@"索引警告：%@", line];

    // ── 阶段 ②：缺包检查（先查后动，缺包时一个字节都不写）───────────
    NSMutableArray<NSString *> *missing = [NSMutableArray array];
    for (CdnImportPlanItem *item in plan.items) {
        if ([index handleForBasename:item.basename] == nil) [missing addObject:item.basename];
    }
    if (missing.count > 0) {
        NSString *preview = [[missing subarrayWithRange:NSMakeRange(0, MIN((NSUInteger)10, missing.count))]
                             componentsJoinedByString:@"\n  "];
        [self log:@"缺少 %lu 个归档：\n  %@%@", (unsigned long)missing.count, preview,
              missing.count > 10 ? @"\n  …" : @""];
    }

    // 预检模式：阶段①②已做完，不写任何文件、不报缺包错误，只把账目交出去。
    // 注意必须在 missing 分支之外 —— 输入完整（missing == 0）才是常态，
    // 放在分支里会让「预检」按钮变成真导入（清空目标目录 + 解压 10 GB）。
    if (self.dryRun) {
        CdnImportResult *previewResult = [[CdnImportResult alloc] init];
        previewResult.archiveCount = index.handles.count;
        previewResult.expectedArchiveCount = plan.items.count;
        previewResult.missingArchives = [missing copy];
        previewResult.warnings = [self.warnings copy];
        previewResult.problems = [self.problems copy];
        previewResult.finalBytes = 0;
        previewResult.finalFiles = 0;
        previewResult.totalsMatch = (missing.count == 0 && index.handles.count == plan.items.count);
        previewResult.duration = [[NSDate date] timeIntervalSinceDate:_startedAt];
        previewResult.infoJsonPath = @"";
        previewResult.summaryText = [NSString stringWithFormat:
                                     @"预检：识别 %lu/%lu 个归档，缺 %lu 个，警告 %lu 条（未写任何文件）",
                                     (unsigned long)index.handles.count, (unsigned long)plan.items.count,
                                     (unsigned long)missing.count, (unsigned long)self.warnings.count];
        self.stage = CdnImportStageFinished;
        [self reportProgress:@"预检完成（未写文件）" force:YES];
        [self log:@"%@", previewResult.summaryText];
        return previewResult;
    }

    if (missing.count > 0) {
        if (!self.allowMissingArchives) {
            if (error != NULL) {
                NSUInteger cap = MIN((NSUInteger)50, missing.count);
                NSArray<NSString *> *details = [missing subarrayWithRange:NSMakeRange(0, cap)];
                if (missing.count > cap) {
                    details = [details arrayByAddingObject:[NSString stringWithFormat:@"…（另有 %lu 个）",
                                                            (unsigned long)(missing.count - cap)]];
                }
                *error = CdnErrorWithDetails(CdnImporterErrorMissingArchives, details,
                                             @"缺少 %lu 个归档（共需 %lu 个），未开始解压。首个缺失：%@",
                                             (unsigned long)missing.count, (unsigned long)plan.items.count,
                                             missing.firstObject ?: @"?");
            }
            self.stage = CdnImportStageFailed;
            [self reportProgress:@"缺归档，已中止（未改动目标目录）" force:YES];
            return nil;
        }
        [self log:@"allowMissingArchives = YES，继续导入（终态会与实体表口径不一致）"];
    }

    // ── 阶段 ③：按计划顺序解压 ────────────────────────────────────
    // 取消检查必须在清空目标目录之前：清空发生在解压前，用户若在索引期间就点了取消，
    // 已经清空却没有删 partial，会同时毁掉旧资产和游戏的重下线索。
    if (self.cancelled) return [self cancelledResultWithError:error];
    self.stage = CdnImportStageExtracting;
    if (self.clearDownloadDirectoryFirst) {
        [self log:@"清空目标目录（保证覆盖语义与终态统计正确）：%@", downloadDir];
        CdnImporterRemoveItem(downloadDir);
    }
    NSError *localError = nil;
    // 清空会把目录本身也删掉，所以先建回来再检查空间：
    // ① 后面的解压要往这里写；② 让空间检查有一个真实存在的探测路径。
    if (!CdnImporterEnsureDirectory(downloadDir, &localError)) {
        if (error != NULL) *error = localError;
        self.stage = CdnImportStageFailed;
        return nil;
    }
    // 清空之后的精确空间检查（此时可用空间是真实的，不再需要估算旧资产体积）
    if (![self checkFreeSpaceAtPath:downloadDir replacingBytes:0 error:error]) {
        self.stage = CdnImportStageFailed;
        return nil;
    }

    NSMutableDictionary<NSString *, NSNumber *> *finalSizes = [NSMutableDictionary dictionaryWithCapacity:150000];
    NSMutableSet<NSString *> *knownDirs = [NSMutableSet setWithCapacity:4096];
    uint64_t finalBytes = 0;
    NSUInteger uniqueFiles = 0;
    NSUInteger archiveCount = 0;

    for (CdnImportPlanItem *item in plan.items) {
        if (self.cancelled) return [self cancelledResultWithError:error];

        CdnArchiveHandle *handle = [index handleForBasename:item.basename];
        if (handle == nil) {
            [self log:@"跳过（缺归档）：%@", item.relativePath];
            continue;
        }

        NSError *sourceError = nil;
        id<CdnArchiveSource> source = [handle acquireSourceWithError:&sourceError];
        if (source == nil) {
            // 打不开就不能当「跳过」处理：少解一个包却照写 info.json、照删 partial，
            // 会产出「残缺资产 + 声称完整」的错误终态，游戏要到运行期才暴露。
            NSString *reason = sourceError.localizedDescription ?: @"未知错误";
            [self log:@"打开归档失败：%@（%@）", item.relativePath, reason];
            if (!self.allowMissingArchives) {
                [handle releaseSource];
                if (error != NULL) {
                    *error = CdnErrorWithDetails(CdnImporterErrorIO, @[item.basename],
                                                 @"%@ 无法打开：%@（未写 info.json，未删 partial）",
                                                 item.basename, reason);
                }
                self.stage = CdnImportStageFailed;
                [self reportProgress:@"归档无法打开，已中止" force:YES];
                return nil;
            }
            [self.warnings addObject:[NSString stringWithFormat:@"%@ 无法打开：%@", item.basename, reason]];
            continue;
        }

        if (source.length != item.size) {
            // 字节数是「没拿错包」的唯一廉价防线（深度 sha256 默认关闭），默认按致命处理
            NSString *reason = [NSString stringWithFormat:@"%@ 字节数不符：实际 %llu / 计划 %llu",
                                item.basename, source.length, item.size];
            [self log:@"%@", reason];
            if (!self.allowMissingArchives) {
                [handle releaseSource];
                if (error != NULL) {
                    *error = CdnErrorWithDetails(CdnImporterErrorFormat, @[item.basename],
                                                 @"%@（同名但内容不对？未写 info.json，未删 partial）", reason);
                }
                self.stage = CdnImportStageFailed;
                [self reportProgress:@"归档字节数不符，已中止" force:YES];
                return nil;
            }
            [self.warnings addObject:reason];
        }

        if (self.deepVerify) {
            NSError *digestError = nil;
            NSString *digest = CdnSHA256Base64OfSource(source, &digestError);
            if (digest == nil || ![digest isEqualToString:item.sha256Base64]) {
                [handle releaseSource];
                if (error != NULL) {
                    *error = CdnError(CdnImporterErrorFormat, @"%@ 的 sha256 与计划不符（深度校验）", item.basename);
                }
                self.stage = CdnImportStageFailed;
                return nil;
            }
        }

        NSError *archiveError = nil;
        CdnZipArchive *archive = [CdnZipArchive archiveWithSource:source error:&archiveError];
        if (archive == nil) {
            [handle releaseSource];
            if (error != NULL) {
                *error = CdnError(CdnImporterErrorFormat, @"%@ 不是合法 ZIP：%@",
                                  item.basename, archiveError.localizedDescription ?: @"未知错误");
            }
            self.stage = CdnImportStageFailed;
            return nil;
        }

        for (CdnZipEntry *entry in archive.entries) {
            if (self.cancelled) {
                [handle releaseSource];
                return [self cancelledResultWithError:error];
            }
            if (CdnZipIsSkippedEntryName(entry.name)) continue;

            // 每个条目一个 autorelease 池：解压是唯一的长循环（十几万次读取 × 256 KB），
            // 每次 readAtOffset: 都会产生一个 autoreleased NSData；整轮都不排空的话，
            // 自动释放对象会一路攒到 GB 量级，进程先撞上内存上限、分配开始失败 ——
            // 真机表现就是「读 … 失败(off=369631328): Bad address」
            // （dataWithLength: 返回 nil → 缓冲区是 NULL → pread 报 EFAULT）。
            BOOL entryOK = NO;
            NSError *entryError = nil;

            @autoreleasepool {
                NSString *relativePath = CdnImporterSanitizeEntryPath(entry.name);
                if (relativePath.length == 0) {
                    entryError = CdnError(CdnImporterErrorFormat, @"%@ 里出现非法条目名：%@", item.basename, entry.name);
                } else {
                    NSString *destination = [downloadDir stringByAppendingPathComponent:relativePath];
                    NSString *parent = [destination stringByDeletingLastPathComponent];
                    NSError *directoryError = nil;
                    if (![knownDirs containsObject:parent] && !CdnImporterEnsureDirectory(parent, &directoryError)) {
                        entryError = directoryError;
                    } else {
                        [knownDirs addObject:parent];

                        uint64_t written = 0;
                        NSError *extractError = nil;
                        if (![archive extractEntry:entry toPath:destination writtenBytes:&written error:&extractError]) {
                            // 保留内层错误码：Format = 归档损坏（CRC/尺寸不符），IO = 磁盘 / 内存问题
                            CdnImporterErrorCode innerCode = (extractError != nil
                                                              && [extractError.domain isEqualToString:CdnImporterErrorDomain])
                                ? (CdnImporterErrorCode)extractError.code : CdnImporterErrorIO;
                            entryError = CdnErrorWithDetails(innerCode, @[item.basename, entry.name],
                                                             @"解压 %@ 的 %@ 失败：%@", item.basename, entry.name,
                                                             extractError.localizedDescription ?: @"未知错误");
                        } else {
                            NSNumber *previous = finalSizes[relativePath];
                            if (previous != nil) {
                                finalBytes -= previous.unsignedLongLongValue;      // 覆盖：先扣掉旧大小
                            } else {
                                uniqueFiles++;
                            }
                            finalSizes[relativePath] = @(written);
                            finalBytes += written;
                            self.filesWritten++;
                            entryOK = YES;

                            if ((self.filesWritten % 512) == 0) {
                                [self reportProgress:[NSString stringWithFormat:@"解压中：%@",
                                                      item.relativePath.lastPathComponent] force:NO];
                            }
                        }
                    }
                }
            }

            if (!entryOK) {
                // 池内只往强局部变量里放错误对象，交回调用方这件事放在池外做 ——
                // 在池里给 NSError ** 赋值，池一 drain 就是一个悬垂指针。
                [handle releaseSource];
                if (error != NULL) {
                    *error = entryError ?: CdnError(CdnImporterErrorFormat, @"解压 %@ 的条目失败", item.basename);
                }
                self.stage = CdnImportStageFailed;
                return nil;
            }
        }

        [handle releaseSource];

        archiveCount++;
        self.archivesDone = archiveCount;
        self.compressedDone += item.size;
        [self log:@"[%lu/%lu] %@ → %lu 个条目（累计 %@ 文件 / %@，内存 %@）",
              (unsigned long)archiveCount, (unsigned long)plan.items.count, item.relativePath,
              (unsigned long)archive.entries.count, CdnImporterHumanCount(uniqueFiles),
              CdnImporterHumanBytes(finalBytes), CdnImporterResidentMemoryDescription()];
        [self reportProgress:[NSString stringWithFormat:@"已完成 %@", item.basename] force:YES];
    }

    // ── 阶段 ④：收尾 ─────────────────────────────────────────────
    self.stage = CdnImportStageFinalizing;

    // 完整性门禁：只有「归档数、字节数、文件数」三项同时对上才认为导入完整。
    // 不完整时默认中止（不写 info.json、不删 partial），否则游戏会直接接受一棵残缺资产树。
    BOOL totalsMatch = (archiveCount == plan.items.count && missing.count == 0
                        && finalBytes == plan.expectedTotalBytes && uniqueFiles == plan.expectedTotalFiles);
    if (!totalsMatch && !self.allowMissingArchives) {
        if (error != NULL) {
            *error = CdnError(CdnImporterErrorFormat,
                              @"导入不完整（归档 %lu/%lu，缺 %lu，文件 %lu/%lu，字节 %llu/%llu）"
                              @"——未写 info.json、未删 partial，游戏会重新走完整下载流程",
                              (unsigned long)archiveCount, (unsigned long)plan.items.count,
                              (unsigned long)missing.count,
                              (unsigned long)uniqueFiles, (unsigned long)plan.expectedTotalFiles,
                              finalBytes, plan.expectedTotalBytes);
        }
        self.stage = CdnImportStageFailed;
        [self reportProgress:@"导入不完整，已中止（未写 info.json）" force:YES];
        [self log:@"⚠️ 导入不完整：%@", (*error).localizedDescription];
        return nil;
    }

    [self reportProgress:@"写入 info.json…" force:YES];

    NSDictionary<NSString *, id> *info = @{
        @"version": plan.targetVersion,
        @"assetRecoveryInfo": @[],
        @"totalSize": @(finalBytes),
        @"assetSizeKind": @"fulfill",
        @"baseUrl": CdnImporterEffectivePatchBase(),
        @"latestModifiedTimeOfArchive": CDN_IMPORT_ARCHIVE_TIME,
    };
    NSString *infoPath = CdnImporterInfoJsonPath();
    NSError *writeError = nil;
    if (!CdnImporterWriteJSONAtomically(info, infoPath, &writeError)) {
        if (error != NULL) {
            *error = CdnError(CdnImporterErrorIO, @"写 info.json 失败：%@", writeError.localizedDescription ?: @"未知错误");
        }
        self.stage = CdnImportStageFailed;
        return nil;
    }
    [self log:@"已写 info.json：version=%@ totalSize=%@ assetSizeKind=fulfill assetRecoveryInfo=[]",
          plan.targetVersion, CdnImporterHumanBytes(finalBytes)];

    if (totalsMatch) {
        for (NSString *partialPath in CdnImporterPartialFilePaths()) {
            if ([[NSFileManager defaultManager] fileExistsAtPath:partialPath]) {
                BOOL removed = CdnImporterRemoveItem(partialPath);
                [self log:@"%@ partial 文件：%@", removed ? @"已删除" : @"删除失败", partialPath];
            }
        }
    } else {
        // 只可能走到这里：allowMissingArchives = YES 且终态不完整。
        // 这种情况下保留 partial —— 它是客户端自己的「没下完」标记，删了游戏就会把残缺资产当完整。
        [self log:@"⚠️ 终态不完整（allowMissingArchives）：保留 %lu 个 partial 文件，让游戏重新走下载流程",
              (unsigned long)CdnImporterPartialFilePaths().count];
    }

    // 10 GB 级别的资产不该进 iCloud 备份（客户端自己也有 preventBackup 逻辑）
    NSURL *downloadURL = [NSURL fileURLWithPath:downloadDir isDirectory:YES];
    [downloadURL setResourceValue:@YES forKey:NSURLIsExcludedFromBackupKey error:NULL];

    CdnImportResult *result = [[CdnImportResult alloc] init];
    result.archiveCount = archiveCount;
    result.expectedArchiveCount = plan.items.count;
    result.missingArchives = [missing copy];
    result.warnings = [self.warnings copy];
    result.problems = [self.problems copy];
    result.finalBytes = finalBytes;
    result.finalFiles = uniqueFiles;
    result.totalsMatch = totalsMatch;
    result.duration = [[NSDate date] timeIntervalSinceDate:_startedAt];
    result.infoJsonPath = infoPath;
    result.summaryText = [self summaryTextForResult:result];

    self.stage = CdnImportStageFinished;
    [self reportProgress:@"导入完成" force:YES];
    [self log:@"完成：%@", result.summaryText];
    if (!totalsMatch) {
        [self log:@"⚠️ 终态与实体表口径不一致（期望 %@ 文件 / %@，实际 %@ 文件 / %@）——若使用了「缺包也继续」，这是预期的",
              CdnImporterHumanCount(plan.expectedTotalFiles), CdnImporterHumanBytes(plan.expectedTotalBytes),
              CdnImporterHumanCount(uniqueFiles), CdnImporterHumanBytes(finalBytes)];
    }
    return result;
}

- (nullable CdnImportResult *)cancelledResultWithError:(NSError **)error {
    self.stage = CdnImportStageCancelled;
    [self log:@"已取消（目标目录可能不完整；partial 文件保留，游戏会重新走下载流程）"];
    [self reportProgress:@"已取消" force:YES];
    if (error != NULL) *error = CdnError(CdnImporterErrorCancelled, @"用户取消了导入");
    return nil;
}

- (NSString *)summaryTextForResult:(CdnImportResult *)result {
    CdnImportPlan *plan = self.plan;
    NSMutableString *text = [NSMutableString string];
    [text appendFormat:@"归档 %lu/%lu，文件 %@（%@）",
     (unsigned long)result.archiveCount, (unsigned long)result.expectedArchiveCount,
     CdnImporterHumanCount(result.finalFiles), CdnImporterHumanBytes(result.finalBytes)];
    if (result.missingArchives.count > 0) {
        [text appendFormat:@"；缺 %lu 个归档", (unsigned long)result.missingArchives.count];
    }
    [text appendFormat:@"；耗时 %.1f 分钟", result.duration / 60.0];
    [text appendFormat:@"；终态%@实体表口径（%@ 文件 / %@）",
     result.totalsMatch ? @"符合" : @"不符合",
     CdnImporterHumanCount(plan.expectedTotalFiles), CdnImporterHumanBytes(plan.expectedTotalBytes)];
    if (result.warnings.count > 0) {
        [text appendFormat:@"；警告 %lu 条", (unsigned long)result.warnings.count];
    }
    return text;
}

@end
