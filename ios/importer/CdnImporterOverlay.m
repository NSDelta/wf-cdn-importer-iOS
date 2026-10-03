//
//  CdnImporterOverlay.m
//

#import "CdnImporterOverlay.h"

#import "CdnImporterConfig.h"
#import "CdnImporterPanelViewController.h"

static const CGFloat kCdnBallSize = 56.0;
static const CGFloat kCdnBallMargin = 12.0;
/// 自己建窗口时的等级：**低于**登录插件（SpLogin）的悬浮层（`UIWindowLevelStatusBar + 100`）。
/// 别人的悬浮层永远压在我们上面，我们绝不抢它们的层。
static const CGFloat kCdnOverlayLevelOffset = 90.0;
/// 登录插件悬浮球的 `accessibilityLabel`（现成、稳定的识别标志；它自己的球是 UIButton + 这个标签）。
static NSString *const kCdnForeignBallAccessibilityLabel = @"SpLogin 服务器绑定";

#pragma mark - 与别的插件共存（同层规则）

// 这个进程里可能同时挂着别的悬浮插件（本项目成例：登录插件 SpLogin 的覆盖窗口，
// `windowLevel = UIWindowLevelStatusBar + 100`，rootViewController 是 SpLoginOverlayRootViewController，
// 根视图 SpLoginPassView，球是右上角 52×52 的 UIButton）。
//
// 两家各建一个全屏透明窗口时，谁的 windowLevel 高谁在上面：等级高的一方会把自己的球压在对方球身上，
// 对方的球就点不动了（表现为「另一个插件没法用了」）。所以规则定成两条：
//   ① 发现对方的悬浮层窗口时——**把我们的球挂进对方的窗口**（真·同一图层），并且默认落在左边，
//      必要时自动避让对方球的位置；我们自己的窗口这时整体 hidden（不留一个多余的透明窗口）。
//   ② 对方窗口不在（例如登录插件的出货配置是「进游戏后整套覆盖层停用」）——才用我们自己的窗口，
//      等级 `UIWindowLevelStatusBar + 90`，仍低于对方的悬浮层。
// 两条路都由看门狗每 2s 复查一次，窗口可见性变化（UIWindowDidBecome*）也会立即复查，可来回切换。

static BOOL CdnViewIsBallLike(UIView *view) {
    if (view == nil) {
        return NO;
    }
    CGSize size = view.bounds.size;
    CGFloat delta = size.width >= size.height ? size.width - size.height : size.height - size.width;
    return size.width >= 36.0 && size.width <= 88.0 && delta <= 6.0;
}

static BOOL CdnWindowLooksLikeFloatingLayer(UIWindow *window, UIWindow *ownWindow) {
    if (window == nil || window == ownWindow || window.hidden) {
        return NO;
    }
    CGFloat level = window.windowLevel;
    if (level <= UIWindowLevelNormal || level >= UIWindowLevelAlert) {
        return NO;      // 游戏自己的窗口、系统弹窗（alert 级）都不算
    }
    if (CGRectIsEmpty(window.bounds)) {
        return NO;
    }
    NSMutableArray<NSString *> *names = [NSMutableArray array];
    [names addObject:NSStringFromClass([window class])];
    if (window.rootViewController != nil) {
        [names addObject:NSStringFromClass([window.rootViewController class])];
        if (window.rootViewController.view != nil) {
            [names addObject:NSStringFromClass([window.rootViewController.view class])];
        }
    }
    for (NSString *name in names) {
        for (NSString *needle in @[ @"Overlay", @"SpLogin", @"Floating", @"Ball", @"Pass" ]) {
            if ([name containsString:needle]) {
                return YES;
            }
        }
    }
    return NO;
}

#pragma mark - 穿透宿主 VC

/// 命中自身时返回 nil，让触摸继续传给下层（游戏）窗口；子视图（球 / 面板）正常命中。
@interface CdnImporterPassthroughView : UIView
@end

@implementation CdnImporterPassthroughView

- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    UIView *hit = [super hitTest:point withEvent:event];
    return hit == self ? nil : hit;
}

@end

@interface CdnImporterPassthroughViewController : UIViewController
@end

@implementation CdnImporterPassthroughViewController

- (void)loadView {
    self.view = [[CdnImporterPassthroughView alloc] initWithFrame:CGRectZero];
    self.view.backgroundColor = [UIColor clearColor];
}

- (BOOL)prefersStatusBarHidden {
    return NO;
}

- (UIInterfaceOrientationMask)supportedInterfaceOrientations {
    return UIInterfaceOrientationMaskAll;
}

