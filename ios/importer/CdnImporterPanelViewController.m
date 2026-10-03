//
//  CdnImporterPanelViewController.m
//

#import "CdnImporterPanelViewController.h"

#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

#import "CdnArchiveIndex.h"
#import "CdnImportEngine.h"
#import "CdnImporterConfig.h"

static const NSUInteger kCdnPanelMaxLogLines = 400;

/// 「文件」App 不能一次多选（尤其 SMB/iCloud 里的文件夹），所以每次选择都是**追加**：
/// 用户一个一个加、加完再导入。这里只按名字与字节数做体检，真正的识别由引擎在预检/导入时完成。
static uint64_t CdnPanelFileSizeAtPath(NSString *path) {
    NSDictionary<NSFileAttributeKey, id> *attributes = [[NSFileManager defaultManager] attributesOfItemAtPath:path error:NULL];
    return [attributes[NSFileSize] unsignedLongLongValue];
}

static BOOL CdnPanelNameLooksLikeZip(NSString *name) {
    return [name.lowercaseString hasSuffix:@".zip"];
}

static BOOL CdnPanelNameLooksLikeTar(NSString *name) {
    if ([name rangeOfString:@".tar.part." options:NSCaseInsensitiveSearch].location != NSNotFound) return YES;
    return [name.lowercaseString hasSuffix:@".tar"];
}

@interface CdnImporterPanelViewController () <UIDocumentPickerDelegate>

@property (nonatomic, strong) UILabel *titleLabel;
@property (nonatomic, strong) UILabel *statusLabel;
@property (nonatomic, strong) UIProgressView *progressView;
@property (nonatomic, strong) UITextView *logView;
@property (nonatomic, strong) NSMutableArray<UIButton *> *actionButtons;
@property (nonatomic, strong) NSMutableArray<NSString *> *logLines;

@property (nonatomic, strong) NSMutableArray<NSURL *> *inputURLs;      ///< 累积的输入（追加式选择）
@property (nonatomic, strong) NSMutableSet<NSString *> *inputPaths;    ///< 路径去重
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSURL *> *scopedURLs;  ///< 已 start 过安全作用域的输入（撤销/清空时归还）
@property (nonatomic, strong, nullable) NSArray<NSURL *> *lastBatchURLs;  ///< 供「撤销上次」
@property (nonatomic) NSUInteger pickBatchCount;
@property (nonatomic, strong, nullable) CdnImportEngine *engine;
@property (nonatomic, strong, nullable) CdnImportResult *lastResult;
@property (nonatomic, strong, nullable) NSString *lastStageText;
@property (nonatomic) BOOL busy;
@property (nonatomic) BOOL previousIdleTimerDisabled;
@property (nonatomic, strong) dispatch_queue_t workQueue;
@property (nonatomic, strong) NSDateFormatter *timeFormatter;

@end

@implementation CdnImporterPanelViewController

