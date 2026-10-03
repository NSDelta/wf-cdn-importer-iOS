//
//  CdnArchiveIndex.m
//

#import "CdnArchiveIndex.h"

#import "CdnImporterConfig.h"
#import "CdnTarIndex.h"
#import "CdnZipArchive.h"

static const NSUInteger kCdnIndexMaxDepth = 4;
static const NSUInteger kCdnIndexMaxInputFiles = 5000;

#pragma mark - 前置声明

NSString *CdnTarGroupKeyForName(NSString *name);
NSInteger CdnTarPartIndexForName(NSString *name);
uint64_t CdnFileSizeAtPath(NSString *path);
NSString *CdnMaterializePathForBasename(NSString *basename);

@interface CdnArchiveIndexBuilder : NSObject
@property (nonatomic, strong) CdnImportPlan *plan;
@property (nonatomic, copy, nullable) void (^log)(NSString *line);
@property (nonatomic, strong) NSMutableDictionary<NSString *, CdnArchiveHandle *> *handles;
@property (nonatomic, strong) NSMutableArray<NSString *> *problems;
@property (nonatomic, strong) NSMutableArray<NSString *> *warnings;
@property (nonatomic, strong) NSMutableArray<NSString *> *notes;
@property (nonatomic, strong) NSMutableArray<NSString *> *unrecognized;
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSMutableArray<NSURL *> *> *tarGroups;
@property (nonatomic, strong) NSMutableSet<NSString *> *tarPartKeys;
@property (nonatomic, strong) NSMutableArray<NSURL *> *zipFiles;
@property (nonatomic, strong) NSMutableSet<NSString *> *consumedPaths;
@property (nonatomic) NSUInteger inputFileCount;
- (void)collectURL:(NSURL *)url depth:(NSUInteger)depth;
- (void)processTarGroups;
- (void)processZipFiles;
- (void)applySizeFallback;
- (CdnArchiveIndex *)finish;
@end

#pragma mark - 散装 zip：懒开懒关（不能同时持有 634 个 fd）

@interface CdnLooseFileHandle : CdnArchiveHandle
@property (nonatomic, copy) NSString *path;
@property (nonatomic, strong, nullable) CdnFileSource *source;
@end

#pragma mark - 整包 zip 的 deflate 成员：物化到临时文件

@interface CdnZipMemberHandle : CdnArchiveHandle
@property (nonatomic, strong) CdnZipArchive *bundleArchive;
@property (nonatomic, strong) CdnZipEntry *entry;
@property (nonatomic, strong, nullable) CdnFileSource *materialized;
@end

#pragma mark - 基类

@interface CdnArchiveHandle ()
@property (nonatomic, strong, nullable) id<CdnArchiveSource> immediateSource;
@end

@implementation CdnArchiveHandle

- (instancetype)initWithBasename:(NSString *)basename
                    expectedSize:(uint64_t)size
                            kind:(CdnArchiveHandleKind)kind
                          origin:(NSString *)origin
                            note:(NSString *)note {
    self = [super init];
    if (self != nil) {
        _basename = [basename copy];
        _expectedSize = size;
        _kind = kind;
        _origin = [origin copy] ?: @"";
        _note = [note copy] ?: @"";
    }
    return self;
}

- (nullable id<CdnArchiveSource>)acquireSourceWithError:(NSError **)error {
    if (_immediateSource == nil) {
        if (error != NULL) *error = CdnError(CdnImporterErrorPlan, @"归档 %@ 没有可用数据源", _basename);
        return nil;
    }
    return _immediateSource;
}

- (void)releaseSource {
}

- (NSString *)description {
    NSArray<NSString *> *kinds = @[ @"散装", @"tar成员", @"整包stored", @"整包deflate" ];
    return [NSString stringWithFormat:@"<CdnArchiveHandle %@ %@ %llu 字节 ← %@%@>",
            _basename,
            kinds[(NSUInteger)_kind],
            _expectedSize,
            _origin,
            _note.length > 0 ? [NSString stringWithFormat:@" (%@)", _note] : @""];
}

