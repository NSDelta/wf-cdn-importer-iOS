//
//  CdnImporterConfig.h
//  CdnImporter —— iOS CDN 归档导入器（非越狱线：独立 dylib，经 LC_LOAD_DYLIB 注入 app 进程，
//  重签后侧载；不依赖 MobileSubstrate，不做任何 hook）
//
//  职责：构建期常量、沙盒路径解析、日志、通用小工具。
//  设计约束见 ios/importer/README.md。
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// info.json 的 baseUrl。客户端只把它当 Recovery 直链前缀（base_url + file.hash），而服务端
/// files_list 恒为空的 recovery/empty.csv ⇒ 该字段近乎惰性。构建期用 -DCDN_IMPORT_PATCH_BASE
/// 覆盖（Makefile 传 CDN_IMPORT_PATCH_BASE_HOST），运行期可用 plist 键覆写。
#ifndef CDN_IMPORT_PATCH_BASE
#define CDN_IMPORT_PATCH_BASE @"http://192.168.1.10:8001/patch/cn/"
#endif

/// info.json 的 latestModifiedTimeOfArchive。客户端只把它抄进 info.json / partial_downloaded.json，
/// 没有任何比较逻辑 ⇒ 写一个固定字符串即可。
#ifndef CDN_IMPORT_ARCHIVE_TIME
#define CDN_IMPORT_ARCHIVE_TIME @"Sat, 09 Aug 2025 09:35:28 GMT"
#endif

/// plist / NSUserDefaults 覆写键（与 SpLoginConfig 同套路：plist 优先于编译期常量）。
extern NSString *const CdnImporterPatchBaseKey;      ///< NSString，覆盖 baseUrl
extern NSString *const CdnImporterStorageRootKey;    ///< NSString，覆盖 Local Store 根（只该用于调试）
extern NSString *const CdnImporterDeepVerifyKey;     ///< BOOL，逐归档校验 sha256（慢，默认 NO）
extern NSString *const CdnImporterBallXKey;          ///< double，悬浮球位置
extern NSString *const CdnImporterBallYKey;          ///< double，悬浮球位置
extern NSString *const CdnImporterForceBallKey;      ///< BOOL，资源已完整时也强制显示悬浮球

#pragma mark - 错误

extern NSString *const CdnImporterErrorDomain;

typedef NS_ENUM(NSInteger, CdnImporterErrorCode) {
    CdnImporterErrorIO = 1,
    CdnImporterErrorFormat,
    CdnImporterErrorPlan,
    CdnImporterErrorCancelled,
    CdnImporterErrorMissingArchives,
};

/// userInfo 里附「逐条明细」的键（如缺归档清单）；面板会把它逐行打印出来。
extern NSString *const CdnImporterDetailsKey;

NSError *CdnError(CdnImporterErrorCode code, NSString *format, ...) NS_FORMAT_FUNCTION(2, 3);
NSError *CdnErrorWithDetails(CdnImporterErrorCode code, NSArray<NSString *> * _Nullable details,
                             NSString *format, ...) NS_FORMAT_FUNCTION(3, 4);

#pragma mark - 日志

/// NSLog + 追加写容器内日志文件（沙盒内一定可写；越狱机的 /var/mobile/Library/Logs 对
/// 沙盒进程通常不可写，因此不作为主路径）。
void CdnImporterLog(NSString *format, ...) NS_FORMAT_FUNCTION(1, 2);

/// 日志文件路径（容器内 Library/Application Support/CdnImporter/CdnImporter.log）。
NSString *CdnImporterLogPath(void);

/// 读日志尾部（面板展示用）；maxLines <= 0 表示不限制行数。
NSString *CdnImporterLogTail(NSUInteger maxLines);

#pragma mark - 目标目录（app 沙盒内）

/// 解析 Local Store 根。**不要求任何特定 bundle id / app id**：
///   1) NSUserDefaults 键 `CdnImporterStorageRoot` 覆写优先（调试用）；
///   2) 扫 `<Application Support>/*/Local Store`，按磁盘证据取最强的那个
///      （有 `asset/asset_download` > 有 `asset` > 只是存在；bundle id 相符只在同分时加分）——
///      AIR 的 File.applicationStorageDirectory 落在这里，而它的目录名既可能是 Info.plist 的
///      CFBundleIdentifier，也可能是 SWF 描述符里的 app id，重签名后两者可能不一致；
///   3) 一个都不存在（游戏还没跑过）才按 bundle id 预置路径，交给 CdnImporterEnsureDirectory 创建。
NSString *CdnImporterStorageRoot(void);