@end

#pragma mark - 悬浮球

@interface CdnImporterBallView : UIView
@end

@implementation CdnImporterBallView

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self != nil) {
        self.backgroundColor = [UIColor colorWithRed:0.09 green:0.36 blue:0.66 alpha:0.92];
        self.layer.cornerRadius = frame.size.width / 2.0;
        self.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.65].CGColor;
        self.layer.borderWidth = 1.5;
        self.layer.shadowColor = [UIColor blackColor].CGColor;
        self.layer.shadowOpacity = 0.35;
        self.layer.shadowRadius = 4;
        self.layer.shadowOffset = CGSizeMake(0, 2);

        UILabel *label = [[UILabel alloc] initWithFrame:self.bounds];
        label.text = @"CDN";
        label.textColor = [UIColor whiteColor];
        label.textAlignment = NSTextAlignmentCenter;
        label.font = [UIFont boldSystemFontOfSize:15];
        label.userInteractionEnabled = NO;
        [self addSubview:label];
    }
    return self;
}

@end

#pragma mark - 覆盖层

@interface CdnImporterOverlay ()
@property (nonatomic, strong, nullable) UIWindow *window;
@property (nonatomic, strong, nullable) CdnImporterBallView *ball;
@property (nonatomic, strong, nullable) CdnImporterPanelViewController *panel;
@property (nonatomic, strong, nullable) NSTimer *watchdog;
@property (nonatomic, strong) NSMutableArray<NSLayoutConstraint *> *ballConstraints;
/// 资源已经完整 → 把球收起来（用户建议：资源齐了就别再挡着屏幕）。
/// 只记「是不是因为完整而藏起来」，免得别的原因藏球被这里翻回去。
@property (nonatomic) BOOL completenessHidesBall;
/// 看门狗每 2s 一跳，攒够 15 跳（≈30s）复查一次资源完整度。
@property (nonatomic) NSUInteger watchdogTicks;
@end

@implementation CdnImporterOverlay

+ (instancetype)sharedOverlay {
    static CdnImporterOverlay *overlay = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        overlay = [[CdnImporterOverlay alloc] init];
    });
    return overlay;
}

- (instancetype)init {
    self = [super init];
    if (self != nil) {
        _ballConstraints = [NSMutableArray array];
        NSNotificationCenter *center = [NSNotificationCenter defaultCenter];
        [center addObserver:self
                   selector:@selector(handleWindowBecameKey:)
                       name:UIWindowDidBecomeKeyNotification
                     object:nil];
        // 别的悬浮层窗口被隐藏 / 重新显示时立刻复查宿主（看门狗 2s 是兜底）
        [center addObserver:self
                   selector:@selector(handleWindowVisibilityChanged:)
                       name:UIWindowDidBecomeHiddenNotification
                     object:nil];
        [center addObserver:self
                   selector:@selector(handleWindowVisibilityChanged:)
                       name:UIWindowDidBecomeVisibleNotification
                     object:nil];
        // 回到前台时复查一次资源完整度（刚在别处删过 info.json / 游戏自己清过资源都能立刻反映）
        [center addObserver:self
                   selector:@selector(handleApplicationDidBecomeActive:)
                       name:UIApplicationDidBecomeActiveNotification
                     object:nil];
    }
    return self;
}

- (void)dealloc {
    [_watchdog invalidate];
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

#pragma mark - 安装

- (void)install {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self install];
        });
        return;
    }

    UIWindowScene *scene = [self activeWindowScene];
    if (scene == nil) {
        // 场景还没就绪：稍后重试（App 启动早期会走到这里）
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.7 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [self install];
        });
        return;
    }

    if (self.window == nil || self.window.windowScene != scene) {
        [self buildWindowWithScene:scene];
    }

    [self syncHostWindow];
    [self startWatchdog];
    [self refreshBallVisibilityForCompleteness];
    CdnImporterLog(@"[overlay] 悬浮球已就位（window=%@ scene=%@ 宿主=%@）",
                   self.window, NSStringFromClass(scene.class), [self describeHostContainer]);
}

- (nullable UIWindowScene *)activeWindowScene {
    for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
        if (![scene isKindOfClass:[UIWindowScene class]]) continue;
        if (scene.activationState == UISceneActivationStateForegroundActive) return (UIWindowScene *)scene;
    }
    for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
        if ([scene isKindOfClass:[UIWindowScene class]]) return (UIWindowScene *)scene;
    }
    return nil;
}