@end

@implementation CdnLooseFileHandle

- (nullable id<CdnArchiveSource>)acquireSourceWithError:(NSError **)error {
    if (_source == nil) {
        _source = [CdnFileSource sourceWithPath:_path error:error];
        if (_source == nil) return nil;
    }
    return _source;
}

- (void)releaseSource {
    [_source close];
    _source = nil;
}

@end

@implementation CdnZipMemberHandle

- (nullable id<CdnArchiveSource>)acquireSourceWithError:(NSError **)error {
    if (_materialized != nil) return _materialized;
    NSString *target = CdnMaterializePathForBasename(self.basename);
    if (!CdnImporterEnsureDirectory(target.stringByDeletingLastPathComponent, error)) return nil;
    CdnImporterRemoveItem(target);
    uint64_t written = 0;
    if (![_bundleArchive extractEntry:_entry toPath:target writtenBytes:&written error:error]) return nil;
    CdnFileSource *source = [CdnFileSource sourceWithPath:target error:error];
    if (source == nil) {
        CdnImporterRemoveItem(target);
        return nil;
    }
    _materialized = source;
    CdnImporterLog(@"[索引] 物化整包成员 %@（%llu 字节）", self.basename, written);
    return source;
}

- (void)releaseSource {
    [_materialized close];
    _materialized = nil;
    CdnImporterRemoveItem(CdnMaterializePathForBasename(self.basename));
}

@end

#pragma mark - 索引

@interface CdnArchiveIndex ()
@property (nonatomic, readwrite, copy) NSDictionary<NSString *, CdnArchiveHandle *> *handles;
@property (nonatomic, readwrite, copy) NSArray<NSString *> *problems;
@property (nonatomic, readwrite, copy) NSArray<NSString *> *warnings;
@property (nonatomic, readwrite, copy) NSArray<NSString *> *notes;
@property (nonatomic, readwrite, copy) NSArray<NSString *> *unrecognizedInputs;
@property (nonatomic, readwrite) NSUInteger inputFileCount;
@property (nonatomic, readwrite) uint64_t recognizedBytes;
@end

@implementation CdnArchiveIndex

+ (instancetype)indexWithInputURLs:(NSArray<NSURL *> *)urls
                              plan:(CdnImportPlan *)plan
                        logHandler:(void (^ _Nullable)(NSString *))logHandler {
    CdnImportPlan *effectivePlan = plan ?: [CdnImportPlan sharedPlan];
    CdnArchiveIndexBuilder *builder = [[CdnArchiveIndexBuilder alloc] init];
    builder.plan = effectivePlan;
    builder.log = logHandler;

    for (NSURL *url in urls) {
        @autoreleasepool {
            [builder collectURL:url depth:0];
        }
    }
    [builder processTarGroups];
    [builder processZipFiles];
    [builder applySizeFallback];

    CdnArchiveIndex *index = [builder finish];
    if (logHandler != NULL) {
        logHandler([NSString stringWithFormat:@"索引完成：识别 %lu/%lu 个计划归档，%.2f GB；输入文件 %lu 个",
                    (unsigned long)index.handles.count,
                    (unsigned long)effectivePlan.items.count,
                    index.recognizedBytes / 1e9,
                    (unsigned long)index.inputFileCount]);
    }
    CdnImporterLog(@"[索引] 识别 %lu/%lu 个归档，警告 %lu，问题 %lu，未参与输入 %lu",
                   (unsigned long)index.handles.count,
                   (unsigned long)effectivePlan.items.count,
                   (unsigned long)index.warnings.count,
                   (unsigned long)index.problems.count,
                   (unsigned long)index.unrecognizedInputs.count);
    return index;
}

- (nullable CdnArchiveHandle *)handleForBasename:(NSString *)basename {
    return _handles[basename];
}

@end

#pragma mark - 构建器

@implementation CdnArchiveIndexBuilder

