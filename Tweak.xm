#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <notify.h>
#import "XLHIDSender.h"
#import "XLBackIconDetector.h"
#import "XingLanSwipeShared.h"

static const uint32_t XLMinimumDelay = 180;
static const uint32_t XLMaximumDelay = 300;
static const uint32_t XLBackMinimumDelay = 300;
static const uint32_t XLBackMaximumDelay = 600;
static const uint32_t XLInitialBackVerificationDelay = 10;

static dispatch_source_t xlTimer;
static dispatch_source_t xlBackTimer;
static XLHIDSender *xlSender;
static XLBackIconDetector *xlBackIconDetector;
static dispatch_queue_t xlImageMatchQueue;
static BOOL xlRunning = NO;
static NSUInteger xlRunGeneration = 0;
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

static void XLPerformBackSwipe(BOOL quickVerification) {
    XLCancelBackTimer();
    if (!xlRunning) return;
    if (!xlBackIconDetector) xlBackIconDetector = [XLBackIconDetector new];

    NSError *captureError = nil;
    UIImage *screenshot = [xlBackIconDetector captureScreenWithError:&captureError];
    if (!screenshot) {
        NSLog(@"[XingLanSwipe] screen check skipped: %@",
              captureError.localizedDescription ?: @"screenshot unavailable");
        if (quickVerification) XLShowStatusText(@"图错", 3.0);
        XLScheduleNextBackSwipe();
        return;
    }

    NSUInteger generation = xlRunGeneration;
    dispatch_async(xlImageMatchQueue, ^{
        @autoreleasepool {
            NSError *matchError = nil;
            double score = [xlBackIconDetector matchScoreForScreenshot:screenshot
                                                                  error:&matchError];
            dispatch_async(dispatch_get_main_queue(), ^{
                if (!xlRunning || generation != xlRunGeneration) return;
                if (matchError) {
                    NSLog(@"[XingLanSwipe] screen template match failed: %@",
                          matchError.localizedDescription);
                    if (quickVerification) XLShowStatusText(@"模错", 3.0);
                    XLScheduleNextBackSwipe();
                    return;
                }
                if (score < 0.68) {
                    NSLog(@"[XingLanSwipe] profile template absent (score %.4f); skipped", score);
                    if (quickVerification) XLShowStatusText(@"无我", 3.0);
                    XLScheduleNextBackSwipe();
                    return;
                }
                NSLog(@"[XingLanSwipe] profile template matched (score %.4f); returning", score);
                XLDispatchBackSwipe(quickVerification);
            });
        }
    });
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

__attribute__((constructor))
static void XingLanSwipeInit(void) {
    @autoreleasepool {
        NSString *bundleIdentifier = NSBundle.mainBundle.bundleIdentifier;
        if (![bundleIdentifier isEqualToString:@"com.apple.springboard"]) return;
        dispatch_async(dispatch_get_main_queue(), ^{
            xlSender = [XLHIDSender new];
            xlBackIconDetector = [XLBackIconDetector new];
            xlImageMatchQueue = dispatch_queue_create(
                "com.jibeib.xinglanswipe.image-match", DISPATCH_QUEUE_SERIAL);
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
