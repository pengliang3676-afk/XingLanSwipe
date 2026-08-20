#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <math.h>
#import <notify.h>
#import "XLHIDSender.h"
#import "XingLanSwipeShared.h"

static const uint32_t XLMinimumDelay = 12;
static const uint32_t XLMaximumDelay = 18;
static const uint32_t XLBackMinimumDelay = 25;
static const uint32_t XLBackMaximumDelay = 35;
static const uint32_t XLConflictRetryDelay = 5;
static const CFTimeInterval XLGestureCooldown = 5.0;
static const NSTimeInterval XLBackRequestTimeout = 3.0;

static dispatch_source_t xlTimer;
static dispatch_source_t xlBackTimer;
static XLHIDSender *xlSender;
static BOOL xlRunning = NO;
static BOOL xlActionBusy = NO;
static BOOL xlBackRequestPending = NO;
static BOOL xlBackRequestQuickVerification = NO;
static NSUInteger xlBackRequestSerial = 0;
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

static void XLPostBackResult(CFStringRef notification) {
    CFNotificationCenterPostNotification(
        CFNotificationCenterGetDarwinNotifyCenter(),
        notification, NULL, NULL, YES);
}

static BOOL XLValidAccessibilityFrame(CGRect frame) {
    return !CGRectIsNull(frame) && !CGRectIsInfinite(frame) &&
        isfinite(frame.origin.x) && isfinite(frame.origin.y) &&
        isfinite(frame.size.width) && isfinite(frame.size.height) &&
        frame.size.width > 0.0 && frame.size.height > 0.0;
}

static CGRect XLFrameForAccessibilityElement(id element) {
    CGRect frame = CGRectZero;
    @try {
        frame = [element accessibilityFrame];
    } @catch (__unused NSException *exception) {
        frame = CGRectZero;
    }
    if (!XLValidAccessibilityFrame(frame) && [element isKindOfClass:UIView.class]) {
        UIView *view = (UIView *)element;
        frame = [view convertRect:view.bounds toView:nil];
    }
    return frame;
}

static void XLCollectAccessibleButtons(id element,
                                       NSMutableArray *buttons,
                                       NSMutableSet<NSValue *> *visited,
                                       NSUInteger depth) {
    if (!element || depth > 48 || visited.count >= 2048 || buttons.count > 64) return;
    NSValue *identity = [NSValue valueWithPointer:(__bridge const void *)element];
    if ([visited containsObject:identity]) return;
    [visited addObject:identity];

    if ([element isKindOfClass:UIView.class]) {
        UIView *view = (UIView *)element;
        if (view.hidden || view.alpha < 0.01 || !view.userInteractionEnabled) return;
    }

    @try {
        if ([element isAccessibilityElement]) {
            if (([element accessibilityTraits] & UIAccessibilityTraitButton) != 0) {
                [buttons addObject:element];
            }
            return;
        }

        NSInteger count = [element accessibilityElementCount];
        if (count > 0 && count <= 256) {
            for (NSInteger index = 0; index < count; index++) {
                XLCollectAccessibleButtons([element accessibilityElementAtIndex:index],
                                           buttons, visited, depth + 1);
            }
        }
    } @catch (NSException *exception) {
        NSLog(@"[XingLanSwipe] accessibility container ignored: %@", exception.reason);
    }

    if ([element isKindOfClass:UIView.class]) {
        for (UIView *subview in ((UIView *)element).subviews) {
            XLCollectAccessibleButtons(subview, buttons, visited, depth + 1);
        }
    }
}

static NSString *XLAccessibilityLabel(id element) {
    NSString *label = nil;
    @try {
        label = [element accessibilityLabel];
    } @catch (__unused NSException *exception) {
        label = nil;
    }
    if (![label isKindOfClass:NSString.class]) return @"";
    return [label stringByTrimmingCharactersInSet:
        NSCharacterSet.whitespaceAndNewlineCharacterSet];
}

static NSArray *XLForegroundAccessibilityButtons(void) {
    UIApplication *application = UIApplication.sharedApplication;
    if (application.applicationState != UIApplicationStateActive) return @[];

    NSMutableArray<UIWindow *> *windows = [NSMutableArray array];
    if (@available(iOS 13.0, *)) {
        for (UIScene *scene in application.connectedScenes) {
            if (![scene isKindOfClass:UIWindowScene.class] ||
                scene.activationState != UISceneActivationStateForegroundActive) continue;
            [windows addObjectsFromArray:((UIWindowScene *)scene).windows];
        }
    }
    NSMutableArray *buttons = [NSMutableArray array];
    NSMutableSet<NSValue *> *visited = [NSMutableSet set];
    for (UIWindow *window in windows) {
        if (window.hidden || window.alpha < 0.01) continue;
        XLCollectAccessibleButtons(window, buttons, visited, 0);
    }
    return buttons;
}

