#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <math.h>
#import <notify.h>
#import "XLHIDSender.h"
#import "XLBackIconDetector.h"
#import "XingLanSwipeShared.h"

static const uint32_t XLMinimumDelay = 180;
static const uint32_t XLMaximumDelay = 300;
static const uint32_t XLBackMinimumDelay = 600;
static const uint32_t XLBackMaximumDelay = 900;
static const uint32_t XLConflictRetryDelay = 5;
static const CFTimeInterval XLGestureCooldown = 5.0;
static const NSUInteger XLBackRecognitionAttempts = 3;
static const NSTimeInterval XLBackRecognitionInterval = 1.0;
static const double XLBackChevronThreshold = 0.65;

static dispatch_source_t xlTimer;
static dispatch_source_t xlBackTimer;
static XLHIDSender *xlSender;
static XLBackIconDetector *xlBackIconDetector;
static dispatch_queue_t xlImageMatchQueue;
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
static void XLPerformBackRecognitionAttempt(NSUInteger generation,
                                            BOOL quickVerification,
                                            NSUInteger attempt,
                                            NSArray<NSValue *> *detectedCenters,
                                            double bestScore);

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

static CGPoint XLStableCenter(NSArray<NSValue *> *centers) {
    if (centers.count == 0) return CGPointZero;
    if (centers.count == 1) return centers.firstObject.CGPointValue;
    if (centers.count == 2) {
        CGPoint first = centers[0].CGPointValue;
        CGPoint second = centers[1].CGPointValue;
        return CGPointMake((first.x + second.x) * 0.5,
                           (first.y + second.y) * 0.5);
    }
    NSMutableArray<NSNumber *> *xs = [NSMutableArray arrayWithCapacity:centers.count];
    NSMutableArray<NSNumber *> *ys = [NSMutableArray arrayWithCapacity:centers.count];
    for (NSValue *value in centers) {
        CGPoint point = value.CGPointValue;
        [xs addObject:@(point.x)];
        [ys addObject:@(point.y)];
    }
    [xs sortUsingSelector:@selector(compare:)];
    [ys sortUsingSelector:@selector(compare:)];
    NSUInteger middle = centers.count / 2;
    return CGPointMake(xs[middle].doubleValue, ys[middle].doubleValue);
}

static NSInteger XLRandomSignedOffset(NSUInteger radius) {
    return (NSInteger)arc4random_uniform((uint32_t)(radius * 2 + 1)) -
        (NSInteger)radius;
}

static void XLDispatchBackTap(CGPoint detectedCenter, BOOL quickVerification) {
    NSUInteger generation = xlRunGeneration;
    if (!xlSender) xlSender = [XLHIDSender new];
    CGSize screenSize = UIScreen.mainScreen.bounds.size;
    if (screenSize.width <= 0.0 || screenSize.height <= 0.0 ||
        detectedCenter.x < 0.03 || detectedCenter.x > 0.12 ||
        detectedCenter.y < 0.90 || detectedCenter.y > 0.99) {
        xlActionBusy = NO;
        NSLog(@"[XingLanSwipe] detected chevron center outside safe region: %.4fx%.4f",
              detectedCenter.x, detectedCenter.y);
        if (quickVerification) XLShowStatusText(@"点错", 3.0);
        if (xlRunning) XLScheduleNextBackSwipe();
        return;
    }

    CGPoint tapPoint = CGPointZero;
    BOOL validTapPoint = NO;
    for (NSUInteger attempt = 0; attempt < 16; attempt++) {
        double x = detectedCenter.x + XLRandomSignedOffset(8) / screenSize.width;
        double y = detectedCenter.y + XLRandomSignedOffset(6) / screenSize.height;
        if (x >= 0.02 && x <= 0.14 && y >= 0.90 && y <= 0.99) {
            tapPoint = CGPointMake(x, y);
            validTapPoint = YES;
            break;
        }
    }
    if (!validTapPoint) {
        xlActionBusy = NO;
        NSLog(@"[XingLanSwipe] could not generate safe randomized tap point");
        if (quickVerification) XLShowStatusText(@"点错", 3.0);
        if (xlRunning) XLScheduleNextBackSwipe();
        return;
    }

    NSLog(@"[XingLanSwipe] tapping detected chevron center=%.4fx%.4f final=%.4fx%.4f",
          detectedCenter.x, detectedCenter.y, tapPoint.x, tapPoint.y);
    [xlSender performTapAtNormalizedX:tapPoint.x y:tapPoint.y completion:^(BOOL success) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (generation != xlRunGeneration) return;
            xlActionBusy = NO;
            xlLastGestureEndTime = CFAbsoluteTimeGetCurrent();
            NSLog(@"[XingLanSwipe] back-chevron tap %@", success ? @"success" : @"failed");
            if (quickVerification && xlRunning) {
                XLShowStatusText(success ? @"点✓" : @"点×", 2.0);
            }
            if (xlRunning) XLScheduleNextBackSwipe();
        });
    }];
}