- (instancetype)init {
    self = [super init];
    if (self != nil) {
        _logLines = [NSMutableArray array];
        _actionButtons = [NSMutableArray array];
        _inputURLs = [NSMutableArray array];
        _inputPaths = [NSMutableSet set];
        _scopedURLs = [NSMutableDictionary dictionary];
        _workQueue = dispatch_queue_create("com.starpoint.cdnimporter.work", DISPATCH_QUEUE_SERIAL);
        _timeFormatter = [[NSDateFormatter alloc] init];
        _timeFormatter.dateFormat = @"HH:mm:ss";
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];

    self.view.backgroundColor = [UIColor colorWithWhite:0.10 alpha:0.97];
    self.view.layer.cornerRadius = 14.0;
    self.view.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.18].CGColor;
    self.view.layer.borderWidth = 1.0;
    self.view.clipsToBounds = YES;

    _titleLabel = [[UILabel alloc] init];
    _titleLabel.text = @"CDN 本地导入器";
    _titleLabel.textColor = [UIColor whiteColor];
    _titleLabel.font = [UIFont boldSystemFontOfSize:15];

    _statusLabel = [[UILabel alloc] init];
    _statusLabel.textColor = [UIColor colorWithWhite:0.82 alpha:1.0];
    _statusLabel.font = [UIFont systemFontOfSize:11];
    _statusLabel.numberOfLines = 0;

    _progressView = [[UIProgressView alloc] initWithProgressViewStyle:UIProgressViewStyleDefault];
    _progressView.progressTintColor = [UIColor colorWithRed:0.24 green:0.62 blue:0.96 alpha:1.0];
    _progressView.trackTintColor = [UIColor colorWithWhite:0.28 alpha:1.0];
    _progressView.progress = 0.0;

    _logView = [[UITextView alloc] init];
    _logView.editable = NO;
    _logView.backgroundColor = [UIColor colorWithWhite:0.04 alpha:1.0];
    _logView.textColor = [UIColor colorWithWhite:0.85 alpha:1.0];
    _logView.font = [UIFont monospacedSystemFontOfSize:9.5 weight:UIFontWeightRegular];
    _logView.layer.cornerRadius = 6.0;
    _logView.textContainerInset = UIEdgeInsetsMake(6, 5, 6, 5);

    [self.view addSubview:_titleLabel];
    [self.view addSubview:_statusLabel];
    [self.view addSubview:_progressView];
    [self.view addSubview:_logView];

    NSArray<NSArray *> *specs = @[
        @[@"选文件夹", @"handlePickFolder:"],
        @[@"选文件(可多选)", @"handlePickFiles:"],
        @[@"预检", @"handleDryRun:"],
        @[@"开始导入", @"handleImport:"],
        @[@"取消", @"handleCancel:"],
        @[@"关闭", @"handleClose:"],
        @[@"深度校验", @"handleToggleDeepVerify:"],
        @[@"导出日志", @"handleExportLog:"],
        @[@"撤销上次", @"handleUndoLastPick:"],
        @[@"清空选择", @"handleClearPicks:"],
    ];
    for (NSArray *spec in specs) {
        UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
        [button setTitle:spec[0] forState:UIControlStateNormal];
        [button setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
        [button setTitleColor:[UIColor colorWithWhite:0.6 alpha:1.0] forState:UIControlStateDisabled];
        button.titleLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightMedium];
        button.backgroundColor = [UIColor colorWithWhite:0.30 alpha:1.0];
        button.layer.cornerRadius = 8.0;
        SEL action = NSSelectorFromString(spec[1]);
        [button addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
        [self.actionButtons addObject:button];
        [self.view addSubview:button];
    }
    // 「开始导入」用醒目色
    self.actionButtons[3].backgroundColor = [UIColor colorWithRed:0.15 green:0.47 blue:0.85 alpha:1.0];
    [self updateDeepVerifyButton];

    [self appendLog:[NSString stringWithFormat:@"导入计划：%@ → %@，%lu 个归档，压缩态 %@",
                     [CdnImportPlan sharedPlan].baselineVersion,
                     [CdnImportPlan sharedPlan].targetVersion,
                     (unsigned long)[CdnImportPlan sharedPlan].items.count,
                     CdnImporterHumanBytes([CdnImportPlan sharedPlan].totalCompressedBytes)]];
    [self appendLog:[NSString stringWithFormat:@"目标目录：%@", CdnImporterAssetDownloadDir()]];
    [self appendLog:@"选择输入是追加式的：可反复点「选文件夹」/「选文件」，每次都追加到列表；"];
    [self appendLog:@"全部加完后先「预检」（只读）确认识别 N/N，再「开始导入」。"];
    [self refreshFromDisk];
    [self updateButtons];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];

    CGFloat pad = 12.0;
    CGFloat width = self.view.bounds.size.width;
    CGFloat height = self.view.bounds.size.height;
    CGFloat contentWidth = width - 2 * pad;
    CGFloat y = pad;

    self.titleLabel.frame = CGRectMake(pad, y, contentWidth, 20.0);
    y += 24.0;
    // 状态区行数随内容变化（追加式选择要显示「已选 / 对上计划 / 还缺多少」），
    // 但不能无限长，否则日志区会被挤没。
    CGFloat statusHeight = [self.statusLabel sizeThatFits:CGSizeMake(contentWidth, CGFLOAT_MAX)].height;
    statusHeight = MAX(46.0, MIN(statusHeight, 132.0));
    self.statusLabel.frame = CGRectMake(pad, y, contentWidth, statusHeight);
    y += statusHeight + 4.0;
    self.progressView.frame = CGRectMake(pad, y, contentWidth, 6.0);
    y += 14.0;

    CGFloat buttonHeight = 32.0;
    CGFloat gap = 8.0;
    CGFloat columnWidth = (contentWidth - gap) / 2.0;
    for (NSUInteger index = 0; index < self.actionButtons.count; index++) {
        NSUInteger row = index / 2;
        NSUInteger column = index % 2;
        self.actionButtons[index].frame = CGRectMake(pad + column * (columnWidth + gap),
                                                     y + row * (buttonHeight + gap),
                                                     columnWidth, buttonHeight);
    }
    y += ((self.actionButtons.count + 1) / 2) * (buttonHeight + gap) + 2.0;

    self.logView.frame = CGRectMake(pad, y, contentWidth, MAX(60.0, height - y - pad));
}

