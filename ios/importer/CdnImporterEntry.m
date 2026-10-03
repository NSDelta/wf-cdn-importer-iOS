//
//  CdnImporterEntry.m
//  CdnImporter
//
//  非越狱入口：本 dylib 由主二进制的 LC_LOAD_DYLIB 加载（dyld 初始化阶段、main() 之前）。
//  不做任何 hook、不依赖 MobileSubstrate；只在 App 启动后挂一个悬浮球。
//
//  安装时机：__attribute__((constructor)) 跑在 dyld 里，此时 UIApplication 还不存在，
//  所以只注册通知 + 定时兜底；真正的安装由 CdnImporterOverlay.install（幂等）完成。
//

#import <UIKit/UIKit.h>
#import <unistd.h>

#import "CdnImporterConfig.h"
#import "CdnImportPlan.h"
#import "CdnImporterOverlay.h"

static void CdnImporterInstallAfter(NSTimeInterval delay) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        [[CdnImporterOverlay sharedOverlay] install];
    });
}

__attribute__((constructor)) static void CdnImporterEntry(void) {
    @autoreleasepool {
        NSBundle *bundle = [NSBundle mainBundle];
        CdnImporterLog(@"[entry] CdnImporter dylib 已加载（pid=%d bundle=%@ 可执行文件=%@）",
                       (int)getpid(), bundle.bundleIdentifier ?: @"?",
                       bundle.executablePath.lastPathComponent ?: @"?");
        CdnImporterLog(@"[entry] 目标目录：%@", CdnImporterAssetDownloadDir());
        CdnImporterLog(@"[entry] 日志文件：%@", CdnImporterLogPath());
        CdnImporterLog(@"[entry] 导入计划：%@ 个归档（%@ → %@），压缩态 %@",
                       @([CdnImportPlan sharedPlan].items.count),
                       [CdnImportPlan sharedPlan].baselineVersion,
                       [CdnImportPlan sharedPlan].targetVersion,
                       CdnImporterHumanBytes([CdnImportPlan sharedPlan].totalCompressedBytes));

        // 启动完成通知（正常路径）；错过通知也有下面的定时兜底
        [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidFinishLaunchingNotification
                                                          object:nil
                                                           queue:[NSOperationQueue mainQueue]
                                                      usingBlock:^(NSNotification *note) {
            CdnImporterLog(@"[entry] 收到 didFinishLaunching，1 秒后安装悬浮球");
            CdnImporterInstallAfter(1.0);
        }];

        // 兜底：3 秒 / 12 秒各试一次（install 幂等；有些启动路径（后台拉起、恢复场景）不发通知）
        CdnImporterInstallAfter(3.0);
        CdnImporterInstallAfter(12.0);
    }
}