- (void)buildWindowWithScene:(UIWindowScene *)scene {
    [self.watchdog invalidate];
    self.watchdog = nil;

    UIWindow *window = [[UIWindow alloc] initWithWindowScene:scene];
    window.windowLevel = UIWindowLevelStatusBar + kCdnOverlayLevelOffset;
    window.backgroundColor = [UIColor clearColor];
    window.rootViewController = [[CdnImporterPassthroughViewController alloc] init];
    window.hidden = NO;

    self.window = window;

    if (self.ball == nil) {
        CdnImporterBallView *ball = [[CdnImporterBallView alloc] initWithFrame:CGRectMake(0, 0, kCdnBallSize, kCdnBallSize)];
        ball.translatesAutoresizingMaskIntoConstraints = NO;
        ball.userInteractionEnabled = YES;
        [ball addGestureRecognizer:[[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(handleBallPan:)]];
        [ball addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(handleBallTap:)]];
        self.ball = ball;
    }
}

#pragma mark - 宿主窗口（与别的悬浮插件同层）

/// 场景里已存在的第三方悬浮层窗口（现在只有登录插件会建）；没有就返回 nil。
- (nullable UIWindow *)foreignFloatingWindow {
    NSMutableArray<UIWindow *> *candidates = [NSMutableArray array];
    if (self.window.windowScene != nil) {
        [candidates addObjectsFromArray:self.window.windowScene.windows];
    }
    for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
        if (![scene isKindOfClass:[UIWindowScene class]]) continue;
        [candidates addObjectsFromArray:((UIWindowScene *)scene).windows];
    }
    [candidates addObjectsFromArray:[UIApplication sharedApplication].windows];
    for (UIWindow *candidate in candidates) {
        if (CdnWindowLooksLikeFloatingLayer(candidate, self.window)) {
            return candidate;
        }
    }
    return nil;
}

/// 对方窗口里那颗球（按 accessibilityLabel 认；认不到就退化成「尺寸像球的方形子视图」）。
- (nullable UIView *)foreignFloatingBallInWindow:(nullable UIWindow *)window {
    if (window == nil) {
        return nil;
    }
    NSMutableArray<UIView *> *queue = [NSMutableArray arrayWithObject:window];
    NSUInteger visited = 0;
    UIView *fallback = nil;
    while (queue.count > 0 && visited < 400) {
        UIView *view = queue.firstObject;
        [queue removeObjectAtIndex:0];
        visited += 1;
        if (view != self.ball) {
            NSString *label = view.accessibilityLabel;
            if ([label isEqualToString:kCdnForeignBallAccessibilityLabel]) {
                return view;
            }
            if (fallback == nil && view != window && CdnViewIsBallLike(view) && view.window == window) {
                fallback = view;
            }
        }
        [queue addObjectsFromArray:view.subviews];
    }
    return fallback;
}

/// 球此刻应该挂在哪个视图上：优先「对方的悬浮层」，否则自己的窗口。
- (nullable UIView *)hostContainerView {
    UIWindow *foreign = [self foreignFloatingWindow];
    if (foreign != nil) {
        return foreign.rootViewController.view ?: foreign;
    }
    return self.window;
}

- (NSString *)describeHostContainer {
    UIView *container = self.ball.superview ?: [self hostContainerView];
    if (container == nil) {
        return @"(无)";
    }
    if (container == self.window) {
        return [NSString stringWithFormat:@"自己的窗口 lvl=%.0f", self.window.windowLevel];
    }
    return [NSString stringWithFormat:@"%@（同层，lvl=%.0f）",
            NSStringFromClass([container class]), container.window.windowLevel];
}

/// 把球放到正确的宿主里；自己的窗口只在「没跟别人同层」时显示。
/// 幂等：宿主没变就什么都不做（只保证约束还在）。
- (void)syncHostWindow {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self syncHostWindow];
        });
        return;
    }
    if (self.window == nil) {
        [self install];
        return;
    }
    if (self.ball == nil) {
        [self buildWindowWithScene:self.window.windowScene];
    }

    UIView *container = [self hostContainerView];
    if (container == nil) {
        return;
    }
    BOOL shared = (container != self.window);

    if (self.ball.superview != container) {
        UIView *previous = self.ball.superview;
        [self.ball removeFromSuperview];
        [container addSubview:self.ball];
        if (previous != nil) {
            CdnImporterLog(@"[overlay] 悬浮球换宿主：%@ → %@", NSStringFromClass([previous class]), [self describeHostContainer]);
        }
    }

    // 自己的窗口：同层时整体收起来（不留多余透明窗口）；用自己的窗口时显示出来、等级低于对方悬浮层
    self.window.hidden = shared;
    if (!shared) {
        [self.window setWindowLevel:UIWindowLevelStatusBar + kCdnOverlayLevelOffset];
    }
    [self layoutBall];
}