#pragma mark - 日志

- (void)appendLog:(NSString *)line {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self appendLog:line];
        });
        return;
    }
    NSString *stamp = [self.timeFormatter stringFromDate:[NSDate date]];
    [self.logLines addObject:[NSString stringWithFormat:@"%@ %@", stamp, line]];
    while (self.logLines.count > kCdnPanelMaxLogLines) {
        [self.logLines removeObjectAtIndex:0];
    }
    self.logView.text = [self.logLines componentsJoinedByString:@"\n"];
    if (self.logView.text.length > 0) {
        NSRange end = NSMakeRange(self.logView.text.length - 1, 1);
        [self.logView scrollRangeToVisible:end];
    }
}

#pragma mark - 状态刷新

- (void)refreshFromDisk {
    NSMutableString *text = [NSMutableString string];
    CdnImportPlan *plan = [CdnImportPlan sharedPlan];

    NSDictionary *info = CdnImporterJSONFromFile(CdnImporterInfoJsonPath(), NULL);
    if (info != nil) {
        [text appendFormat:@"已装 info.json：version=%@ totalSize=%@ recovery=%@\n",
                           info[@"version"] ?: @"?", info[@"totalSize"] ?: @"?",
                           [(NSArray *)info[@"assetRecoveryInfo"] count] == 0 ? @"[]" : @"非空"];
    } else {
        [text appendString:@"尚无 info.json（未导入过，或导入未完成）\n"];
    }
    [text appendFormat:@"资源完整度：%@\n", CdnImporterAssetCompletenessNote()];

    NSString *dummyDir = CdnImporterAssetDummyDir();
    BOOL downloadExists = [[NSFileManager defaultManager] fileExistsAtPath:CdnImporterAssetDownloadDir()];
    [text appendFormat:@"目标目录：%@ %@\n", CdnImporterTargetDirectoryNote(),
                       CdnImporterTargetDirectoryIsEvidenceBacked() ? @"[已确证]" : @"[推断]"];
    [text appendFormat:@"Local Store：%@\n", CdnImporterStorageRootNote()];
    [text appendFormat:@"download 目录：%@\n", downloadExists ? @"存在" : @"不存在（首次导入会创建）"];

    NSError *spaceError = nil;
    NSString *probeDir = CdnImporterNearestExistingPath(dummyDir);
    NSDictionary *attributes = [[NSFileManager defaultManager] attributesOfFileSystemForPath:probeDir error:&spaceError];
    if (attributes == nil) {
        attributes = [[NSFileManager defaultManager] attributesOfFileSystemForPath:NSHomeDirectory() error:&spaceError];
    }
    unsigned long long freeBytes = [attributes[NSFileSystemFreeSize] unsignedLongLongValue];
    [text appendFormat:@"可用空间：%@（需要 %@ + 1GB）\n",
                       CdnImporterHumanBytes(freeBytes),
                       CdnImporterHumanBytes(plan.expectedTotalBytes)];

    NSArray<NSString *> *partials = CdnImporterPartialFilePaths();
    NSUInteger existingPartials = 0;
    for (NSString *path in partials) {
        if ([[NSFileManager defaultManager] fileExistsAtPath:path]) existingPartials++;
    }
    [text appendFormat:@"残留 partial 文件：%lu / %lu\n", (unsigned long)existingPartials, (unsigned long)partials.count];
    [self appendInputSummaryTo:text];

    self.statusLabel.text = text;
    [self setNeedsStatusLayout];
}

