#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <notify.h>
#import "XLHIDSender.h"
#import "XingLanSwipeShared.h"

static const uint32_t XLMinimumDelay = 12;
static const uint32_t XLMaximumDelay = 18;
static const uint32_t XLBackMinimumDelay = 25;
static const uint32_t XLBackMaximumDelay = 35;
static const uint32_t XLConflictRetryDelay = 5;
static const CFTimeInterval XLGestureCooldown = 5.0;
static const double XLBackTapMinimumX = 0.036;
static const double XLBackTapMaximumX = 0.092;
static const double XLBackTapMinimumY = 0.942;
static const double XLBackTapMaximumY = 0.982;

static dispatch_source_t xlTimer;
static dispatch_source_t xlBackTimer;
static XLHIDSender *xlSender;
static BOOL xlRunning = NO;
static BOOL xlActionBusy = NO;
static NSUInteger xlRunGeneration = 0;
static CFAbsoluteTime xlLastGestureEndTime = 0.0;
static CFAbsoluteTime xlNextBackCheckTime = 0.0;
static UIWindow *xlStatusWindow;
static UILabel *xlHomeStatusLabel;

@interface XLStatusOverlayWindow : UIWindow
@end

@implementation XLStatusOverlayWindow
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    (void)point; (void)event;
    return nil;
}
@end

static void XLUpdateUI(void) {
    UILabel *status = xlHomeStatusLabel;
    if (status) {
        status.hidden = !xlRunning;
        status.text = @"开";
    }
}

static void XLShowStatusText(NSString *text, NSTimeInterval duration) {
    UILabel *status = xlHomeStatusLabel;
    if (!status || !xlRunning) return;

    status.hidden = NO;
    status.text = text;
    NSUInteger generation = xlRunGeneration;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                 (int64_t)(duration * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        if (xlRunning && generation == xlRunGeneration) XLUpdateUI();
    });
}

static void XLCancelTimer(void) {
    if (xlTimer) {
        dispatch_source_cancel(xlTimer);
        xlTimer = nil;
    }
}

static void XLCancelBackTimer(void) {
    if (xlBackTimer) {
        dispatch_source_cancel(xlBackTimer);
        xlBackTimer = nil;
    }
    xlNextBackCheckTime = 0.0;
}

static void XLScheduleNext(void);
static void XLScheduleSwipeAfterDelay(uint32_t delay);
static void XLScheduleNextBackSwipe(void);
static void XLScheduleBackSwipeAfterDelay(uint32_t delay, BOOL quickVerification);
static void XLPerformBackSwipe(BOOL quickVerification);

static BOOL XLGestureCooldownIsActive(void) {
    if (xlLastGestureEndTime <= 0.0) return NO;
    return CFAbsoluteTimeGetCurrent() - xlLastGestureEndTime < XLGestureCooldown;
}

static void XLPerformSwipe(void) {
    XLCancelTimer();
    if (!xlRunning) return;
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    BOOL backCheckDueSoon = xlNextBackCheckTime > 0.0 &&
        xlNextBackCheckTime - now <= XLGestureCooldown;
    if (xlActionBusy || XLGestureCooldownIsActive() || backCheckDueSoon) {
        NSLog(@"[XingLanSwipe] local swipe deferred to avoid action conflict");
        XLScheduleSwipeAfterDelay(XLConflictRetryDelay);
        return;
    }
    xlActionBusy = YES;
    NSUInteger generation = xlRunGeneration;
    if (!xlSender) xlSender = [XLHIDSender new];
    [xlSender performNaturalUpSwipeWithCompletion:^(BOOL success) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (generation != xlRunGeneration) return;
            xlActionBusy = NO;
            xlLastGestureEndTime = CFAbsoluteTimeGetCurrent();
            NSLog(@"[XingLanSwipe] local swipe %@", success ? @"success" : @"failed");
            if (xlRunning) XLScheduleNext();
        });
    }];
}

static BOOL XLReadRunningPreference(void) {
    CFPreferencesAppSynchronize(CFSTR(XLPreferenceDomain));
    CFPropertyListRef value = CFPreferencesCopyAppValue(
        CFSTR(XLRunningPreferenceKey), CFSTR(XLPreferenceDomain));
    BOOL running = value && CFEqual(value, kCFBooleanTrue);
    if (value) CFRelease(value);
    return running;
}

@interface UIApplication (XingLanFrontmostApplication)
- (id)_accessibilityFrontMostApplication;
@end

@interface NSObject (XingLanApplicationIdentity)
- (NSString *)bundleIdentifier;
@end