- (instancetype)init {
    self = [super init];
    if (self != nil) {
        _handles = [NSMutableDictionary dictionary];
        _problems = [NSMutableArray array];
        _warnings = [NSMutableArray array];
        _notes = [NSMutableArray array];
        _unrecognized = [NSMutableArray array];
        _tarGroups = [NSMutableDictionary dictionary];
        _tarPartKeys = [NSMutableSet set];
        _zipFiles = [NSMutableArray array];
        _consumedPaths = [NSMutableSet set];
        _plan = [CdnImportPlan sharedPlan];
    }
    return self;
}

- (void)say:(NSString *)format, ... NS_FORMAT_FUNCTION(1, 2) {
    va_list args;
    va_start(args, format);
    NSString *line = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);
    [_notes addObject:line];
    CdnImporterLog(@"[索引] %@", line);
    if (self.log != NULL) self.log(line);
}

- (void)collectURL:(NSURL *)url depth:(NSUInteger)depth {
    if (url == nil || !url.isFileURL) {
        [_unrecognized addObject:url.absoluteString ?: @"(非文件 URL)"];
        return;
    }
    NSFileManager *manager = [NSFileManager defaultManager];
    BOOL isDirectory = NO;
    NSString *path = url.path;
    if (path.length == 0 || ![manager fileExistsAtPath:path isDirectory:&isDirectory]) {
        [_problems addObject:[NSString stringWithFormat:@"输入不存在或无法访问：%@", url.lastPathComponent ?: url.absoluteString]];
        return;
    }
    if (!isDirectory) {
        [self ingestFileURL:url];
        return;
    }
    if (depth > kCdnIndexMaxDepth) {
        [self say:@"跳过过深的目录：%@", url.lastPathComponent];
        return;
    }

    NSDirectoryEnumerator<NSURL *> *enumerator =
        [manager enumeratorAtURL:url
      includingPropertiesForKeys:@[ NSURLIsDirectoryKey, NSURLFileSizeKey ]
                         options:NSDirectoryEnumerationSkipsHiddenFiles
                    errorHandler:^BOOL(NSURL *badURL, NSError *error) {
                        [self.problems addObject:[NSString stringWithFormat:@"枚举失败：%@（%@）",
                                                  badURL.lastPathComponent, error.localizedDescription]];
                        return YES;
                    }];
    for (NSURL *child in enumerator) {
        if (self.inputFileCount >= kCdnIndexMaxInputFiles) {
            [self say:@"输入文件数达到上限 %lu，其余忽略", (unsigned long)kCdnIndexMaxInputFiles];
            break;
        }
        NSNumber *isDirValue = nil;
        if (![child getResourceValue:&isDirValue forKey:NSURLIsDirectoryKey error:NULL]) continue;
        if (isDirValue.boolValue) {
            if (enumerator.level >= kCdnIndexMaxDepth) [enumerator skipDescendents];
            continue;
        }
        NSString *name = child.lastPathComponent;
        if (name.length == 0 || [name hasPrefix:@"."] || [name isEqualToString:@"__MACOSX"]) continue;
        [self ingestFileURL:child];
    }
}

- (void)ingestFileURL:(NSURL *)url {
    NSString *path = url.path;
    if (path.length == 0 || [_consumedPaths containsObject:path]) return;
    [_consumedPaths addObject:path];
    self.inputFileCount++;

    NSString *name = url.lastPathComponent;
    NSString *lower = name.lowercaseString;

    if ([lower hasSuffix:@".zip"]) {
        [_zipFiles addObject:url];
        return;
    }
    NSString *tarKey = CdnTarGroupKeyForName(name);
    if (tarKey != nil) {
        NSInteger partIndex = CdnTarPartIndexForName(name);
        NSMutableArray<NSURL *> *group = _tarGroups[tarKey];
        if (group == nil) {
            group = [NSMutableArray array];
            _tarGroups[tarKey] = group;
        }
        [group addObject:url];
        NSString *partKey = [tarKey stringByAppendingFormat:@"#%ld", (long)partIndex];
        if ([_tarPartKeys containsObject:partKey]) {
            [_warnings addObject:[NSString stringWithFormat:@"tar 分卷序号重复：%@", name]];
        }
        [_tarPartKeys addObject:partKey];
        return;
    }
    [_unrecognized addObject:name];
}