/// 状态区行数会变（多一行少一行），重新排版一次。
- (void)setNeedsStatusLayout {
    [self.view setNeedsLayout];
}

/// 追加式选择的汇总：只说「选了多少、按名字对上多少、还缺多少」，
/// 真正的识别（tar 成员、整包 zip、改名兜底）由引擎在预检/导入时做。
- (void)appendInputSummaryTo:(NSMutableString *)text {
    CdnImportPlan *plan = [CdnImportPlan sharedPlan];
    NSUInteger zipCount = 0;
    NSUInteger tarCount = 0;
    NSUInteger otherCount = 0;
    NSUInteger mismatched = 0;
    NSMutableSet<NSString *> *matchedNames = [NSMutableSet set];
    for (NSURL *url in self.inputURLs) {
        NSString *name = url.lastPathComponent;
        if (name.length == 0) {
            otherCount++;
            continue;
        }
        if (CdnPanelNameLooksLikeZip(name)) {
            zipCount++;
            CdnImportPlanItem *item = plan.itemsByBasename[name];
            if (item == nil) continue;
            [matchedNames addObject:name];
            if (CdnPanelFileSizeAtPath(url.path) != item.size) mismatched++;
            continue;
        }
        if (CdnPanelNameLooksLikeTar(name)) {
            tarCount++;
            continue;
        }
        otherCount++;
    }

    [text appendFormat:@"已选输入：%lu 项（zip %lu / tar %lu / 其他 %lu）\n",
                       (unsigned long)self.inputURLs.count,
                       (unsigned long)zipCount, (unsigned long)tarCount, (unsigned long)otherCount];
    if (matchedNames.count > 0) {
        NSUInteger total = plan.items.count;
        if (matchedNames.count >= total) {
            [text appendFormat:@"按名字对上计划：%lu / %lu ✅ 齐了\n",
                               (unsigned long)matchedNames.count, (unsigned long)total];
        } else {
            [text appendFormat:@"按名字对上计划：%lu / %lu（还缺 %lu 个 zip）\n",
                               (unsigned long)matchedNames.count, (unsigned long)total,
                               (unsigned long)(total - matchedNames.count)];
        }
    } else if (tarCount > 0) {
        [text appendString:@"按名字对上计划：0（tar 成员要点「预检」时才解析）\n"];
    }
    if (mismatched > 0) {
        [text appendFormat:@"⚠️ %lu 个 zip 字节数与计划不符（传输可能没传完）\n", (unsigned long)mismatched];
    }
}

/// 单个新输入的体检结论（只看名字与字节数，不读内容）。
- (NSString *)describeAddedInput:(NSURL *)url {
    NSString *name = url.lastPathComponent ?: (url.absoluteString ?: @"(无名字)");
    if (CdnPanelNameLooksLikeZip(name)) {
        CdnImportPlanItem *item = [CdnImportPlan sharedPlan].itemsByBasename[name];
        if (item == nil) {
            return [NSString stringWithFormat:@"  + %@ ？（基名不在计划里：改名包/整包 zip 会在导入时按字节数+sha256 认领）", name];
        }
        uint64_t size = CdnPanelFileSizeAtPath(url.path);
        if (size == item.size) {
            return [NSString stringWithFormat:@"  + %@ ✓ %@（%@ %@）", name,
                    CdnImporterHumanBytes(item.size), item.layer, item.kind];
        }
        return [NSString stringWithFormat:@"  + %@ ⚠️ 字节数不符：本地 %llu / 计划 %llu", name, size, item.size];
    }
    if (CdnPanelNameLooksLikeTar(name)) {
        return [NSString stringWithFormat:@"  + %@（tar 分卷/整包 tar，点「预检」时解析成员）", name];
    }
    return [NSString stringWithFormat:@"  + %@ ？（不是 zip/tar，很可能不会被识别）", name];
}

- (void)updateButtons {
    for (NSUInteger index = 0; index < self.actionButtons.count; index++) {
        BOOL enabled = YES;
        if (self.busy) {
            enabled = (index == 4);   // 只有「取消」在忙时可用
        } else {
            enabled = (index != 4);   // 不忙时「取消」不可用
        }
        if ((index == 2 || index == 3) && self.inputURLs.count == 0 && !self.busy) {
            enabled = NO;
        }
        if ((index == 8 || index == 9) && self.inputURLs.count == 0 && !self.busy) {
            enabled = NO;   // 没选任何东西时，「撤销上次」「清空选择」没意义
        }
        if (index == 7) enabled = YES;   // 「导出日志」任何时刻可用（导入中也能抓日志）
        self.actionButtons[index].enabled = enabled;
        self.actionButtons[index].alpha = enabled ? 1.0 : 0.45;
    }
}

