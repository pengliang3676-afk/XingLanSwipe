#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <notify.h>
#import "XLHIDSender.h"
#import "XingLanSwipeShared.h"

static const uint32_t XLMinimumDelay = 180;
static const uint32_t XLMaximumDelay = 300;
static const uint32_t XLBackMinimumDelay = 300;
static const uint32_t XLBackMaximumDelay = 600;
static const uint32_t XLInitialBackVerificationDelay = 10;

static dispatch_source_t xlTimer;
static dispatch_source_t xlBackTimer;
static XLHIDSender *xlSender;
static BOOL xlRunning = NO;
static NSUInteger xlRunGeneration = 0;
static NSUInteger xlProfileCheckToken = 0;
static NSUInteger xlPendingProfileCheckToken = 0;
static BOOL xlPendingProfileCheckQuick = NO;
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
}

static void XLScheduleNext(void);
static void XLScheduleNextBackSwipe(void);
static void XLPerformBackSwipe(BOOL quickVerification);

static BOOL XLExactProfileTabText(NSString *text) {
    if (![text isKindOfClass:NSString.class]) return NO;
    NSString *normalized = [text stringByTrimmingCharactersInSet:
        NSCharacterSet.whitespaceAndNewlineCharacterSet];
    normalized = [normalized stringByReplacingOccurrencesOfString:@" " withString:@""];
    return [normalized isEqualToString:@"我的"];
}

static BOOL XLViewIsInBottomRight(UIView *view, UIWindow *window) {
    if (!view || !window || CGRectIsEmpty(view.bounds)) return NO;
    CGRect frame = [view convertRect:view.bounds toView:window];
    CGRect visible = CGRectIntersection(frame, window.bounds);
    if (CGRectIsEmpty(visible)) return NO;
    CGPoint center = CGPointMake(CGRectGetMidX(visible), CGRectGetMidY(visible));
    return center.x >= CGRectGetWidth(window.bounds) * 0.62 &&
           center.y >= CGRectGetHeight(window.bounds) * 0.72;
}

static BOOL XLVisibleViewTreeContainsProfileTab(UIView *view, UIWindow *window) {
    if (!view || view.hidden || view.alpha < 0.01) return NO;

    BOOL isProfileTab = NO;
    if ([view isKindOfClass:UILabel.class]) {
        isProfileTab = XLExactProfileTabText(((UILabel *)view).text);
    } else if ([view isKindOfClass:UITextView.class]) {
        isProfileTab = XLExactProfileTabText(((UITextView *)view).text);
    } else if ([view isKindOfClass:UIButton.class]) {
        isProfileTab = XLExactProfileTabText(((UIButton *)view).currentTitle);
    }
    if (!isProfileTab) isProfileTab = XLExactProfileTabText(view.accessibilityLabel);
    if (isProfileTab && XLViewIsInBottomRight(view, window)) return YES;

    for (UIView *subview in view.subviews) {
        if (XLVisibleViewTreeContainsProfileTab(subview, window)) return YES;
    }
    return NO;
}

static BOOL XLBaiduVisibleProfileTab(void) {
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class] ||
            scene.activationState == UISceneActivationStateUnattached) continue;
        for (UIWindow *window in ((UIWindowScene *)scene).windows) {
            if (window.hidden || window.alpha < 0.01) continue;
            if (XLVisibleViewTreeContainsProfileTab(window, window)) return YES;
        }
    }
    return NO;
}

static void XLPerformSwipe(void) {
    XLCancelTimer();
    if (!xlRunning) return;
    if (!xlSender) xlSender = [XLHIDSender new];
    [xlSender performNaturalUpSwipeWithCompletion:^(BOOL success) {
        NSLog(@"[XingLanSwipe] local swipe %@", success ? @"success" : @"failed");
        if (xlRunning) XLScheduleNext();
    }];
}

static void XLDispatchBackSwipe(BOOL quickVerification) {
    if (!xlSender) xlSender = [XLHIDSender new];
    [xlSender performSystemBackSwipeWithCompletion:^(BOOL success) {
        NSLog(@"[XingLanSwipe] system back swipe %@", success ? @"success" : @"failed");
        if (quickVerification && xlRunning) {
            XLShowStatusText(success ? @"回✓" : @"回×", 2.0);
        }
        if (xlRunning) XLScheduleNextBackSwipe();
    }];
}

static void XLFinishProfileCheck(BOOL visible, BOOL quickVerification) {
    xlPendingProfileCheckToken = 0;
    if (!xlRunning) return;
    if (!visible) {
        NSLog(@"[XingLanSwipe] Baidu profile tab text not visible; skipped back swipe");
        if (quickVerification) XLShowStatusText(@"无我", 2.0);
        XLScheduleNextBackSwipe();
        return;
    }
    NSLog(@"[XingLanSwipe] Baidu profile tab text visible; performing back swipe");
    XLDispatchBackSwipe(quickVerification);
}