static NSString *XLFrontmostBundleIdentifier(void) {
    @try {
        UIApplication *application = UIApplication.sharedApplication;
        if (![application respondsToSelector:@selector(_accessibilityFrontMostApplication)]) {
            return nil;
        }
        id frontmost = [application _accessibilityFrontMostApplication];
        if (![frontmost respondsToSelector:@selector(bundleIdentifier)]) return nil;
        NSString *bundleIdentifier = [frontmost bundleIdentifier];
        return [bundleIdentifier isKindOfClass:NSString.class] ? bundleIdentifier : nil;
    } @catch (NSException *exception) {
        NSLog(@"[XingLanSwipe] foreground lookup failed: %@", exception.reason);
        return nil;
    }
}

static double XLRandomCoordinate(double minimum, double maximum) {
    double unit = (double)arc4random_uniform(1000001) / 1000000.0;
    return minimum + (maximum - minimum) * unit;
}

static void XLPerformBackSwipe(BOOL quickVerification) {
    XLCancelBackTimer();
    if (!xlRunning) return;
    if (xlActionBusy || XLGestureCooldownIsActive()) {
        NSLog(@"[XingLanSwipe] back check deferred to avoid action conflict");
        XLScheduleBackSwipeAfterDelay(XLConflictRetryDelay, quickVerification);
        return;
    }
    NSString *frontmost = XLFrontmostBundleIdentifier();
    if (![frontmost isEqualToString:@"com.baidu.BaiduMobileInfo"]) {
        NSLog(@"[XingLanSwipe] fixed back tap skipped; foreground=%@",
              frontmost ?: @"unknown");
        if (quickVerification) XLShowStatusText(@"非百", 4.0);
        XLScheduleNextBackSwipe();
        return;
    }

    xlActionBusy = YES;
    NSUInteger generation = xlRunGeneration;
    double tapX = XLRandomCoordinate(XLBackTapMinimumX, XLBackTapMaximumX);
    double tapY = XLRandomCoordinate(XLBackTapMinimumY, XLBackTapMaximumY);
    if (!xlSender) xlSender = [XLHIDSender new];
    NSLog(@"[XingLanSwipe] Baidu foreground; randomized HID tap at %.4fx%.4f",
          tapX, tapY);
    [xlSender performTapAtNormalizedX:tapX y:tapY
                           completion:^(BOOL success) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (generation != xlRunGeneration) return;
            xlActionBusy = NO;
            if (success) xlLastGestureEndTime = CFAbsoluteTimeGetCurrent();
            XLShowStatusText(success ? @"点✓" : @"点×", 4.0);
            NSLog(@"[XingLanSwipe] randomized Baidu back tap %@",
                  success ? @"success" : @"failed");
            if (xlRunning) XLScheduleNextBackSwipe();
        });
    }];
}

static void XLScheduleSwipeAfterDelay(uint32_t delay) {
    XLCancelTimer();
    if (!xlRunning) return;
    NSLog(@"[XingLanSwipe] next local swipe in %u seconds", delay);
    xlTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0,
        dispatch_get_main_queue());
    dispatch_source_set_timer(xlTimer,
        dispatch_time(DISPATCH_TIME_NOW, (int64_t)delay * NSEC_PER_SEC),
        DISPATCH_TIME_FOREVER, NSEC_PER_SEC / 4);
    dispatch_source_set_event_handler(xlTimer, ^{ XLPerformSwipe(); });
    dispatch_resume(xlTimer);
}

static void XLScheduleNext(void) {
    uint32_t delay = XLMinimumDelay +
        arc4random_uniform(XLMaximumDelay - XLMinimumDelay + 1);
    XLScheduleSwipeAfterDelay(delay);
}

static void XLScheduleBackSwipeAfterDelay(uint32_t delay, BOOL quickVerification) {
    XLCancelBackTimer();
    if (!xlRunning) return;
    xlNextBackCheckTime = CFAbsoluteTimeGetCurrent() + delay;
    NSLog(@"[XingLanSwipe] %@ system back check in %u seconds",
          quickVerification ? @"initial verification" : @"next", delay);
    xlBackTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0,
        dispatch_get_main_queue());
    dispatch_source_set_timer(xlBackTimer,
        dispatch_time(DISPATCH_TIME_NOW, (int64_t)delay * NSEC_PER_SEC),
        DISPATCH_TIME_FOREVER, NSEC_PER_SEC / 4);
    dispatch_source_set_event_handler(xlBackTimer, ^{ XLPerformBackSwipe(quickVerification); });
    dispatch_resume(xlBackTimer);
}

static void XLScheduleNextBackSwipe(void) {
    uint32_t delay = XLBackMinimumDelay +
        arc4random_uniform(XLBackMaximumDelay - XLBackMinimumDelay + 1);
    XLScheduleBackSwipeAfterDelay(delay, NO);
}

