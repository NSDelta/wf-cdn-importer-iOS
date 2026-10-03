//
//  CdnImporterOverlay.h
//  CdnImporter
//
//  独立覆盖窗口 + 可拖动悬浮球（不依赖 MobileSubstrate；本 dylib 直接被注入 app 进程）。
//  窗口只在游戏之上挂一个 56pt 的球；点球才展开面板。触摸默认穿透到游戏。
//

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface CdnImporterOverlay : NSObject

+ (instancetype)sharedOverlay;

/// 幂等安装（可重复调用：窗口丢了会重建）。必须在主线程调用。
- (void)install;

- (void)setBallVisible:(BOOL)visible;

@end

NS_ASSUME_NONNULL_END