/// Local Store 根的判定说明（人类可读，面板/日志直接展示；永不为 nil）
NSString *CdnImporterStorageRootNote(void);

/// <Local Store>/asset/asset_download/dummy
/// 注意：子目录名是「探测」出来的（客户端开始下载时才创建它）。见下面两个函数。
NSString *CdnImporterAssetDummyDir(void);

/// 目标子目录是否由「磁盘证据」确定（客户端已创建过该目录）。
/// NO = 磁盘上什么都没找到，用的是参考实现推断出来的 `dummy` ⇒ 建议先让游戏跑一次资源检查再导入。
BOOL CdnImporterTargetDirectoryIsEvidenceBacked(void);

/// 目标子目录的判定说明（人类可读，面板/日志直接展示；永不为 nil）
NSString *CdnImporterTargetDirectoryNote(void);

/// <dummy>/download —— 解压落盘根（与参考 APK 的 new File(fileResolveStorageDir, "download") 一致）
NSString *CdnImporterAssetDownloadDir(void);

/// <dummy>/info.json
NSString *CdnImporterInfoJsonPath(void);

/// partial_downloaded.json / partial_downloaded.platform / partial_downloaded_android_thread.json
NSArray<NSString *> *CdnImporterPartialFilePaths(void);

/// 生效的 baseUrl（plist 覆写 > 编译期常量）
NSString *CdnImporterEffectivePatchBase(void);

/// 是否开启逐归档 sha256 深度校验
BOOL CdnImporterDeepVerifyEnabled(void);

#pragma mark - 资源完整度（资源齐了就把悬浮球收起来）

/// 容器 Documents（文件 App 里的「我的 iPhone → <app>」；能否看到取决于 Info.plist 是否开了
/// UIFileSharingEnabled —— 本包没开，所以它主要作为容器内一个「好找」的落点，外加分享面板的输入）
NSString *CdnImporterDocumentsDirectory(void);

/// 导出日志时顺手写下的副本路径（<Documents>/CdnImporter.log）
NSString *CdnImporterExportedLogPath(void);

/// 客户端口径的「资源已完整」：info.json 存在、version == 计划目标版本、assetRecoveryInfo 为空数组、
/// 没有任何 partial_downloaded* 残留、download/ 目录存在。
/// 只用客户端自己的判据（isDownloaded + isAssetComplete），不猜别的。
BOOL CdnImporterAssetsAreComplete(void);

/// 上面这个判断的人类可读说明（面板/日志直接展示；永不为 nil）
NSString *CdnImporterAssetCompletenessNote(void);

/// 资源完整时是否仍强制显示悬浮球（NSUserDefaults 键 CdnImporterForceBall，默认 NO）
BOOL CdnImporterForceBallEnabled(void);

#pragma mark - 小工具

BOOL CdnImporterEnsureDirectory(NSString *path, NSError **error);
BOOL CdnImporterRemoveItem(NSString *path);
NSString *CdnImporterHumanBytes(uint64_t bytes);
NSString *CdnImporterHumanCount(uint64_t count);

/// 进程当前内存占用（task_vm_info 的 phys_footprint —— jetsam 就是按它杀进程的）。
/// 解压 10 GB 是个长跑，逐归档把它打进日志：数字一路平稳才算正常，
/// 只涨不落说明有东西在攒（真机「Bad address」就是攒到分配失败的表现）。
uint64_t CdnImporterResidentMemoryBytes(void);
NSString *CdnImporterResidentMemoryDescription(void);

/// 向上找到最近的**已存在**目录：`attributesOfFileSystemForPath:` 对不存在的路径会直接报错
/// （"未能打开文件“download”，因为它不存在。"）。同一卷上读到的可用空间是同一个数字。
NSString *CdnImporterNearestExistingPath(NSString *path);

/// ZIP 条目名 → 相对落盘路径：拒绝绝对路径与 `..`，去掉前导 `./`；非法返回 nil。
NSString * _Nullable CdnImporterSanitizeEntryPath(NSString *name);

NSString *CdnImporterTempDirectory(void);
NSDate *CdnImporterNow(void);

NSDictionary<NSString *, id> * _Nullable CdnImporterJSONFromFile(NSString *path, NSError **error);
BOOL CdnImporterWriteJSONAtomically(NSDictionary<NSString *, id> *object, NSString *path, NSError **error);

NS_ASSUME_NONNULL_END
