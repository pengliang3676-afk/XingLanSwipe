#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <notify.h>
#import "XLBackIconDetector.h"
#import "XLHIDSender.h"
#import "XingLanSwipeShared.h"

static const uint32_t XLMinimumDelay = 180;
static const uint32_t XLMaximumDelay = 300;
static const uint32_t XLBackMinimumDelay = 420;
static const uint32_t XLBackMaximumDelay = 720;
static const uint32_t XLConflictRetryDelay = 5;
static const uint32_t XLDownSwipeProbabilityPercent = 8;
static const CFTimeInterval XLGestureCooldown = 5.0;
static const double XLBackTapMinimumX = 0.036;
static const double XLBackTapMaximumX = 0.092;
static const double XLBackTapMinimumY = 0.942;
static const double XLBackTapMaximumY = 0.982;
static const double XLBackChevronThreshold = 0.65;

static dispatch_source_t xlTimer;
static dispatch_source_t xlBackTimer;
static XLBackIconDetector *xlBackIconDetector;
static dispatch_queue_t xlImageMatchQueue;
static XLHIDSender *xlSender;
static BOOL xlControlEnabled = NO;
static BOOL xlRunning = NO;
static BOOL xlUserPaused = NO;
static BOOL xlActionBusy = NO;
static BOOL xlDeviceLocked = NO;
static int xlLockStateToken = 0;
static NSUInteger xlRunGeneration = 0;
static CFAbsoluteTime xlLastGestureEndTime = 0.0;
static CFAbsoluteTime xlNextBackCheckTime = 0.0;
static UIWindow *xlStatusWindow;
static UIView *xlOverlayRootView;
static UIButton *xlHomeStatusButton;
static UIView *xlActionPanel;
static UIButton *xlPauseButton;
static NSLayoutConstraint *xlActionPanelWidthConstraint;
static BOOL xlActionMenuExpanded = NO;

static void XLSetRunning(BOOL running);
static void XLSetActionMenuExpanded(BOOL expanded, BOOL animated);
static void XLHandleStatusButtonTap(void);
static void XLHandlePauseButtonTap(void);
static void XLHandleCloseButtonTap(void);

@interface XLStatusOverlayWindow : UIWindow
@end

@implementation XLStatusOverlayWindow
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    UIView *hitView = [super hitTest:point withEvent:event];
    if (hitView == self || hitView == self.rootViewController.view) return nil;
    return hitView;
}
@end

@interface XLStatusOverlayController : UIViewController
@end

@implementation XLStatusOverlayController
- (void)xlStatusTapped {
    XLHandleStatusButtonTap();
}

- (void)xlPauseTapped {
    XLHandlePauseButtonTap();
}

- (void)xlCloseTapped {
    XLHandleCloseButtonTap();
}
@end

static void XLSetActionMenuExpanded(BOOL expanded, BOOL animated) {
    if (!xlActionPanel || !xlActionPanelWidthConstraint || !xlOverlayRootView) return;
    if (!xlControlEnabled) expanded = NO;

    xlActionMenuExpanded = expanded;
    if (expanded) {
        xlActionPanel.hidden = NO;
        xlActionPanel.userInteractionEnabled = YES;
    }

    xlActionPanelWidthConstraint.constant = expanded ? 177.0 : 27.0;
    void (^changes)(void) = ^{
        xlActionPanel.alpha = expanded ? 1.0 : 0.0;
        [xlOverlayRootView layoutIfNeeded];
    };
    void (^completion)(BOOL) = ^(BOOL finished) {
        (void)finished;
        if (!xlActionMenuExpanded) {
            xlActionPanel.hidden = YES;
            xlActionPanel.userInteractionEnabled = NO;
        }
    };

    if (animated) {
        [UIView animateWithDuration:0.18
                              delay:0.0
                            options:UIViewAnimationOptionCurveEaseInOut |
                                    UIViewAnimationOptionBeginFromCurrentState
                         animations:changes
                         completion:completion];
    } else {
        changes();
        completion(YES);
    }
}