#pragma mark tar

- (void)processTarGroups {
    for (NSString *key in _tarGroups.allKeys) {
        NSMutableArray<NSURL *> *parts = _tarGroups[key];
        [parts sortUsingComparator:^NSComparisonResult(NSURL *a, NSURL *b) {
            NSInteger ia = CdnTarPartIndexForName(a.lastPathComponent);
            NSInteger ib = CdnTarPartIndexForName(b.lastPathComponent);
            if (ia == ib) return NSOrderedSame;
            return ia < ib ? NSOrderedAscending : NSOrderedDescending;
        }];

        NSMutableArray<id<CdnArchiveSource>> *sources = [NSMutableArray array];
        NSError *error = nil;
        for (NSURL *part in parts) {
            CdnFileSource *source = [CdnFileSource sourceWithPath:part.path error:&error];
            if (source == nil) {
                [_problems addObject:[NSString stringWithFormat:@"tar 分卷打不开：%@（%@）",
                                      part.lastPathComponent, error.localizedDescription]];
                break;
            }
            [sources addObject:source];
        }
        if (sources.count != parts.count) continue;

        id<CdnArchiveSource> concat = sources.count == 1 ? sources.firstObject : [CdnConcatSource sourceWithSources:sources];
        CdnTarIndex *tar = [CdnTarIndex indexWithSource:concat error:&error];
        if (tar == nil) {
            [_problems addObject:[NSString stringWithFormat:@"tar 索引失败：%@（%@）", key, error.localizedDescription]];
            continue;
        }
        for (NSString *note in tar.notes) [self say:@"%@：%@", key, note];
        [self say:@"tar %@：%lu 个分卷 / %.2f GB → %lu 个成员",
             key, (unsigned long)parts.count, concat.length / 1e9, (unsigned long)tar.members.count];

        NSUInteger matched = 0;
        for (CdnTarMember *member in tar.members) {
            if (!member.isRegularFile) continue;
            NSString *basename = member.name.lastPathComponent;
            CdnImportPlanItem *item = self.plan.itemsByBasename[basename];
            if (item == nil) continue;
            if (self.handles[basename] != nil) {
                [_warnings addObject:[NSString stringWithFormat:@"tar 内重复归档（后者忽略）：%@", basename]];
                continue;
            }
            if (member.size != item.size) {
                [_warnings addObject:[NSString stringWithFormat:@"tar 成员字节数与计划不符：%@（tar %llu / 计划 %llu）",
                                      basename, member.size, item.size]];
            }
            CdnArchiveHandle *handle = [[CdnArchiveHandle alloc] initWithBasename:basename
                                                                    expectedSize:item.size
                                                                            kind:CdnArchiveHandleKindTarMember
                                                                          origin:[NSString stringWithFormat:@"%@ 内 %@", key, member.name]
                                                                            note:@""];
            handle.immediateSource = [CdnSubrangeSource sourceWithSource:concat offset:member.dataOffset length:member.size];
            self.handles[basename] = handle;
            matched++;
        }
        if (matched == 0) {
            [_unrecognized addObject:[NSString stringWithFormat:@"%@（tar 里没有计划内的归档）", key]];
        } else {
            [self say:@"tar %@：命中计划归档 %lu 个", key, (unsigned long)matched];
        }
    }
}

#pragma mark zip

- (void)processZipFiles {
    for (NSURL *url in _zipFiles) {
        @autoreleasepool {
            [self ingestZipFileURL:url];
        }
    }
}