- (void)updateProgress:(CdnImportProgress *)progress {
    NSString *stage = CdnImportStageName(progress.stage);
    if (progress.stage == CdnImportStageIdle || progress.stage == CdnImportStageFinished ||
        progress.stage == CdnImportStageFailed || progress.stage == CdnImportStageCancelled) {
        self.progressView.progress = (progress.stage == CdnImportStageFinished) ? 1.0 : 0.0;
    } else {
        self.progressView.progress = (float)MAX(0.0, MIN(1.0, progress.fraction));
    }

    NSMutableString *text = [NSMutableString string];
    [text appendFormat:@"%@ · %@\n", stage, progress.statusText ?: @""];
    [text appendFormat:@"归档 %lu/%lu · 压缩态 %@/%@\n",
                       (unsigned long)progress.archivesDone, (unsigned long)progress.archivesTotal,
                       CdnImporterHumanBytes(progress.compressedDone), CdnImporterHumanBytes(progress.compressedTotal)];
    [text appendFormat:@"已写文件 %lu", (unsigned long)progress.filesWritten];
    if (progress.elapsed > 0.5) {
        [text appendFormat:@" · 用时 %.0fs", progress.elapsed];
        if (progress.remaining >= 0.0) [text appendFormat:@" · 剩余约 %.0fs", progress.remaining];
    }
    self.statusLabel.text = text;
}

#pragma mark - 弹窗（先找对「由谁来 present」）

/// 面板的 view 是直接 addSubview 到容器上的（同层共存时还挂在登录插件的窗口里），
/// 面板 VC 自己并不在 VC 层级里 —— 直接 [self presentViewController:] 有时会被 UIKit
/// 静默丢掉（分享面板尤其明显：点了没反应、日志里也只有一行「导出日志：…」）。
/// 所以统一改成「当前最上层可见窗口的 rootViewController」来 present。
- (nullable UIViewController *)cdn_presenter {
    if (self.presentingViewController != nil || self.parentViewController != nil) {
        return self;
    }
    NSMutableArray<UIWindow *> *windows = [NSMutableArray array];
    for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
        if (![scene isKindOfClass:[UIWindowScene class]]) continue;
        [windows addObjectsFromArray:((UIWindowScene *)scene).windows];
    }
    [windows sortUsingComparator:^NSComparisonResult(UIWindow *a, UIWindow *b) {
        if (a.windowLevel == b.windowLevel) return NSOrderedSame;
        return a.windowLevel > b.windowLevel ? NSOrderedAscending : NSOrderedDescending;
    }];
    for (UIWindow *window in windows) {
        if (window.hidden || window.alpha < 0.01) continue;
        UIViewController *controller = window.rootViewController;
        if (controller == nil) continue;
        while (controller.presentedViewController != nil) {
            controller = controller.presentedViewController;
        }
        return controller;
    }
    return nil;
}

/// 用 cdn_presenter 弹窗；没有可用窗口时记一行日志（调用方自己决定还要不要兜底）。
- (BOOL)cdn_present:(UIViewController *)controller note:(NSString *)note {
    UIViewController *presenter = [self cdn_presenter];
    if (presenter == nil) {
        [self appendLog:[NSString stringWithFormat:@"⚠️ 没有可用的窗口来弹出「%@」", note]];
        return NO;
    }
    [presenter presentViewController:controller animated:YES completion:nil];
    return YES;
}

#pragma mark - 选择输入

- (void)handlePickFolder:(UIButton *)sender {
    UIDocumentPickerViewController *picker =
        [[UIDocumentPickerViewController alloc] initForOpeningContentTypes:@[UTTypeFolder] asCopy:NO];
    picker.allowsMultipleSelection = NO;
    picker.shouldShowFileExtensions = YES;
    picker.delegate = self;
    [self appendLog:@"选文件夹：进到放归档的目录后点右上角「打开」/「选取」即选中当前目录（结果会追加到输入列表）"];
    [self cdn_present:picker note:@"文件选择器"];
}

