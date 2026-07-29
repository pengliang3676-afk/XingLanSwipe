#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <notify.h>
#import "XLHIDSender.h"

// Test build: shorten the interval so real-device swipe injection can be
// verified quickly. Restore to 180 / 300 after the device test passes.
static const uint32_t XLMinimumDelay = 10;
static const uint32_t XLMaximumDelay = 30;
static NSString *const XLPositionXKey = @"XingLanSwipeButtonX";
static NSString *const XLPositionYKey = @"XingLanSwipeButtonY";

static UIWindow *xlWindow;
static UIButton *xlButton;
static dispatch_source_t xlTimer;
static XLHIDSender *xlSender;
static BOOL xlRunning = NO;

@interface XLPassthroughWindow : UIWindow
@end

@implementation XLPassthroughWindow
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    UIView *hit = [super hitTest:point withEvent:event];
    return (hit == self || hit == self.rootViewController.view) ? nil : hit;
}
@end

@interface XLControlTarget : NSObject
- (void)toggle;
- (void)dragged:(UIPanGestureRecognizer *)gesture;
@end

static void XLUpdateButton(void) {
    if (!xlButton) return;
    [xlButton setTitle:xlRunning ? @"停" : @"开" forState:UIControlStateNormal];
    xlButton.backgroundColor = xlRunning
        ? [UIColor colorWithRed:0.78 green:0.10 blue:0.12 alpha:0.88]
        : [UIColor colorWithRed:0.05 green:0.46 blue:0.94 alpha:0.82];
    xlButton.accessibilityLabel = xlRunning ? @"停止星澜滑屏" : @"开始星澜滑屏";
}

static void XLCancelTimer(void) {
    if (xlTimer) {
        dispatch_source_cancel(xlTimer);
        xlTimer = nil;
    }
}

static void XLScheduleNext(void);

static void XLPerformSwipe(void) {
    XLCancelTimer();
    if (!xlRunning) return;
    if (!xlSender) xlSender = [XLHIDSender new];
    [xlSender performNaturalUpSwipeWithCompletion:^(BOOL success) {
        NSLog(@"[XingLanSwipe] local swipe %@", success ? @"success" : @"failed");
        if (xlRunning) XLScheduleNext();
    }];
}

static void XLScheduleNext(void) {
    XLCancelTimer();
    if (!xlRunning) return;
    uint32_t delay = XLMinimumDelay +
        arc4random_uniform(XLMaximumDelay - XLMinimumDelay + 1);
    NSLog(@"[XingLanSwipe] next local swipe in %u seconds", delay);
    xlTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0,
        dispatch_get_main_queue());
    dispatch_source_set_timer(xlTimer,
        dispatch_time(DISPATCH_TIME_NOW, (int64_t)delay * NSEC_PER_SEC),
        DISPATCH_TIME_FOREVER, NSEC_PER_SEC / 4);
    dispatch_source_set_event_handler(xlTimer, ^{ XLPerformSwipe(); });
    dispatch_resume(xlTimer);
}

static void XLStop(void) {
    xlRunning = NO;
    XLCancelTimer();
    XLUpdateButton();
    NSLog(@"[XingLanSwipe] stopped");
}

@implementation XLControlTarget
- (void)toggle {
    xlRunning = !xlRunning;
    XLUpdateButton();
    if (xlRunning) {
        // Test build only: perform one swipe immediately so HID injection can
        // be verified without waiting, then continue at random 10-30s delays.
        XLPerformSwipe();
        NSLog(@"[XingLanSwipe] started with immediate test swipe");
    } else {
        XLCancelTimer();
        NSLog(@"[XingLanSwipe] stopped by user");
    }
}