- (void)ingestZipFileURL:(NSURL *)url {
    NSString *path = url.path;
    NSString *name = url.lastPathComponent;
    uint64_t fileSize = CdnFileSizeAtPath(path);
    CdnImportPlanItem *item = self.plan.itemsByBasename[name];

    if (item != nil) {
        if (self.handles[name] != nil) {
            [_warnings addObject:[NSString stringWithFormat:@"重复的归档文件（忽略后者）：%@", name]];
            return;
        }
        CdnLooseFileHandle *handle = [[CdnLooseFileHandle alloc] initWithBasename:name
                                                                    expectedSize:item.size
                                                                            kind:CdnArchiveHandleKindLooseZip
                                                                          origin:path
                                                                            note:@""];
        handle.path = path;
        self.handles[name] = handle;
        return;
    }

    // 基名没命中 → 当整包 zip 试：成员（末段基名）命中计划才有意义
    NSError *error = nil;
    CdnFileSource *source = [CdnFileSource sourceWithPath:path error:&error];
    if (source == nil) {
        [_problems addObject:[NSString stringWithFormat:@"打不开：%@（%@）", name, error.localizedDescription]];
        return;
    }
    CdnZipArchive *archive = [CdnZipArchive archiveWithSource:source error:&error];
    if (archive == nil) {
        [source close];
        [_unrecognized addObject:[NSString stringWithFormat:@"%@（不是合法 zip）", name]];
        return;
    }

    NSUInteger matched = 0;
    for (CdnZipEntry *entry in archive.entries) {
        if (CdnZipIsSkippedEntryName(entry.name)) continue;
        NSString *basename = entry.name.lastPathComponent;
        CdnImportPlanItem *planItem = self.plan.itemsByBasename[basename];
        if (planItem == nil || self.handles[basename] != nil) continue;
        if (entry.uncompressedSize != planItem.size) {
            [_warnings addObject:[NSString stringWithFormat:@"整包成员字节数与计划不符：%@（包内 %llu / 计划 %llu）",
                                  basename, entry.uncompressedSize, planItem.size]];
        }
        CdnArchiveHandle *handle = nil;
        if (entry.method == 0) {
            id<CdnArchiveSource> window = [archive rawSourceForEntry:entry error:&error];
            if (window == nil) {
                [_problems addObject:[NSString stringWithFormat:@"整包成员窗口失败：%@（%@）",
                                      basename, error.localizedDescription]];
                continue;
            }
            handle = [[CdnArchiveHandle alloc] initWithBasename:basename
                                                   expectedSize:planItem.size
                                                           kind:CdnArchiveHandleKindZipMemberStored
                                                         origin:[NSString stringWithFormat:@"%@ 内 %@", name, entry.name]
                                                           note:@""];
            handle.immediateSource = window;
        } else if (entry.method == 8) {
            CdnZipMemberHandle *member = [[CdnZipMemberHandle alloc] initWithBasename:basename
                                                                         expectedSize:planItem.size
                                                                                 kind:CdnArchiveHandleKindZipMemberDeflated
                                                                               origin:[NSString stringWithFormat:@"%@ 内 %@", name, entry.name]
                                                                                 note:@""];
            member.bundleArchive = archive;
            member.entry = entry;
            handle = member;
        } else {
            [_problems addObject:[NSString stringWithFormat:@"整包成员压缩法不支持：%@（method=%u）", basename, entry.method]];
            continue;
        }
        self.handles[basename] = handle;
        matched++;
    }

    if (matched > 0) {
        [self say:@"整包 zip %@（%.2f GB）：命中计划归档 %lu 个", name, fileSize / 1e9, (unsigned long)matched];
        return;
    }
    [source close];
    [_unrecognized addObject:name];
}