- (void)handlePickFiles:(UIButton *)sender {
    UIDocumentPickerViewController *picker =
        [[UIDocumentPickerViewController alloc] initForOpeningContentTypes:@[UTTypeData] asCopy:NO];
    picker.allowsMultipleSelection = YES;
    picker.shouldShowFileExtensions = YES;
    picker.delegate = self;
    [self appendLog:@"选文件：能多选就多选，不能多选就一个一个加（每次都追加到输入列表）"];
    [self cdn_present:picker note:@"文件选择器"];
}

- (void)documentPicker:(UIDocumentPickerViewController *)controller didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
    NSMutableArray<NSURL *> *added = [NSMutableArray array];
    NSUInteger duplicates = 0;
    for (NSURL *url in urls) {
        NSString *key = url.path ?: url.absoluteString;
        if (key.length == 0 || [self.inputPaths containsObject:key]) {
            duplicates++;
            continue;
        }
        [self.inputPaths addObject:key];
        [self.inputURLs addObject:url];
        // 追加式选择要跨多批保持可读：这里先把安全作用域打开并留着（引擎跑导入时还会自己
        // start/stop，系统按引用计数，不冲突）。返回值 NO 一般只说明它不是作用域 URL（本地沙盒文件），
        // 不是错误。撤销/清空时归还。
        if ([url startAccessingSecurityScopedResource]) {
            self.scopedURLs[key] = url;
        }
        [added addObject:url];
    }
    self.lastBatchURLs = [added copy];
    if (added.count > 0) self.pickBatchCount++;

    [self appendLog:[NSString stringWithFormat:@"第 %lu 次选择：新增 %lu 项%@，累计 %lu 项",
                     (unsigned long)self.pickBatchCount, (unsigned long)added.count,
                     duplicates > 0 ? [NSString stringWithFormat:@"（重复忽略 %lu 项）", (unsigned long)duplicates] : @"",
                     (unsigned long)self.inputURLs.count]];
    for (NSURL *url in added) {
        [self appendLog:[self describeAddedInput:url]];
    }
    if (added.count == 0) {
        [self appendLog:@"（这一批全是已加过的，输入列表没有变化）"];
    }
    [self refreshFromDisk];
    [self updateButtons];
}

- (void)documentPickerWasCancelled:(UIDocumentPickerViewController *)controller {
    [self appendLog:@"文件选择已取消"];
}

- (void)handleUndoLastPick:(UIButton *)sender {
    if (self.busy) return;
    NSArray<NSURL *> *batch = self.lastBatchURLs;
    if (batch.count == 0) {
        [self appendLog:@"没有可撤销的选择"];
        return;
    }
    for (NSURL *url in batch) {
        [self.inputURLs removeObject:url];
        NSString *key = url.path ?: url.absoluteString;
        if (key.length == 0) continue;
        [self.inputPaths removeObject:key];
        [self releaseSecurityScopeForPath:key];
    }
    [self appendLog:[NSString stringWithFormat:@"已撤销上次选择 %lu 项，累计 %lu 项",
                     (unsigned long)batch.count, (unsigned long)self.inputURLs.count]];
    self.lastBatchURLs = nil;
    [self refreshFromDisk];
    [self updateButtons];
}

- (void)handleClearPicks:(UIButton *)sender {
    if (self.busy) return;
    NSUInteger count = self.inputURLs.count;
    for (NSString *key in [self.scopedURLs.allKeys copy]) {
        [self releaseSecurityScopeForPath:key];
    }
    [self.inputURLs removeAllObjects];
    [self.inputPaths removeAllObjects];
    self.lastBatchURLs = nil;
    self.pickBatchCount = 0;
    [self appendLog:[NSString stringWithFormat:@"已清空输入列表（原有 %lu 项）", (unsigned long)count]];
    [self refreshFromDisk];
    [self updateButtons];
}

/// 归还某个输入占用的安全作用域（只有真的 start 过才 stop）。
- (void)releaseSecurityScopeForPath:(NSString *)key {
    NSURL *url = self.scopedURLs[key];
    if (url == nil) return;
    [url stopAccessingSecurityScopedResource];
    [self.scopedURLs removeObjectForKey:key];
}