static void XLUpdateUI(void) {
    UIButton *status = xlHomeStatusButton;
    if (status) {
        if (!xlControlEnabled) {
            XLSetActionMenuExpanded(NO, NO);
            status.hidden = YES;
            return;
        }
        status.hidden = NO;
        NSString *statusText = xlUserPaused ? @"停" : (xlRunning ? @"开" : @"关");
        [status setTitle:statusText forState:UIControlStateNormal];
        if (xlRunning) {
            status.backgroundColor =
                [UIColor colorWithRed:0.90 green:0.12 blue:0.16 alpha:0.90];
        } else if (xlUserPaused) {
            status.backgroundColor =
                [UIColor colorWithRed:0.20 green:0.84 blue:0.38 alpha:0.94];
        } else {
            status.backgroundColor = [UIColor colorWithWhite:0.35 alpha:0.82];
        }
        [xlPauseButton setTitle:(xlUserPaused ? @"继续" : @"暂停")
                       forState:UIControlStateNormal];
        [xlPauseButton setTitleColor:(xlUserPaused
            ? [UIColor colorWithRed:0.20 green:0.84 blue:0.38 alpha:1.0]
            : [UIColor colorWithRed:1.0 green:0.70 blue:0.72 alpha:1.0])
                       forState:UIControlStateNormal];
    }
}