- (void)layoutBall {
    UIView *container = self.ball.superview ?: self.window;
    CdnImporterBallView *ball = self.ball;
    if (container == nil || ball == nil) {
        return;
    }

    [NSLayoutConstraint deactivateConstraints:self.ballConstraints];
    [self.ballConstraints removeAllObjects];

    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    CGFloat size = kCdnBallSize;
    CGRect bounds = container.bounds;
    CGFloat maxX = MAX(0, bounds.size.width - size);
    CGFloat maxY = MAX(0, bounds.size.height - size);
    BOOL shared = (container != self.window);

    // 默认位置：自己独占屏幕时贴右边；跟登录插件同层时贴**左边**（它的球默认在右上角）
    CGFloat defaultX = shared ? kCdnBallMargin : MAX(0, bounds.size.width - size - kCdnBallMargin);
    CGFloat x = [defaults objectForKey:CdnImporterBallXKey] != nil
        ? (CGFloat)[defaults doubleForKey:CdnImporterBallXKey]
        : defaultX;
    CGFloat y = [defaults objectForKey:CdnImporterBallYKey] != nil
        ? (CGFloat)[defaults doubleForKey:CdnImporterBallYKey]
        : bounds.size.height * 0.35;
    x = MIN(MAX(0, x), maxX);
    y = MIN(MAX(0, y), maxY);

    // 避让对方的球：重叠就让到左边，左边也重叠就退到它下面（只在本次布局生效，不写进默认值）
    UIView *foreignBall = [self foreignFloatingBallInWindow:[self foreignFloatingWindow]];
    if (foreignBall != nil && foreignBall != ball && foreignBall.window == container.window) {
        CGRect theirs = [foreignBall convertRect:foreignBall.bounds toView:container];
        CGRect padded = CGRectInset(theirs, -8.0, -8.0);
        if (CGRectIntersectsRect(padded, CGRectMake(x, y, size, size))) {
            CGFloat mirrored = kCdnBallMargin;
            if (!CGRectIntersectsRect(padded, CGRectMake(mirrored, y, size, size))) {
                x = mirrored;
                CdnImporterLog(@"[overlay] 悬浮球与登录插件的球重叠，自动让到左侧");
            } else {
                CGFloat below = CGRectGetMaxY(theirs) + kCdnBallMargin;
                if (below <= maxY) {
                    y = below;
                    CdnImporterLog(@"[overlay] 悬浮球与登录插件的球重叠，自动让到其下方");
                }
            }
        }
    }

    [self.ballConstraints addObject:[ball.widthAnchor constraintEqualToConstant:size]];
    [self.ballConstraints addObject:[ball.heightAnchor constraintEqualToConstant:size]];
    [self.ballConstraints addObject:[ball.leadingAnchor constraintEqualToAnchor:container.leadingAnchor constant:x]];
    [self.ballConstraints addObject:[ball.topAnchor constraintEqualToAnchor:container.topAnchor constant:y]];
    [NSLayoutConstraint activateConstraints:self.ballConstraints];
}

- (void)setBallVisible:(BOOL)visible {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self setBallVisible:visible];
        });
        return;
    }
    self.ball.hidden = !visible;
}

#pragma mark - 资源完整就把球收起来

/// 资源已完整（客户端 isDownloaded()/isAssetComplete() 同口径）⇒ 藏球；不完整 ⇒ 球回来。
/// 三条触发路径：install 之后、看门狗每 ≈30s、App 回到前台；状态没翻转时不记日志。
- (void)refreshBallVisibilityForCompleteness {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self refreshBallVisibilityForCompleteness];
        });
        return;
    }
    if (CdnImporterForceBallEnabled()) {
        if (self.completenessHidesBall) {
            self.completenessHidesBall = NO;
            [self setBallVisible:YES];
            CdnImporterLog(@"[overlay] CdnImporterForceBall 已打开，强制显示悬浮球");
        }
        return;
    }
    BOOL complete = CdnImporterAssetsAreComplete();
    if (complete == self.completenessHidesBall) {
        return;
    }
    self.completenessHidesBall = complete;
    [self setBallVisible:!complete];
    if (complete) {
        [self hidePanel];
        CdnImporterLog(@"[overlay] 资源已完整（%@），收起悬浮球；想再导入就删掉 info.json，"
                       @"或把 NSUserDefaults 的 CdnImporterForceBall 设为 YES", CdnImporterAssetCompletenessNote());
    } else {
        CdnImporterLog(@"[overlay] 资源又不完整了（%@），悬浮球回来了", CdnImporterAssetCompletenessNote());
    }
}