#pragma mark - 运行

- (void)handleDryRun:(UIButton *)sender {
    [self runWithDryRun:YES];
}

- (void)handleImport:(UIButton *)sender {
    if (self.busy) return;
    CdnImportPlan *plan = [CdnImportPlan sharedPlan];
    NSString *message = [NSString stringWithFormat:
        @"已选输入 %lu 项。\n将先清空\n%@\n再按计划顺序解压 %lu 个归档（压缩态 %@，终态约 %@）。\n\n"
         "若不确定选全了没有，先点「预检」：它只读不写，会告出缺哪几个归档。\n"
         "导入时请保持本界面在前台、不要锁屏；中途可点「取消」。",
        (unsigned long)self.inputURLs.count,
        CdnImporterAssetDownloadDir(), (unsigned long)plan.items.count,
        CdnImporterHumanBytes(plan.totalCompressedBytes), CdnImporterHumanBytes(plan.expectedTotalBytes)];
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"开始导入？"
                                                                  message:message
                                                           preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    __weak typeof(self) weakSelf = self;
    [alert addAction:[UIAlertAction actionWithTitle:@"开始导入" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action) {
        [weakSelf runWithDryRun:NO];
    }]];
    [self cdn_present:alert note:@"开始导入确认"];
}

- (void)handleCancel:(UIButton *)sender {
    if (self.engine == nil) return;
    [self appendLog:@"请求取消…"];
    [self.engine cancel];
}

- (void)handleClose:(UIButton *)sender {
    if (self.closeHandler != nil) self.closeHandler();
}

#pragma mark - 开关与日志导出

- (void)updateDeepVerifyButton {
    if (self.actionButtons.count < 8) return;
    BOOL on = CdnImporterDeepVerifyEnabled();
    [self.actionButtons[6] setTitle:(on ? @"深度校验(开)" : @"深度校验(关)") forState:UIControlStateNormal];
    self.actionButtons[6].backgroundColor = on
        ? [UIColor colorWithRed:0.55 green:0.33 blue:0.10 alpha:1.0]
        : [UIColor colorWithWhite:0.30 alpha:1.0];
}

- (void)handleToggleDeepVerify:(UIButton *)sender {
    if (self.busy) {
        [self appendLog:@"导入进行中，深度校验开关在下次导入生效"];
    }
    BOOL now = !CdnImporterDeepVerifyEnabled();
    [[NSUserDefaults standardUserDefaults] setBool:now forKey:CdnImporterDeepVerifyKey];
    [[NSUserDefaults standardUserDefaults] synchronize];
    [self updateDeepVerifyButton];
    [self appendLog:[NSString stringWithFormat:@"深度校验（逐包整包 sha256）已%@%@",
                     now ? @"开启" : @"关闭",
                     now ? @"：每个归档会完整读两遍，导入时间约翻倍" : @""]];
}

- (void)handleExportLog:(UIButton *)sender {
    NSString *path = CdnImporterLogPath();
    NSFileManager *manager = [NSFileManager defaultManager];
    if (![manager fileExistsAtPath:path]) {
        [self appendLog:[NSString stringWithFormat:@"日志文件还不存在：%@", path]];
        return;
    }

    // ① 复制一份到 Documents：固定的好找落点（以后开了文件共享也能直接从电脑取）
    NSString *exportPath = CdnImporterExportedLogPath();
    BOOL copied = NO;
    if (CdnImporterEnsureDirectory([exportPath stringByDeletingLastPathComponent], NULL)) {
        [manager removeItemAtPath:exportPath error:NULL];
        copied = [manager copyItemAtPath:path toPath:exportPath error:NULL];
    }

    // ② 整份日志塞剪贴板：这是最稳的一条路（分享面板在某些窗口层级下弹不出来）
    NSString *text = CdnImporterLogTail(0);
    const NSUInteger maxPasteboardChars = 512 * 1024;
    BOOL truncated = text.length > maxPasteboardChars;
    NSString *paste = truncated ? [text substringFromIndex:(text.length - maxPasteboardChars)] : text;
    [UIPasteboard generalPasteboard].string = paste ?: @"";
    [self appendLog:[NSString stringWithFormat:@"日志已复制到剪贴板（%lu 字符%@）：随便找个输入框长按 → 粘贴 就能发出来",
                     (unsigned long)paste.length, truncated ? @"，只保留最后 512 KB" : @""]];

    // ③ 分享面板：必须用 cdn_presenter —— 面板的 view 是 addSubview 进来的，
    //    面板 VC 自己不在 VC 层级里，直接 present 会被 UIKit 静默丢掉。
    UIViewController *presenter = [self cdn_presenter];
    if (presenter == nil) {
        [self appendLog:@"没有可用的窗口来弹分享面板，用上面的剪贴板方式取日志"];
    } else {
        NSURL *url = [NSURL fileURLWithPath:path];
        UIActivityViewController *activity = [[UIActivityViewController alloc] initWithActivityItems:@[url]
                                                                              applicationActivities:nil];
        activity.popoverPresentationController.sourceView = sender;
        activity.popoverPresentationController.sourceRect = sender.bounds;
        [presenter presentViewController:activity animated:YES completion:nil];
        [self appendLog:[NSString stringWithFormat:@"导出日志：%@（分享面板由 %@ 弹出）",
                         path, NSStringFromClass([presenter class])]];
    }
    if (copied) {
        [self appendLog:[NSString stringWithFormat:@"日志副本：%@", exportPath]];
    }
}