static void XLPerformBackRecognitionAttempt(NSUInteger generation,
                                            BOOL quickVerification,
                                            NSUInteger attempt,
                                            NSArray<NSValue *> *detectedCenters,
                                            double bestScore) {
    if (!xlRunning || generation != xlRunGeneration) return;
    NSError *captureError = nil;
    UIImage *screenshot = [xlBackIconDetector captureScreenWithError:&captureError];
    if (!screenshot) {
        xlActionBusy = NO;
        NSLog(@"[XingLanSwipe] back recognition attempt %lu capture failed; swipe cancelled: %@",
              (unsigned long)(attempt + 1),
              captureError.localizedDescription ?: @"screenshot unavailable");
        if (quickVerification) XLShowStatusText(@"图错", 3.0);
        XLScheduleNextBackSwipe();
        return;
    }

    dispatch_async(xlImageMatchQueue, ^{
        @autoreleasepool {
            NSError *matchError = nil;
            CGPoint matchedCenter = CGPointZero;
            double matchScore = [xlBackIconDetector matchScoreForScreenshot:screenshot
                                                           normalizedCenter:&matchedCenter
                                                                       error:&matchError];
            BOOL chevronFound = !matchError && matchScore >= XLBackChevronThreshold;
            NSInteger matchPercent = MAX(0, MIN(99,
                (NSInteger)lround(matchScore * 100.0)));
            dispatch_async(dispatch_get_main_queue(), ^{
                if (!xlRunning || generation != xlRunGeneration) return;
                if (matchError) {
                    xlActionBusy = NO;
                    NSLog(@"[XingLanSwipe] back recognition attempt %lu failed; swipe cancelled: %@",
                          (unsigned long)(attempt + 1),
                          matchError.localizedDescription);
                    if (quickVerification) XLShowStatusText(@"模错", 3.0);
                    XLScheduleNextBackSwipe();
                    return;
                }
                double nextBestScore = MAX(bestScore, matchScore);
                NSMutableArray<NSValue *> *nextCenters =
                    [detectedCenters mutableCopy] ?: [NSMutableArray array];
                if (chevronFound) {
                    [nextCenters addObject:[NSValue valueWithCGPoint:matchedCenter]];
                }
                NSUInteger nextDetectedCount = nextCenters.count;
                NSUInteger nextAttempt = attempt + 1;
                NSLog(@"[XingLanSwipe] back chevron %@ on attempt %lu/%lu score=%.4f detected=%lu",
                      chevronFound ? @"present" : @"absent",
                      (unsigned long)nextAttempt,
                      (unsigned long)XLBackRecognitionAttempts,
                      matchScore,
                      (unsigned long)nextDetectedCount);
                if (nextAttempt < XLBackRecognitionAttempts) {
                    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                                 (int64_t)(XLBackRecognitionInterval * NSEC_PER_SEC)),
                                   dispatch_get_main_queue(), ^{
                        XLPerformBackRecognitionAttempt(generation,
                                                        quickVerification,
                                                        nextAttempt,
                                                        [nextCenters copy],
                                                        nextBestScore);
                    });
                    return;
                }

                BOOL shouldReturn = nextDetectedCount >= 2;
                NSLog(@"[XingLanSwipe] back chevron final detected=%lu/%lu best=%.4f; %@",
                      (unsigned long)nextDetectedCount,
                      (unsigned long)XLBackRecognitionAttempts,
                      nextBestScore,
                      shouldReturn ? @"returning" : @"swipe cancelled");
                if (!shouldReturn) {
                    xlActionBusy = NO;
                    if (quickVerification) {
                        XLShowStatusText([NSString stringWithFormat:@"无%ld",
                                          (long)matchPercent], 3.0);
                    }
                    XLScheduleNextBackSwipe();
                    return;
                }
                CGPoint stableCenter = XLStableCenter(nextCenters);
                if (quickVerification) {
                    XLShowStatusText([NSString stringWithFormat:@"点%lu",
                                      (unsigned long)nextDetectedCount], 0.8);
                    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                                 (int64_t)(0.8 * NSEC_PER_SEC)),
                                   dispatch_get_main_queue(), ^{
                        if (xlRunning && generation == xlRunGeneration) {
                            XLDispatchBackTap(stableCenter, YES);
                        }
                    });
                } else {
                    XLDispatchBackTap(stableCenter, NO);
                }
            });
        }
    });
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
    if (!xlBackIconDetector) xlBackIconDetector = [XLBackIconDetector new];
    XLPerformBackRecognitionAttempt(xlRunGeneration, quickVerification, 0, @[], 0.0);
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
        XLScheduleNextBackSwipe();
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