static id XLUniqueBottomLeftBlankButton(CFStringRef *failureNotification) {
    if (failureNotification) *failureNotification = CFSTR(XLBackCheckNoButtonNotification);
    CGRect screenBounds = UIScreen.mainScreen.bounds;
    CGSize screenSize = screenBounds.size;
    if (screenSize.width <= 0.0 || screenSize.height <= 0.0 ||
        screenSize.height <= screenSize.width) return nil;

    NSMutableArray *regionalButtons = [NSMutableArray array];
    for (id button in XLForegroundAccessibilityButtons()) {
        CGRect frame = XLFrameForAccessibilityElement(button);
        if (!XLValidAccessibilityFrame(frame) || frame.size.width < 8.0 ||
            frame.size.height < 8.0 || frame.size.width > screenSize.width * 0.30 ||
            frame.size.height > screenSize.height * 0.20) continue;
        CGPoint center = CGPointMake(CGRectGetMidX(frame), CGRectGetMidY(frame));
        double x = center.x / screenSize.width;
        double y = center.y / screenSize.height;
        if (x >= 0.02 && x <= 0.14 && y >= 0.90 && y <= 0.99) {
            [regionalButtons addObject:button];
        }
    }

    if (regionalButtons.count != 1) {
        NSLog(@"[XingLanSwipe] back UI skipped: %lu bottom-left buttons",
              (unsigned long)regionalButtons.count);
        if (failureNotification && regionalButtons.count > 1) {
            *failureNotification = CFSTR(XLBackCheckMultipleNotification);
        }
        return nil;
    }
    id button = regionalButtons.firstObject;
    NSString *label = XLAccessibilityLabel(button);
    if (label.length != 0) {
        NSLog(@"[XingLanSwipe] back UI skipped: bottom-left label=%@", label);
        if (failureNotification) {
            *failureNotification = CFSTR(XLBackCheckLabeledNotification);
        }
        return nil;
    }
    return button;
}

static void XLBaiduBackRequestCallback(CFNotificationCenterRef center, void *observer,
                                       CFStringRef name, const void *object,
                                       CFDictionaryRef userInfo) {
    (void)center; (void)observer; (void)name; (void)object; (void)userInfo;
    dispatch_async(dispatch_get_main_queue(), ^{
        @autoreleasepool {
            if (UIApplication.sharedApplication.applicationState != UIApplicationStateActive) {
                NSLog(@"[XingLanSwipe] back UI skipped: Baidu is not active");
                XLPostBackResult(CFSTR(XLBackCheckInactiveNotification));
                return;
            }
            @try {
                CFStringRef failureNotification = CFSTR(XLBackCheckNoButtonNotification);
                id button = XLUniqueBottomLeftBlankButton(&failureNotification);
                if (!button) {
                    XLPostBackResult(failureNotification);
                    return;
                }
                CGRect frame = XLFrameForAccessibilityElement(button);
                CGSize screenSize = UIScreen.mainScreen.bounds.size;
                CGPoint tapPoint = CGPointMake(CGRectGetMidX(frame) / screenSize.width,
                                               CGRectGetMidY(frame) / screenSize.height);
                if (!xlSender) xlSender = [XLHIDSender new];
                NSLog(@"[XingLanSwipe] back UI confirmed; HID tap at %.4fx%.4f",
                      tapPoint.x, tapPoint.y);
                [xlSender performTapAtNormalizedX:tapPoint.x y:tapPoint.y
                                       completion:^(BOOL success) {
                    NSLog(@"[XingLanSwipe] accessibility-guided HID tap %@",
                          success ? @"success" : @"failed");
                    XLPostBackResult(success ? CFSTR(XLBackCheckTappedNotification)
                                             : CFSTR(XLBackCheckTapFailedNotification));
                }];
            } @catch (NSException *exception) {
                NSLog(@"[XingLanSwipe] back UI exception; skipped: %@", exception.reason);
                XLPostBackResult(CFSTR(XLBackCheckExceptionNotification));
            }
        }
    });
}

static void XLFinishBackRequest(BOOL tapped, NSString *statusText) {
    if (!xlBackRequestPending) return;
    xlBackRequestPending = NO;
    xlActionBusy = NO;
    if (tapped) xlLastGestureEndTime = CFAbsoluteTimeGetCurrent();
    NSLog(@"[XingLanSwipe] accessibility-guided back check %@",
          tapped ? @"tapped" : @"skipped");
    if (xlRunning && statusText.length > 0) {
        XLShowStatusText(statusText, 4.0);
    }
    if (xlRunning) XLScheduleNextBackSwipe();
}