static void XLRequestBaiduProfileCheck(BOOL quickVerification) {
    XLCancelBackTimer();
    if (!xlRunning) return;

    NSUInteger token = ++xlProfileCheckToken;
    xlPendingProfileCheckToken = token;
    xlPendingProfileCheckQuick = quickVerification;
    CFPreferencesSetAppValue(CFSTR(XLProfileCheckRequestKey),
        (__bridge CFPropertyListRef)[NSNumber numberWithUnsignedInteger:token],
        CFSTR(XLPreferenceDomain));
    CFPreferencesAppSynchronize(CFSTR(XLPreferenceDomain));
    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
        CFSTR(XLProfileCheckNotification), NULL, NULL, YES);

    NSUInteger generation = xlRunGeneration;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC),
                   dispatch_get_main_queue(), ^{
        if (!xlRunning || generation != xlRunGeneration ||
            xlPendingProfileCheckToken != token) return;
        NSLog(@"[XingLanSwipe] Baidu profile tab check timed out; skipped back swipe");
        XLFinishProfileCheck(NO, quickVerification);
    });
}

static void XLPerformBackSwipe(BOOL quickVerification) {
    XLRequestBaiduProfileCheck(quickVerification);
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

static void XLScheduleBackSwipeAfterDelay(uint32_t delay, BOOL quickVerification) {
    XLCancelBackTimer();
    if (!xlRunning) return;
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
    xlPendingProfileCheckToken = 0;
    if (xlRunning) {
        XLScheduleNext();
        XLScheduleBackSwipeAfterDelay(XLInitialBackVerificationDelay, YES);
        NSLog(@"[XingLanSwipe] started from Control Center");
    } else {
        XLCancelTimer();
        XLCancelBackTimer();
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
    CFPropertyListRef value = CFPreferencesCopyAppValue(
        CFSTR(XLRunningPreferenceKey), CFSTR(XLPreferenceDomain));
    BOOL running = (value && CFEqual(value, kCFBooleanTrue));
    if (value) CFRelease(value);
    dispatch_async(dispatch_get_main_queue(), ^{ XLSetRunning(running); });
}

static void XLProfileCheckResultCallback(CFNotificationCenterRef center, void *observer,
                                         CFStringRef name, const void *object,
                                         CFDictionaryRef userInfo) {
    (void)center; (void)observer; (void)name; (void)object; (void)userInfo;
    CFPropertyListRef requestValue = CFPreferencesCopyAppValue(
        CFSTR(XLProfileCheckResultRequestKey), CFSTR(XLPreferenceDomain));
    CFPropertyListRef visibleValue = CFPreferencesCopyAppValue(
        CFSTR(XLProfileCheckResultVisibleKey), CFSTR(XLPreferenceDomain));
    NSUInteger token = requestValue ?
        [(__bridge NSNumber *)requestValue unsignedIntegerValue] : 0;
    BOOL visible = (visibleValue && CFEqual(visibleValue, kCFBooleanTrue));
    if (requestValue) CFRelease(requestValue);
    if (visibleValue) CFRelease(visibleValue);

    dispatch_async(dispatch_get_main_queue(), ^{
        if (!xlRunning || token == 0 || token != xlPendingProfileCheckToken) return;
        XLFinishProfileCheck(visible, xlPendingProfileCheckQuick);
    });
}

static void XLBaiduProfileCheckCallback(CFNotificationCenterRef center, void *observer,
                                        CFStringRef name, const void *object,
                                        CFDictionaryRef userInfo) {
    (void)center; (void)observer; (void)name; (void)object; (void)userInfo;
    dispatch_async(dispatch_get_main_queue(), ^{
        CFPropertyListRef requestValue = CFPreferencesCopyAppValue(
            CFSTR(XLProfileCheckRequestKey), CFSTR(XLPreferenceDomain));
        NSUInteger token = requestValue ?
            [(__bridge NSNumber *)requestValue unsignedIntegerValue] : 0;
        if (requestValue) CFRelease(requestValue);
        if (token == 0) return;

        BOOL visible = XLBaiduVisibleProfileTab();
        CFPreferencesSetAppValue(CFSTR(XLProfileCheckResultRequestKey),
            (__bridge CFPropertyListRef)[NSNumber numberWithUnsignedInteger:token],
            CFSTR(XLPreferenceDomain));
        CFPreferencesSetAppValue(CFSTR(XLProfileCheckResultVisibleKey),
            visible ? kCFBooleanTrue : kCFBooleanFalse, CFSTR(XLPreferenceDomain));
        CFPreferencesAppSynchronize(CFSTR(XLPreferenceDomain));
        CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
            CFSTR(XLProfileCheckResultNotification), NULL, NULL, YES);
        NSLog(@"[XingLanSwipe] Baidu profile tab text %@",
              visible ? @"visible" : @"not visible");
    });
}

__attribute__((constructor))
static void XingLanSwipeInit(void) {
    @autoreleasepool {
        NSString *bundleIdentifier = NSBundle.mainBundle.bundleIdentifier;
        if ([bundleIdentifier isEqualToString:@"com.baidu.BaiduMobileInfo"]) {
            CFNotificationCenterAddObserver(
                CFNotificationCenterGetDarwinNotifyCenter(),
                NULL, XLBaiduProfileCheckCallback,
                CFSTR(XLProfileCheckNotification),
                NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
            NSLog(@"[XingLanSwipe] Baidu profile text reader loaded");
            return;
        }
        if (![bundleIdentifier isEqualToString:@"com.apple.springboard"]) return;
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
            CFNotificationCenterAddObserver(
                CFNotificationCenterGetDarwinNotifyCenter(),
                NULL, XLProfileCheckResultCallback,
                CFSTR(XLProfileCheckResultNotification),
                NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
            NSLog(@"[XingLanSwipe] loaded; add the module in Control Center settings");
        });
    }
}