static void XLSetRunning(BOOL running) {
    CFPreferencesSetAppValue(CFSTR(XLRunningPreferenceKey),
        running ? kCFBooleanTrue : kCFBooleanFalse,
        CFSTR(XLPreferenceDomain));
    CFPreferencesAppSynchronize(CFSTR(XLPreferenceDomain));

    if (xlRunning == running) {
        XLUpdateUI();
        return;
    }

    xlRunning = running;
    xlRunGeneration++;
    if (xlRunning) {
        XLScheduleNext();
        XLScheduleBackSwipeAfterDelay(8, YES);
        NSLog(@"[XingLanSwipe] started from Control Center");
    } else {
        XLCancelTimer();
        XLCancelBackTimer();
        xlActionBusy = NO;
        xlLastGestureEndTime = 0.0;
        NSLog(@"[XingLanSwipe] stopped");
    }
    XLUpdateUI();
}

static void XLInstallStatusOverlay(void) {
    if (xlStatusWindow) {
        XLUpdateUI();
        return;
    }

    CGRect bounds = UIScreen.mainScreen.bounds;
    UIWindowScene *activeScene = nil;
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if ([scene isKindOfClass:UIWindowScene.class] &&
            scene.activationState != UISceneActivationStateUnattached) {
            activeScene = (UIWindowScene *)scene;
            break;
        }
    }

    XLStatusOverlayWindow *window;
    if (@available(iOS 13.0, *)) {
        if (activeScene) {
            window = [[XLStatusOverlayWindow alloc] initWithWindowScene:activeScene];
            window.frame = bounds;
        } else {
            window = [[XLStatusOverlayWindow alloc] initWithFrame:bounds];
        }
    } else {
        window = [[XLStatusOverlayWindow alloc] initWithFrame:bounds];
    }
    window.windowLevel = UIWindowLevelAlert + 1000.0;
    window.backgroundColor = UIColor.clearColor;
    window.userInteractionEnabled = NO;

    UIViewController *controller = [UIViewController new];
    controller.view.backgroundColor = UIColor.clearColor;
    controller.view.userInteractionEnabled = NO;
    window.rootViewController = controller;

    UILabel *status = [UILabel new];
    status.translatesAutoresizingMaskIntoConstraints = NO;
    status.userInteractionEnabled = NO;
    status.textAlignment = NSTextAlignmentCenter;
    status.font = [UIFont boldSystemFontOfSize:20.0];
    status.textColor = UIColor.whiteColor;
    status.backgroundColor = [UIColor colorWithRed:0.05 green:0.46 blue:0.94 alpha:0.82];
    status.layer.cornerRadius = 27.0;
    status.layer.borderWidth = 1.5;
    status.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.80].CGColor;
    status.layer.shadowColor = UIColor.blackColor.CGColor;
    status.layer.shadowOpacity = 0.35;
    status.layer.shadowRadius = 4.0;
    status.layer.shadowOffset = CGSizeZero;
    status.clipsToBounds = YES;
    [controller.view addSubview:status];

    UILayoutGuide *safeArea = controller.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [status.leadingAnchor constraintEqualToAnchor:safeArea.leadingAnchor constant:5.0],
        [status.centerYAnchor constraintEqualToAnchor:safeArea.centerYAnchor],
        [status.widthAnchor constraintEqualToConstant:54.0],
        [status.heightAnchor constraintEqualToConstant:54.0],
    ]];
    xlStatusWindow = window;
    xlHomeStatusLabel = status;
    window.hidden = NO;
    XLUpdateUI();
}

static void XLLockCallback(CFNotificationCenterRef center, void *observer,
                           CFStringRef name, const void *object,
                           CFDictionaryRef userInfo) {
    (void)center; (void)observer; (void)name; (void)object; (void)userInfo;
    dispatch_async(dispatch_get_main_queue(), ^{ XLSetRunning(NO); });
}

static void XLControlCenterStateCallback(CFNotificationCenterRef center, void *observer,
                                         CFStringRef name, const void *object,
                                         CFDictionaryRef userInfo) {
    (void)center; (void)observer; (void)name; (void)object; (void)userInfo;
    BOOL running = XLReadRunningPreference();
    dispatch_async(dispatch_get_main_queue(), ^{ XLSetRunning(running); });
}

__attribute__((constructor))
static void XingLanSwipeInit(void) {
    @autoreleasepool {
        NSString *bundleIdentifier = NSBundle.mainBundle.bundleIdentifier;
        if ([bundleIdentifier isEqualToString:@"com.apple.springboard"]) {
            dispatch_async(dispatch_get_main_queue(), ^{
                xlSender = [XLHIDSender new];
                XLInstallStatusOverlay();
                XLSetRunning(NO);
                CFNotificationCenterAddObserver(
                    CFNotificationCenterGetDarwinNotifyCenter(),
                    NULL, XLLockCallback,
                    CFSTR("com.apple.springboard.lockcomplete"),
                    NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
                CFNotificationCenterAddObserver(
                    CFNotificationCenterGetDarwinNotifyCenter(),
                    NULL, XLControlCenterStateCallback,
                    CFSTR(XLControlCenterStateNotification),
                    NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
                NSLog(@"[XingLanSwipe] loaded; add the module in Control Center settings");
            });
        }
    }
}