static void XLBackResultCallback(CFNotificationCenterRef center, void *observer,
                                 CFStringRef name, const void *object,
                                 CFDictionaryRef userInfo) {
    (void)center; (void)observer; (void)object; (void)userInfo;
    BOOL tapped = CFEqual(name, CFSTR(XLBackCheckTappedNotification));
    NSString *statusText = @"无";
    if (tapped) statusText = @"点✓";
    else if (CFEqual(name, CFSTR(XLBackCheckInactiveNotification))) statusText = @"非前";
    else if (CFEqual(name, CFSTR(XLBackCheckNoButtonNotification))) statusText = @"控0";
    else if (CFEqual(name, CFSTR(XLBackCheckMultipleNotification))) statusText = @"控多";
    else if (CFEqual(name, CFSTR(XLBackCheckLabeledNotification))) statusText = @"有字";
    else if (CFEqual(name, CFSTR(XLBackCheckTapFailedNotification))) statusText = @"点×";
    else if (CFEqual(name, CFSTR(XLBackCheckExceptionNotification))) statusText = @"异常";
    dispatch_async(dispatch_get_main_queue(), ^{ XLFinishBackRequest(tapped, statusText); });
}

static void XLPerformBackSwipe(BOOL quickVerification) {
    XLCancelBackTimer();
    if (!xlRunning) return;
    if (xlActionBusy || XLGestureCooldownIsActive()) {
        NSLog(@"[XingLanSwipe] back check deferred to avoid action conflict");
        XLScheduleBackSwipeAfterDelay(XLConflictRetryDelay, quickVerification);
        return;
    }
    xlActionBusy = YES;
    xlBackRequestPending = YES;
    xlBackRequestQuickVerification = quickVerification;
    NSUInteger requestSerial = ++xlBackRequestSerial;
    NSLog(@"[XingLanSwipe] requesting foreground Baidu accessibility check");
    CFNotificationCenterPostNotification(
        CFNotificationCenterGetDarwinNotifyCenter(),
        CFSTR(XLBackCheckRequestNotification), NULL, NULL, YES);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                 (int64_t)(XLBackRequestTimeout * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        if (xlBackRequestPending && requestSerial == xlBackRequestSerial) {
            NSLog(@"[XingLanSwipe] back UI request timed out; skipped");
            XLFinishBackRequest(NO, @"超时");
        }
    });
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
        xlBackRequestPending = NO;
        xlBackRequestSerial++;
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
                CFNotificationCenterAddObserver(
                    CFNotificationCenterGetDarwinNotifyCenter(),
                    NULL, XLBackResultCallback,
                    CFSTR(XLBackCheckTappedNotification),
                    NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
                CFNotificationCenterAddObserver(
                    CFNotificationCenterGetDarwinNotifyCenter(),
                    NULL, XLBackResultCallback,
                    CFSTR(XLBackCheckSkippedNotification),
                    NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
                CFNotificationCenterAddObserver(
                    CFNotificationCenterGetDarwinNotifyCenter(), NULL, XLBackResultCallback,
                    CFSTR(XLBackCheckInactiveNotification), NULL,
                    CFNotificationSuspensionBehaviorDeliverImmediately);
                CFNotificationCenterAddObserver(
                    CFNotificationCenterGetDarwinNotifyCenter(), NULL, XLBackResultCallback,
                    CFSTR(XLBackCheckNoButtonNotification), NULL,
                    CFNotificationSuspensionBehaviorDeliverImmediately);
                CFNotificationCenterAddObserver(
                    CFNotificationCenterGetDarwinNotifyCenter(), NULL, XLBackResultCallback,
                    CFSTR(XLBackCheckMultipleNotification), NULL,
                    CFNotificationSuspensionBehaviorDeliverImmediately);
                CFNotificationCenterAddObserver(
                    CFNotificationCenterGetDarwinNotifyCenter(), NULL, XLBackResultCallback,
                    CFSTR(XLBackCheckLabeledNotification), NULL,
                    CFNotificationSuspensionBehaviorDeliverImmediately);
                CFNotificationCenterAddObserver(
                    CFNotificationCenterGetDarwinNotifyCenter(), NULL, XLBackResultCallback,
                    CFSTR(XLBackCheckTapFailedNotification), NULL,
                    CFNotificationSuspensionBehaviorDeliverImmediately);
                CFNotificationCenterAddObserver(
                    CFNotificationCenterGetDarwinNotifyCenter(), NULL, XLBackResultCallback,
                    CFSTR(XLBackCheckExceptionNotification), NULL,
                    CFNotificationSuspensionBehaviorDeliverImmediately);
                NSLog(@"[XingLanSwipe] loaded; add the module in Control Center settings");
            });
        } else if ([bundleIdentifier isEqualToString:@"com.baidu.BaiduMobileInfo"]) {
            CFNotificationCenterAddObserver(
                CFNotificationCenterGetDarwinNotifyCenter(),
                NULL, XLBaiduBackRequestCallback,
                CFSTR(XLBackCheckRequestNotification),
                NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
            NSLog(@"[XingLanSwipe] Baidu accessibility-guided HID helper loaded");
        }
    }
}