static void XLShowStatusText(NSString *text, NSTimeInterval duration) {
    UIButton *status = xlHomeStatusButton;
    if (!status || !xlRunning) return;

    status.hidden = NO;
    [status setTitle:text forState:UIControlStateNormal];
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
static void XLScheduleBackSwipeAfterDelay(uint32_t delay);
static void XLPerformBackSwipe(void);

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
    BOOL swipeUp = arc4random_uniform(100) >= XLDownSwipeProbabilityPercent;
    if (!xlSender) xlSender = [XLHIDSender new];
    [xlSender performNaturalSwipeUp:swipeUp completion:^(BOOL success) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (generation != xlRunGeneration) return;
            xlActionBusy = NO;
            xlLastGestureEndTime = CFAbsoluteTimeGetCurrent();
            NSLog(@"[XingLanSwipe] local %@ swipe %@",
                  swipeUp ? @"up" : @"down", success ? @"success" : @"failed");
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

static void XLWriteRunningPreference(BOOL running) {
    CFPreferencesSetAppValue(CFSTR(XLRunningPreferenceKey),
        running ? kCFBooleanTrue : kCFBooleanFalse,
        CFSTR(XLPreferenceDomain));
    CFPreferencesAppSynchronize(CFSTR(XLPreferenceDomain));
}

static double XLRandomCoordinate(double minimum, double maximum) {
    double unit = (double)arc4random_uniform(1000001) / 1000000.0;
    return minimum + (maximum - minimum) * unit;
}

static void XLPerformBackSwipe(void) {
    XLCancelBackTimer();
    if (!xlRunning) return;
    if (xlActionBusy || XLGestureCooldownIsActive()) {
        NSLog(@"[XingLanSwipe] back check deferred to avoid action conflict");
        XLScheduleBackSwipeAfterDelay(XLConflictRetryDelay);
        return;
    }
    xlActionBusy = YES;
    NSUInteger generation = xlRunGeneration;
    if (!xlBackIconDetector) xlBackIconDetector = [XLBackIconDetector new];

    __block UIImage *backRegion = nil;
    __block NSError *captureError = nil;
    @autoreleasepool {
        backRegion = [xlBackIconDetector captureBackRegionWithError:&captureError];
    }
    if (!backRegion) {
        xlActionBusy = NO;
        NSLog(@"[XingLanSwipe] cropped back capture failed: %@",
              captureError.localizedDescription ?: @"unknown");
        captureError = nil;
        XLShowStatusText(@"图×", 4.0);
        XLScheduleNextBackSwipe();
        return;
    }

    dispatch_async(xlImageMatchQueue, ^{
        @autoreleasepool {
            UIImage *imageForMatch = backRegion;
            backRegion = nil;
            NSError *matchError = nil;
            double score = [xlBackIconDetector matchScoreForBackRegion:imageForMatch
                                                                  error:&matchError];
            imageForMatch = nil;
            BOOL found = !matchError && score >= XLBackChevronThreshold;
            NSString *errorText = matchError.localizedDescription;
            matchError = nil;

            dispatch_async(dispatch_get_main_queue(), ^{
                if (!xlRunning || generation != xlRunGeneration) return;
                if (errorText.length > 0) {
                    xlActionBusy = NO;
                    NSLog(@"[XingLanSwipe] cropped back match failed: %@", errorText);
                    XLShowStatusText(@"图×", 4.0);
                    XLScheduleNextBackSwipe();
                    return;
                }
                NSLog(@"[XingLanSwipe] cropped back detection %@ score=%.4f",
                      found ? @"present" : @"absent", score);
                if (!found) {
                    xlActionBusy = NO;
                    XLShowStatusText(@"无", 4.0);
                    XLScheduleNextBackSwipe();
                    return;
                }

                double tapX = XLRandomCoordinate(
                    XLBackTapMinimumX, XLBackTapMaximumX);
                double tapY = XLRandomCoordinate(
                    XLBackTapMinimumY, XLBackTapMaximumY);
                if (!xlSender) xlSender = [XLHIDSender new];
                NSLog(@"[XingLanSwipe] cropped back confirmed; randomized HID tap at %.4fx%.4f",
                      tapX, tapY);
                [xlSender performTapAtNormalizedX:tapX y:tapY
                                       completion:^(BOOL success) {
                    dispatch_async(dispatch_get_main_queue(), ^{
                        if (generation != xlRunGeneration) return;
                        xlActionBusy = NO;
                        if (success) {
                            xlLastGestureEndTime = CFAbsoluteTimeGetCurrent();
                        }
                        XLShowStatusText(success ? @"识✓" : @"点×", 4.0);
                        NSLog(@"[XingLanSwipe] cropped back tap %@",
                              success ? @"success" : @"failed");
                        if (xlRunning) XLScheduleNextBackSwipe();
                    });
                }];
            });
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

static void XLScheduleBackSwipeAfterDelay(uint32_t delay) {
    XLCancelBackTimer();
    if (!xlRunning) return;
    xlNextBackCheckTime = CFAbsoluteTimeGetCurrent() + delay;
    NSLog(@"[XingLanSwipe] next system back check in %u seconds", delay);
    xlBackTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0,
        dispatch_get_main_queue());
    dispatch_source_set_timer(xlBackTimer,
        dispatch_time(DISPATCH_TIME_NOW, (int64_t)delay * NSEC_PER_SEC),
        DISPATCH_TIME_FOREVER, NSEC_PER_SEC / 4);
    dispatch_source_set_event_handler(xlBackTimer, ^{ XLPerformBackSwipe(); });
    dispatch_resume(xlBackTimer);
}

static void XLScheduleNextBackSwipe(void) {
    uint32_t delay = XLBackMinimumDelay +
        arc4random_uniform(XLBackMaximumDelay - XLBackMinimumDelay + 1);
    XLScheduleBackSwipeAfterDelay(delay);
}

static void XLSetRunning(BOOL running) {
    if (xlRunning == running) {
        XLUpdateUI();
        return;
    }

    xlRunning = running;
    xlRunGeneration++;
    if (xlRunning) {
        XLScheduleNext();
        XLScheduleNextBackSwipe();
        NSLog(@"[XingLanSwipe] started");
    } else {
        XLCancelTimer();
        XLCancelBackTimer();
        xlActionBusy = NO;
        xlLastGestureEndTime = 0.0;
        NSLog(@"[XingLanSwipe] stopped");
    }
    XLUpdateUI();
}

static void XLHandleStatusButtonTap(void) {
    if (!xlControlEnabled) return;
    XLSetActionMenuExpanded(!xlActionMenuExpanded, YES);
}

static void XLHandlePauseButtonTap(void) {
    if (!xlControlEnabled) return;
    xlUserPaused = !xlUserPaused;
    XLSetRunning(xlControlEnabled && !xlUserPaused && !xlDeviceLocked);
    XLSetActionMenuExpanded(NO, YES);
}

static void XLHandleCloseButtonTap(void) {
    if (!xlControlEnabled) return;
    xlUserPaused = NO;
    xlControlEnabled = NO;
    XLWriteRunningPreference(NO);
    XLSetRunning(NO);
    CFNotificationCenterPostNotification(
        CFNotificationCenterGetDarwinNotifyCenter(),
        CFSTR(XLControlCenterStateNotification),
        NULL, NULL, YES);
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
    window.userInteractionEnabled = YES;

    XLStatusOverlayController *controller = [XLStatusOverlayController new];
    controller.view.backgroundColor = UIColor.clearColor;
    controller.view.userInteractionEnabled = YES;
    window.rootViewController = controller;

    UIView *actionPanel = [UIView new];
    actionPanel.translatesAutoresizingMaskIntoConstraints = NO;
    actionPanel.backgroundColor = [UIColor colorWithWhite:0.24 alpha:0.91];
    actionPanel.layer.cornerRadius = 25.5;
    actionPanel.layer.shadowColor = UIColor.blackColor.CGColor;
    actionPanel.layer.shadowOpacity = 0.28;
    actionPanel.layer.shadowRadius = 4.0;
    actionPanel.layer.shadowOffset = CGSizeZero;
    actionPanel.clipsToBounds = YES;
    actionPanel.hidden = YES;
    actionPanel.alpha = 0.0;
    actionPanel.userInteractionEnabled = NO;

    UIButton *pauseButton = [UIButton buttonWithType:UIButtonTypeCustom];
    pauseButton.translatesAutoresizingMaskIntoConstraints = NO;
    [pauseButton setTitle:@"暂停" forState:UIControlStateNormal];
    [pauseButton setTitleColor:[UIColor colorWithRed:1.0 green:0.70 blue:0.72 alpha:1.0]
                      forState:UIControlStateNormal];
    pauseButton.titleLabel.font = [UIFont boldSystemFontOfSize:21.0];
    [pauseButton addTarget:controller
                    action:@selector(xlPauseTapped)
          forControlEvents:UIControlEventTouchUpInside];

    UIButton *closeButton = [UIButton buttonWithType:UIButtonTypeCustom];
    closeButton.translatesAutoresizingMaskIntoConstraints = NO;
    [closeButton setTitle:@"关闭" forState:UIControlStateNormal];
    [closeButton setTitleColor:[UIColor colorWithRed:1.0 green:0.70 blue:0.72 alpha:1.0]
                      forState:UIControlStateNormal];
    closeButton.titleLabel.font = [UIFont boldSystemFontOfSize:21.0];
    [closeButton addTarget:controller
                    action:@selector(xlCloseTapped)
          forControlEvents:UIControlEventTouchUpInside];

    UIView *separator = [UIView new];
    separator.translatesAutoresizingMaskIntoConstraints = NO;
    separator.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.22];

    [actionPanel addSubview:pauseButton];
    [actionPanel addSubview:separator];
    [actionPanel addSubview:closeButton];
    [controller.view addSubview:actionPanel];

    UIButton *status = [UIButton buttonWithType:UIButtonTypeCustom];
    status.translatesAutoresizingMaskIntoConstraints = NO;
    status.userInteractionEnabled = YES;
    status.titleLabel.font = [UIFont boldSystemFontOfSize:20.0];
    [status setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    status.backgroundColor = [UIColor colorWithWhite:0.35 alpha:0.82];
    status.layer.cornerRadius = 27.0;
    status.layer.borderWidth = 1.5;
    status.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.80].CGColor;
    status.layer.shadowColor = UIColor.blackColor.CGColor;
    status.layer.shadowOpacity = 0.35;
    status.layer.shadowRadius = 4.0;
    status.layer.shadowOffset = CGSizeZero;
    status.clipsToBounds = YES;
    [status addTarget:controller
               action:@selector(xlStatusTapped)
     forControlEvents:UIControlEventTouchUpInside];
    [controller.view addSubview:status];

    UILayoutGuide *safeArea = controller.view.safeAreaLayoutGuide;
    NSLayoutConstraint *panelWidth =
        [actionPanel.widthAnchor constraintEqualToConstant:27.0];
    [NSLayoutConstraint activateConstraints:@[
        [status.leadingAnchor constraintEqualToAnchor:safeArea.leadingAnchor constant:5.0],
        [status.centerYAnchor constraintEqualToAnchor:safeArea.centerYAnchor constant:54.0],
        [status.widthAnchor constraintEqualToConstant:54.0],
        [status.heightAnchor constraintEqualToConstant:54.0],
        [actionPanel.leadingAnchor constraintEqualToAnchor:status.centerXAnchor],
        [actionPanel.centerYAnchor constraintEqualToAnchor:status.centerYAnchor],
        panelWidth,
        [actionPanel.heightAnchor constraintEqualToConstant:51.0],
        [pauseButton.leadingAnchor constraintEqualToAnchor:actionPanel.leadingAnchor constant:27.0],
        [pauseButton.topAnchor constraintEqualToAnchor:actionPanel.topAnchor],
        [pauseButton.bottomAnchor constraintEqualToAnchor:actionPanel.bottomAnchor],
        [pauseButton.widthAnchor constraintEqualToConstant:75.0],
        [separator.leadingAnchor constraintEqualToAnchor:pauseButton.trailingAnchor],
        [separator.centerYAnchor constraintEqualToAnchor:actionPanel.centerYAnchor],
        [separator.widthAnchor constraintEqualToConstant:1.5],
        [separator.heightAnchor constraintEqualToConstant:30.0],
        [closeButton.leadingAnchor constraintEqualToAnchor:separator.trailingAnchor],
        [closeButton.topAnchor constraintEqualToAnchor:actionPanel.topAnchor],
        [closeButton.bottomAnchor constraintEqualToAnchor:actionPanel.bottomAnchor],
        [closeButton.widthAnchor constraintEqualToConstant:73.5],
    ]];
    xlStatusWindow = window;
    xlOverlayRootView = controller.view;
    xlHomeStatusButton = status;
    xlActionPanel = actionPanel;
    xlPauseButton = pauseButton;
    xlActionPanelWidthConstraint = panelWidth;
    window.hidden = NO;
    XLUpdateUI();
}

static void XLRegisterLockStateObserver(void) {
    int status = notify_register_dispatch(
        "com.apple.springboard.lockstate",
        &xlLockStateToken,
        dispatch_get_main_queue(),
        ^(int token) {
            uint64_t state = 0;
            if (notify_get_state(token, &state) != NOTIFY_STATUS_OK) return;
            xlDeviceLocked = state != 0;
            XLSetRunning(xlControlEnabled && !xlUserPaused && !xlDeviceLocked);
        });
    if (status != NOTIFY_STATUS_OK) {
        xlLockStateToken = 0;
        xlDeviceLocked = NO;
        NSLog(@"[XingLanSwipe] lock-state observer unavailable: %d", status);
        return;
    }

    uint64_t initialState = 0;
    if (notify_get_state(xlLockStateToken, &initialState) == NOTIFY_STATUS_OK) {
        xlDeviceLocked = initialState != 0;
    }
}

static void XLControlCenterStateCallback(CFNotificationCenterRef center, void *observer,
                                         CFStringRef name, const void *object,
                                         CFDictionaryRef userInfo) {
    (void)center; (void)observer; (void)name; (void)object; (void)userInfo;
    BOOL requestedRunning = XLReadRunningPreference();
    dispatch_async(dispatch_get_main_queue(), ^{
        xlUserPaused = NO;
        xlControlEnabled = requestedRunning;
        XLSetRunning(requestedRunning && !xlDeviceLocked);
    });
}

__attribute__((constructor))
static void XingLanSwipeInit(void) {
    @autoreleasepool {
        NSString *bundleIdentifier = NSBundle.mainBundle.bundleIdentifier;
        if ([bundleIdentifier isEqualToString:@"com.apple.springboard"]) {
            dispatch_async(dispatch_get_main_queue(), ^{
                xlSender = [XLHIDSender new];
                xlBackIconDetector = [XLBackIconDetector new];
                xlImageMatchQueue = dispatch_queue_create(
                    "com.jibeib.xinglanswipe.cropped-image-match",
                    DISPATCH_QUEUE_SERIAL);
                xlControlEnabled = XLReadRunningPreference();
                XLRegisterLockStateObserver();
                XLInstallStatusOverlay();
                XLSetRunning(xlControlEnabled && !xlUserPaused && !xlDeviceLocked);
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