/// 兜底：基名没命中、但字节数与某个未认领的计划归档完全一致，且能当合法 zip 解析 → 认领（改名/浏览器加后缀场景）。
- (void)applySizeFallback {
    NSArray<NSURL *> *candidates = [_zipFiles filteredArrayUsingPredicate:
        [NSPredicate predicateWithBlock:^BOOL(NSURL *url, NSDictionary *bindings) {
            NSString *name = url.lastPathComponent;
            return [self.unrecognized containsObject:name];
        }]];

    for (NSURL *url in candidates) {
        NSString *path = url.path;
        NSString *name = url.lastPathComponent;
        uint64_t fileSize = CdnFileSizeAtPath(path);
        NSString *sizeKey = [NSString stringWithFormat:@"%llu", fileSize];
        NSArray<CdnImportPlanItem *> *bucket = self.plan.itemsBySize[sizeKey];
        if (bucket.count == 0) continue;

        NSMutableArray<CdnImportPlanItem *> *unclaimed = [NSMutableArray array];
        for (CdnImportPlanItem *item in bucket) {
            if (self.handles[item.basename] == nil) [unclaimed addObject:item];
        }
        if (unclaimed.count == 0) continue;

        // 同尺寸的未认领项可能不止一个（计划里真有 111 字节 × 54 个空包桶），
        // 所以必须用 sha256 精确认领，不能取「第一个」。
        NSError *error = nil;
        CdnFileSource *source = [CdnFileSource sourceWithPath:path error:&error];
        if (source == nil) continue;
        NSString *digest = CdnSHA256Base64OfSource(source, &error);
        CdnImportPlanItem *target = nil;
        if (digest != nil) {
            for (CdnImportPlanItem *item in unclaimed) {
                if ([item.sha256Base64 isEqualToString:digest]) {
                    target = item;
                    break;
                }
            }
        }
        if (target == nil) {
            [source close];
            continue;
        }
        CdnZipArchive *archive = [CdnZipArchive archiveWithSource:source error:&error];
        [source close];
        if (archive == nil) continue;

        CdnLooseFileHandle *handle = [[CdnLooseFileHandle alloc] initWithBasename:target.basename
                                                                    expectedSize:target.size
                                                                            kind:CdnArchiveHandleKindLooseZip
                                                                          origin:path
                                                                            note:[NSString stringWithFormat:@"按字节数 + sha256 认领（原文件名 %@）", name]];
        handle.path = path;
        self.handles[target.basename] = handle;
        [_unrecognized removeObject:name];
        [self say:@"按字节数认领：%@ → %@（%llu 字节）", name, target.basename, fileSize];
    }
}

- (CdnArchiveIndex *)finish {
    CdnArchiveIndex *index = [[CdnArchiveIndex alloc] init];
    index.handles = [self.handles copy];
    index.problems = [self.problems copy];
    index.warnings = [self.warnings copy];
    index.notes = [self.notes copy];
    index.unrecognizedInputs = [self.unrecognized copy];
    index.inputFileCount = self.inputFileCount;
    uint64_t bytes = 0;
    for (CdnArchiveHandle *handle in self.handles.allValues) bytes += handle.expectedSize;
    index.recognizedBytes = bytes;
    return index;
}

@end

#pragma mark - 小工具

NSString *CdnMaterializePathForBasename(NSString *basename) {
    return [[CdnImporterTempDirectory() stringByAppendingPathComponent:@"materialize"] stringByAppendingPathComponent:basename];
}

NSString *CdnTarGroupKeyForName(NSString *name) {
    // 大小写不敏感地找分隔符，但一律在原串上取范围：
    // lowercaseString 遇到 U+0130 这类字符会变长，拿它算出的 range 去切原串会错位。
    NSRange range = [name rangeOfString:@".tar.part." options:NSCaseInsensitiveSearch];
    if (range.location != NSNotFound) return [name substringToIndex:range.location + 4];
    if ([name.lowercaseString hasSuffix:@".tar"]) return name;
    return nil;
}

NSInteger CdnTarPartIndexForName(NSString *name) {
    NSRange range = [name rangeOfString:@".tar.part." options:NSCaseInsensitiveSearch];
    if (range.location == NSNotFound) return -1;
    NSString *suffix = [name substringFromIndex:NSMaxRange(range)];
    if (suffix.length == 0) return -1;
    for (NSUInteger index = 0; index < suffix.length; index++) {
        unichar character = [suffix characterAtIndex:index];
        if (character < '0' || character > '9') return -1;
    }
    return (NSInteger)[suffix integerValue];
}

uint64_t CdnFileSizeAtPath(NSString *path) {
    NSDictionary<NSFileAttributeKey, id> *attributes = [[NSFileManager defaultManager] attributesOfItemAtPath:path error:NULL];
    return [attributes[NSFileSize] unsignedLongLongValue];
}