- (void)handleApplicationDidBecomeActive:(NSNotification *)note {
    if (![NSThread isMainThread]) return;
    [self refreshBallVisibilityForCompleteness];
}

#pragma mark - 保活（三条路幂等：定时器 + 窗口变 key + 手动 install）

- (void)startWatchdog {
    if (self.watchdog != nil) return;
    self.watchdog = [NSTimer scheduledTimerWithTimeInterval:2.0
                                                    repeats:YES
                                                      block:^(NSTimer *timer) {
        if (self.window == nil) {
            [self install];
            return;
        }
        // 每 2s 复查宿主：登录插件的覆盖层起来/收掉都能在 2s 内切过去（同层 ↔ 自己的窗口）
        [self syncHostWindow];
        // 每 15 跳（≈30s）复查一次资源完整度：导完 / 版本变了 / 手动删了 info.json 都能自愈
        self.watchdogTicks++;
        if (self.watchdogTicks % 15 == 0) {
            [self refreshBallVisibilityForCompleteness];
        }
    }];
}

- (void)handleWindowBecameKey:(NSNotification *)note {
    if (![NSThread isMainThread]) return;
    if (self.window == nil) {
        [self install];
        return;
    }
    [self syncHostWindow];
}

- (void)handleWindowVisibilityChanged:(NSNotification *)note {
    if (![NSThread isMainThread]) return;
    if (self.window == nil) return;
    [self syncHostWindow];
}

#pragma mark - 交互

- (void)handleBallPan:(UIPanGestureRecognizer *)gesture {
    CdnImporterBallView *ball = self.ball;
    UIView *container = ball.superview ?: self.window;
    if (container == nil || ball == nil) return;

    CGPoint translation = [gesture translationInView:container];
    [gesture setTranslation:CGPointZero inView:container];

    CGPoint center = ball.center;
    center.x += translation.x;
    center.y += translation.y;
    CGFloat half = kCdnBallSize / 2.0;
    center.x = MIN(MAX(half, center.x), MAX(half, container.bounds.size.width - half));
    center.y = MIN(MAX(half, center.y), MAX(half, container.bounds.size.height - half));
    ball.center = center;

    if (gesture.state == UIGestureRecognizerStateEnded || gesture.state == UIGestureRecognizerStateCancelled) {
        CGRect frame = ball.frame;
        NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
        [defaults setDouble:frame.origin.x forKey:CdnImporterBallXKey];
        [defaults setDouble:frame.origin.y forKey:CdnImporterBallYKey];
    }
}

- (void)handleBallTap:(UITapGestureRecognizer *)gesture {
    [self showPanel];
}

- (void)showPanel {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self showPanel];
        });
        return;
    }
    UIWindow *window = self.window;
    if (window == nil) {
        [self install];
        return;
    }

    // 面板跟球挂在同一个容器上（球在别人的悬浮层里时，面板也在那一层）
    UIView *container = self.ball.superview ?: self.window;
    if (container == nil) {
        [self install];
        return;
    }

    if (self.panel == nil) {
        CdnImporterPanelViewController *panel = [[CdnImporterPanelViewController alloc] init];
        __weak typeof(self) weakSelf = self;
        panel.closeHandler = ^{
            [weakSelf hidePanel];
        };
        self.panel = panel;
    }

    CGFloat width = MIN(container.bounds.size.width - 24.0, 380.0);
    CGFloat height = MIN(container.bounds.size.height - 80.0, 560.0);
    self.panel.view.frame = CGRectMake((container.bounds.size.width - width) / 2.0,
                                       (container.bounds.size.height - height) / 2.0,
                                       width, height);
    self.panel.view.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleRightMargin |
        UIViewAutoresizingFlexibleTopMargin | UIViewAutoresizingFlexibleBottomMargin;
    if (self.panel.view.superview != container) {
        [self.panel.view removeFromSuperview];
        [container addSubview:self.panel.view];
    }
    self.panel.view.hidden = NO;
    [self.panel refreshFromDisk];
}

- (void)hidePanel {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self hidePanel];
        });
        return;
    }
    self.panel.view.hidden = YES;
    // 关面板时顺手复查一次：导入刚成功的话，球这次就收起来了
    [self refreshBallVisibilityForCompleteness];
}

@end