- (void)dragged:(UIPanGestureRecognizer *)gesture {
    CGPoint translation = [gesture translationInView:xlWindow];
    CGPoint center = xlButton.center;
    center.x += translation.x;
    center.y += translation.y;
    CGFloat half = CGRectGetWidth(xlButton.bounds) / 2.0;
    center.x = MIN(MAX(center.x, half + 3.0),
                   CGRectGetWidth(xlWindow.bounds) - half - 3.0);
    center.y = MIN(MAX(center.y, half + 24.0),
                   CGRectGetHeight(xlWindow.bounds) - half - 16.0);
    xlButton.center = center;
    [gesture setTranslation:CGPointZero inView:xlWindow];
    if (gesture.state == UIGestureRecognizerStateEnded ||
        gesture.state == UIGestureRecognizerStateCancelled) {
        NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
        [defaults setDouble:center.x forKey:XLPositionXKey];
        [defaults setDouble:center.y forKey:XLPositionYKey];
    }
}
@end

static XLControlTarget *xlTarget;

static void XLCreateOverlay(void) {
    if (xlWindow) return;
    CGRect bounds = UIScreen.mainScreen.bounds;
    UIWindowScene *activeScene = nil;
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if ([scene isKindOfClass:UIWindowScene.class] &&
            scene.activationState != UISceneActivationStateUnattached) {
            activeScene = (UIWindowScene *)scene;
            break;
        }
    }
    if (@available(iOS 13.0, *)) {
        if (activeScene) {
            xlWindow = [[XLPassthroughWindow alloc] initWithWindowScene:activeScene];
            xlWindow.frame = bounds;
        } else {
            xlWindow = [[XLPassthroughWindow alloc] initWithFrame:bounds];
        }
    } else {
        xlWindow = [[XLPassthroughWindow alloc] initWithFrame:bounds];
    }
    xlWindow.windowLevel = UIWindowLevelAlert + 1000.0;
    xlWindow.backgroundColor = UIColor.clearColor;
    UIViewController *controller = [UIViewController new];
    controller.view.backgroundColor = UIColor.clearColor;
    xlWindow.rootViewController = controller;
    xlWindow.hidden = NO;
    xlWindow.userInteractionEnabled = YES;

    xlButton = [UIButton buttonWithType:UIButtonTypeCustom];
    xlButton.bounds = CGRectMake(0, 0, 54, 54);
    xlButton.layer.cornerRadius = 27;
    xlButton.layer.borderWidth = 1.5;
    xlButton.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.80].CGColor;
    xlButton.titleLabel.font = [UIFont boldSystemFontOfSize:20];
    [xlButton setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    xlButton.layer.shadowColor = UIColor.blackColor.CGColor;
    xlButton.layer.shadowOpacity = 0.35;
    xlButton.layer.shadowRadius = 4;
    xlButton.layer.shadowOffset = CGSizeMake(0, 2);

    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    double savedX = [defaults doubleForKey:XLPositionXKey];
    double savedY = [defaults doubleForKey:XLPositionYKey];
    xlButton.center = CGPointMake(savedX > 0 ? savedX : bounds.size.width - 34,
                                  savedY > 0 ? savedY : bounds.size.height * 0.55);
    [xlButton addTarget:xlTarget action:@selector(toggle)
       forControlEvents:UIControlEventTouchUpInside];
    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc]
        initWithTarget:xlTarget action:@selector(dragged:)];
    [xlButton addGestureRecognizer:pan];
    [controller.view addSubview:xlButton];
    XLUpdateButton();
}

static void XLLockCallback(CFNotificationCenterRef center, void *observer,
                           CFStringRef name, const void *object,
                           CFDictionaryRef userInfo) {
    (void)center; (void)observer; (void)name; (void)object; (void)userInfo;
    dispatch_async(dispatch_get_main_queue(), ^{ XLStop(); });
}

__attribute__((constructor))
static void XingLanSwipeInit(void) {
    @autoreleasepool {
        dispatch_async(dispatch_get_main_queue(), ^{
            xlSender = [XLHIDSender new];
            xlTarget = [XLControlTarget new];
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC),
                           dispatch_get_main_queue(), ^{ XLCreateOverlay(); });
            CFNotificationCenterAddObserver(
                CFNotificationCenterGetDarwinNotifyCenter(),
                NULL, XLLockCallback,
                CFSTR("com.apple.springboard.lockcomplete"),
                NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
            NSLog(@"[XingLanSwipe] loaded; default state is stopped");
        });
    }
}
