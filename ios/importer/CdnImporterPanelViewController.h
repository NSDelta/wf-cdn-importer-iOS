//
//  CdnImporterPanelViewController.h
//  CdnImporter
//

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface CdnImporterPanelViewController : UIViewController

/// 点「关闭」时回调（由覆盖层隐藏本面板，不销毁）。
@property (nonatomic, copy, nullable) void (^closeHandler)(void);

/// 从磁盘刷新一次状态（info.json / 空间 / 已选输入）。
- (void)refreshFromDisk;

@end

NS_ASSUME_NONNULL_END