- (void)runWithDryRun:(BOOL)dryRun {
    if (self.busy) return;
    if (self.inputURLs.count == 0) {
        [self appendLog:@"还没有选择输入"];
        return;
    }

    self.busy = YES;
    self.lastResult = nil;
    [self updateButtons];

    if (!dryRun) {
        self.previousIdleTimerDisabled = [UIApplication sharedApplication].isIdleTimerDisabled;
        [UIApplication sharedApplication].idleTimerDisabled = YES;
    }

    CdnImportEngine *engine = [[CdnImportEngine alloc] init];
    engine.dryRun = dryRun;
    __weak typeof(self) weakSelf = self;
    engine.logHandler = ^(NSString *line) {
        [weakSelf appendLog:line];
    };
    engine.progressHandler = ^(CdnImportProgress *progress) {
        [weakSelf updateProgress:progress];
    };
    self.engine = engine;

    NSArray<NSURL *> *urls = [self.inputURLs copy];
    dispatch_async(self.workQueue, ^{
        NSError *error = nil;
        CdnImportResult *result = [engine runWithInputURLs:urls error:&error];
        dispatch_async(dispatch_get_main_queue(), ^{
            typeof(self) strongSelf = weakSelf;
            if (strongSelf == nil) return;
            strongSelf.busy = NO;
            strongSelf.engine = nil;
            if (!dryRun) {
                [UIApplication sharedApplication].idleTimerDisabled = strongSelf.previousIdleTimerDisabled;
            }
            [strongSelf updateButtons];
            if (result == nil) {
                [strongSelf presentError:error];
            } else {
                strongSelf.lastResult = result;
                [strongSelf presentResult:result dryRun:dryRun];
            }
        });
    });
}

- (void)presentError:(NSError *)error {
    NSString *message = error.localizedDescription ?: @"未知错误";
    [self appendLog:[NSString stringWithFormat:@"失败：%@", message]];
    NSArray<NSString *> *details = error.userInfo[CdnImporterDetailsKey];
    for (NSString *line in details) {
        [self appendLog:[NSString stringWithFormat:@"  · %@", line]];
    }
    [self refreshFromDisk];
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"导入未完成"
                                                                  message:message
                                                           preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"知道了" style:UIAlertActionStyleDefault handler:nil]];
    [self cdn_present:alert note:@"导入未完成提示"];
}

- (void)presentResult:(CdnImportResult *)result dryRun:(BOOL)dryRun {
    NSString *title = dryRun ? @"预检完成" : @"导入完成";
    NSString *message = result.summaryText ?: @"";
    [self appendLog:[NSString stringWithFormat:@"%@：%@", title, message]];
    for (NSString *warning in result.warnings) {
        [self appendLog:[NSString stringWithFormat:@"⚠️ %@", warning]];
    }
    for (NSString *problem in result.problems) {
        [self appendLog:[NSString stringWithFormat:@"❌ %@", problem]];
    }
    [self refreshFromDisk];
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title
                                                                  message:message
                                                           preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
    [self cdn_present:alert note:@"结果提示"];
}

@end
