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

// Novel (right-to-left page turn) mode. The gesture is synthesized in
// XLHIDSender; the cadence is user editable from the floating panel and stored
// as "MIN-MAX" (or a single number for a fixed interval).
static const uint32_t XLNovelIntervalMinimumSeconds = 1;
static const uint32_t XLNovelIntervalMaximumSeconds = 3600;
static const uint32_t XLNovelIntervalFallbackMinimum = 10;
static const uint32_t XLNovelIntervalFallbackMaximum = 15;

// Floating panel geometry, in points, tuned for the SE2 portrait screen.
static const CGFloat XLStatusButtonSize = 54.0;
static const CGFloat XLStatusButtonLeading = 5.0;
static const CGFloat XLStatusButtonCenterOffset = 54.0;
static const CGFloat XLPanelWidth = 180.0;
static const CGFloat XLPanelRowHeight = 44.0;
static const CGFloat XLPanelHeight = 132.0;
static const CGFloat XLPanelCornerRadius = 22.0;
static const CGFloat XLPanelOverlap = 27.0;
static const CGFloat XLPanelDividerWidth = 1.5;

typedef NS_ENUM(NSInteger, XLMode) {
    XLModeSwipe = XLModeSwipeValue,
    XLModePageTurn = XLModePageTurnValue
};

static dispatch_source_t xlTimer;
static dispatch_source_t xlBackTimer;
static dispatch_source_t xlPageTurnTimer;
static XLMode xlMode = XLModeSwipe;
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
static UIButton *xlModeSwipeButton;
static UIButton *xlModeNovelButton;
static UIButton *xlIntervalButton;
static UILabel *xlIntervalValueLabel;
static UIWindow *xlIntervalEditorWindow;
static NSLayoutConstraint *xlActionPanelWidthConstraint;
static BOOL xlActionMenuExpanded = NO;

static void XLSetRunning(BOOL running);
static void XLSetActionMenuExpanded(BOOL expanded, BOOL animated);
static void XLHandleStatusButtonTap(void);
static void XLHandlePauseButtonTap(void);
static void XLHandleCloseButtonTap(void);
static void XLHandleModeSwipeTap(void);
static void XLHandleModeNovelTap(void);
static void XLHandleIntervalTap(void);
static NSString *XLNovelIntervalText(void);
static BOOL XLParseNovelInterval(NSString *text, uint32_t *minimum, uint32_t *maximum);
static BOOL XLApplyNovelInterval(NSString *text);
static void XLPresentIntervalAlert(UIWindow *host, NSString *initialText);
static void XLTearDownIntervalEditorWindow(void);

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

- (void)xlModeSwipeTapped {
    XLHandleModeSwipeTap();
}

- (void)xlModeNovelTapped {
    XLHandleModeNovelTap();
}

- (void)xlIntervalTapped {
    XLHandleIntervalTap();
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

        // Both modes always render in full white; only the highlight block
        // marks which one is active.
        UIColor *modeHighlight = [UIColor colorWithWhite:1.0 alpha:0.22];
        if (xlModeSwipeButton && xlModeNovelButton) {
            BOOL swipeActive = (xlMode == XLModeSwipe);
            [xlModeSwipeButton setTitleColor:UIColor.whiteColor
                                    forState:UIControlStateNormal];
            [xlModeNovelButton setTitleColor:UIColor.whiteColor
                                    forState:UIControlStateNormal];
            xlModeSwipeButton.backgroundColor =
                swipeActive ? modeHighlight : UIColor.clearColor;
            xlModeNovelButton.backgroundColor =
                swipeActive ? UIColor.clearColor : modeHighlight;
        }
        if (xlIntervalValueLabel) {
            xlIntervalValueLabel.text = XLNovelIntervalText();
        }
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
static void XLCancelPageTurnTimer(void);
static void XLSchedulePageTurnAfterDelay(uint32_t delay);
static void XLScheduleNextPageTurn(void);
static void XLPerformPageTurnSwipe(void);

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

static void XLCancelPageTurnTimer(void) {
    if (xlPageTurnTimer) {
        dispatch_source_cancel(xlPageTurnTimer);
        xlPageTurnTimer = nil;
    }
}

static void XLSchedulePageTurnAfterDelay(uint32_t delay) {
    XLCancelPageTurnTimer();
    if (!xlRunning || xlMode != XLModePageTurn) return;
    NSLog(@"[XingLanSwipe] next page turn in %u seconds", delay);
    xlPageTurnTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0,
        dispatch_get_main_queue());
    dispatch_source_set_timer(xlPageTurnTimer,
        dispatch_time(DISPATCH_TIME_NOW, (int64_t)delay * NSEC_PER_SEC),
        DISPATCH_TIME_FOREVER, NSEC_PER_SEC / 4);
    dispatch_source_set_event_handler(xlPageTurnTimer, ^{ XLPerformPageTurnSwipe(); });
    dispatch_resume(xlPageTurnTimer);
}

static void XLScheduleNextPageTurn(void) {
    uint32_t minimum = XLNovelIntervalFallbackMinimum;
    uint32_t maximum = XLNovelIntervalFallbackMaximum;
    if (!XLParseNovelInterval(XLNovelIntervalText(), &minimum, &maximum)) {
        minimum = XLNovelIntervalFallbackMinimum;
        maximum = XLNovelIntervalFallbackMaximum;
    }
    uint32_t delay = minimum + arc4random_uniform(maximum - minimum + 1);
    XLSchedulePageTurnAfterDelay(delay);
}

static void XLPerformPageTurnSwipe(void) {
    XLCancelPageTurnTimer();
    if (!xlRunning || xlMode != XLModePageTurn) return;
    if (xlActionBusy || XLGestureCooldownIsActive()) {
        NSLog(@"[XingLanSwipe] page turn deferred to avoid action conflict");
        XLSchedulePageTurnAfterDelay(XLConflictRetryDelay);
        return;
    }
    xlActionBusy = YES;
    NSUInteger generation = xlRunGeneration;

    if (!xlSender) xlSender = [XLHIDSender new];
    NSLog(@"[XingLanSwipe] page turn swipe");
    [xlSender performNaturalBackwardSwipeWithCompletion:^(BOOL success) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (generation != xlRunGeneration) return;
            xlActionBusy = NO;
            if (success) {
                xlLastGestureEndTime = CFAbsoluteTimeGetCurrent();
            } else {
                // Keep the status fixed on "开" for successful swipes; only a
                // failure is surfaced so a broken HID path stays visible.
                XLShowStatusText(@"滑×", 2.0);
            }
            NSLog(@"[XingLanSwipe] page turn %@", success ? @"success" : @"failed");
            if (xlRunning) XLScheduleNextPageTurn();
        });
    }];
}

static XLMode XLReadModePreference(void) {
    CFPreferencesAppSynchronize(CFSTR(XLPreferenceDomain));
    CFPropertyListRef value = CFPreferencesCopyAppValue(
        CFSTR(XLModePreferenceKey), CFSTR(XLPreferenceDomain));
    XLMode mode = XLModeSwipe;
    if (value) {
        if (CFGetTypeID(value) == CFNumberGetTypeID()) {
            CFIndex number = 0;
            if (CFNumberGetValue((CFNumberRef)value, kCFNumberCFIndexType, &number) &&
                number == XLModePageTurn) {
                mode = XLModePageTurn;
            }
        }
        CFRelease(value);
    }
    return mode;
}

static void XLWriteModePreference(XLMode mode) {
    CFIndex number = (CFIndex)mode;
    CFNumberRef value = CFNumberCreate(kCFAllocatorDefault,
                                       kCFNumberCFIndexType, &number);
    CFPreferencesSetAppValue(CFSTR(XLModePreferenceKey), value,
                             CFSTR(XLPreferenceDomain));
    CFPreferencesAppSynchronize(CFSTR(XLPreferenceDomain));
    if (value) CFRelease(value);
}

// The novel interval is stored as text so the panel can round trip exactly what
// the user typed: "MIN-MAX" for a random range, or a single number for a fixed
// delay. Anything unparsable falls back to the shipped default.
static NSString *XLNovelIntervalText(void) {
    CFPreferencesAppSynchronize(CFSTR(XLPreferenceDomain));
    CFPropertyListRef value = CFPreferencesCopyAppValue(
        CFSTR(XLNovelIntervalPreferenceKey), CFSTR(XLPreferenceDomain));
    NSString *text = nil;
    if (value) {
        if (CFGetTypeID(value) == CFStringGetTypeID()) {
            text = [(__bridge NSString *)value copy];
        }
        CFRelease(value);
    }
    if (text.length == 0 ||
        ![XLParseNovelInterval(text, NULL, NULL)]) {
        text = @XLNovelIntervalDefault;
    }
    return text;
}

static BOOL XLParseNovelInterval(NSString *text, uint32_t *minimum, uint32_t *maximum) {
    if (text.length == 0) return NO;
    NSCharacterSet *trimmed = [NSCharacterSet whitespaceAndNewlineCharacterSet];
    NSString *normalized = [[text stringByTrimmingCharactersInSet:trimmed]
        stringByReplacingOccurrencesOfString:@"\u2013" withString:@"-"];
    normalized = [normalized stringByReplacingOccurrencesOfString:@"\u2014"
                                                       withString:@"-"];
    normalized = [normalized stringByReplacingOccurrencesOfString:@" "
                                                       withString:@""];
    if (normalized.length == 0) return NO;

    NSArray<NSString *> *parts = [normalized componentsSeparatedByString:@"-"];
    if (parts.count == 0 || parts.count > 2) return NO;

    NSCharacterSet *digits = NSCharacterSet.decimalDigitCharacterSet;
    NSCharacterSet *nonDigits = digits.invertedCharacterSet;
    uint32_t lower = 0, upper = 0;
    for (NSUInteger index = 0; index < parts.count; index++) {
        NSString *part = parts[index];
        if (part.length == 0 || [part rangeOfCharacterFromSet:nonDigits].location
                                   != NSNotFound) {
            return NO;
        }
        long long parsed = part.longLongValue;
        if (parsed < (long long)XLNovelIntervalMinimumSeconds ||
            parsed > (long long)XLNovelIntervalMaximumSeconds) {
            return NO;
        }
        if (index == 0) lower = (uint32_t)parsed; else upper = (uint32_t)parsed;
    }
    if (parts.count == 1) upper = lower;
    if (upper < lower) return NO;

    if (minimum) *minimum = lower;
    if (maximum) *maximum = upper;
    return YES;
}

static void XLWriteNovelInterval(NSString *text) {
    CFStringRef value = (__bridge CFStringRef)text;
    CFPreferencesSetAppValue(CFSTR(XLNovelIntervalPreferenceKey), value,
                             CFSTR(XLPreferenceDomain));
    CFPreferencesAppSynchronize(CFSTR(XLPreferenceDomain));
}

// Applies a new interval typed by the user. Rejects anything unparsable.
static BOOL XLApplyNovelInterval(NSString *text) {
    if (!XLParseNovelInterval(text, NULL, NULL)) return NO;
    XLWriteNovelInterval(text);
    NSLog(@"[XingLanSwipe] novel interval set to %@", text);
    XLUpdateUI();
    if (xlRunning && xlMode == XLModePageTurn) {
        // Restart the countdown so the new value takes effect immediately.
        XLScheduleNextPageTurn();
    }
    return YES;
}

static void XLSetMode(XLMode mode) {
    if (!xlControlEnabled) return;
    if (xlMode == mode) {
        XLUpdateUI();
        return;
    }
    xlMode = mode;
    XLWriteModePreference(mode);
    NSLog(@"[XingLanSwipe] mode set to %@",
          mode == XLModePageTurn ? @"page-turn" : @"swipe");
    // Up-swipe and page turn never run together: drop the old mode's timers and
    // reschedule from scratch for the new one.
    if (xlRunning) {
        XLSetRunning(NO);
        XLSetRunning(YES);
    }
    XLUpdateUI();
}

static void XLSetRunning(BOOL running) {
    if (xlRunning == running) {
        XLUpdateUI();
        return;
    }

    xlRunning = running;
    xlRunGeneration++;
    if (xlRunning) {
        if (xlMode == XLModePageTurn) {
            XLScheduleNextPageTurn();
        } else {
            XLScheduleNext();
            XLScheduleNextBackSwipe();
        }
        NSLog(@"[XingLanSwipe] started in %@ mode",
              xlMode == XLModePageTurn ? @"page-turn" : @"swipe");
    } else {
        XLCancelTimer();
        XLCancelBackTimer();
        XLCancelPageTurnTimer();
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

static void XLHandleModeSwipeTap(void) {
    XLSetMode(XLModeSwipe);
}

static void XLHandleModeNovelTap(void) {
    XLSetMode(XLModePageTurn);
}

// Method A: a standard system alert owns the keyboard, so this tweak only
// needs key window state for the lifetime of the alert.
static void XLTearDownIntervalEditorWindow(void) {
    if (!xlIntervalEditorWindow) return;
    xlIntervalEditorWindow.hidden = YES;
    xlIntervalEditorWindow = nil;
}

static void XLPresentIntervalAlert(UIWindow *host, NSString *initialText) {
    UIViewController *root = host.rootViewController;
    if (!root) return;

    UIAlertController *alert = [UIAlertController
        alertControllerWithTitle:@"小说间隔"
                         message:@"范围写 10-15（随机），固定值写一个数字，单位秒"
                  preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *field) {
        field.text = initialText;
        field.placeholder = @XLNovelIntervalDefault;
        field.keyboardType = UIKeyboardTypeNumbersAndPunctuation;
        field.clearButtonMode = UITextFieldViewModeWhileEditing;
        field.textAlignment = NSTextAlignmentCenter;
    }];
    [alert addAction:[UIAlertAction actionWithTitle:@"取消"
                                              style:UIAlertActionStyleCancel
                                            handler:^(UIAlertAction *action) {
        (void)action;
        XLTearDownIntervalEditorWindow();
    }]];
    // Weak so the action handler does not retain the alert (and its text field)
    // through the action it belongs to.
    __weak UIAlertController *weakAlert = alert;
    [alert addAction:[UIAlertAction actionWithTitle:@"确定"
                                              style:UIAlertActionStyleDefault
                                            handler:^(UIAlertAction *action) {
        (void)action;
        NSString *typed = weakAlert.textFields.firstObject.text;
        if ([XLApplyNovelInterval(typed)]) {
            XLTearDownIntervalEditorWindow();
            return;
        }
        // Bad input: explain and reopen on the same host with the text kept.
        NSLog(@"[XingLanSwipe] novel interval rejected: %@", typed);
        UIAlertController *retry = [UIAlertController
            alertControllerWithTitle:@"格式不对"
                             message:[NSString stringWithFormat:
                                 @"范围写成 10-15，固定值写一个数字（%u-%u 秒）。",
                                 XLNovelIntervalMinimumSeconds,
                                 XLNovelIntervalMaximumSeconds]
                      preferredStyle:UIAlertControllerStyleAlert];
        [retry addAction:[UIAlertAction actionWithTitle:@"重填"
                                                  style:UIAlertActionStyleDefault
                                                handler:^(UIAlertAction *inner) {
            (void)inner;
            XLPresentIntervalAlert(host, typed);
        }]];
        // Wait for the dismissal animation before presenting again.
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                     (int64_t)(0.35 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            [root presentViewController:retry animated:YES completion:nil];
        });
    }]];
    [root presentViewController:alert animated:YES completion:nil];
}

static void XLHandleIntervalTap(void) {
    if (!xlControlEnabled) return;

    UIWindowScene *activeScene = nil;
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if ([scene isKindOfClass:UIWindowScene.class] &&
            scene.activationState != UISceneActivationStateUnattached) {
            activeScene = (UIWindowScene *)scene;
            break;
        }
    }

    XLTearDownIntervalEditorWindow();
    UIWindow *host;
    if (@available(iOS 13.0, *)) {
        host = activeScene ? [[UIWindow alloc] initWithWindowScene:activeScene]
                           : [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
    } else {
        host = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
    }
    host.windowLevel = UIWindowLevelAlert + 2000.0;
    host.rootViewController = [UIViewController new];
    xlIntervalEditorWindow = host;
    [host makeKeyAndVisible];

    XLPresentIntervalAlert(host, XLNovelIntervalText());
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
    actionPanel.layer.cornerRadius = XLPanelCornerRadius;
    actionPanel.layer.shadowColor = UIColor.blackColor.CGColor;
    actionPanel.layer.shadowOpacity = 0.28;
    actionPanel.layer.shadowRadius = 4.0;
    actionPanel.layer.shadowOffset = CGSizeZero;
    actionPanel.clipsToBounds = YES;
    actionPanel.hidden = YES;
    actionPanel.alpha = 0.0;
    actionPanel.userInteractionEnabled = NO;

    UIColor *actionColor =
        [UIColor colorWithRed:1.0 green:0.70 blue:0.72 alpha:1.0];
    UIColor *dividerColor = [UIColor colorWithWhite:1.0 alpha:0.22];

    // Row 1: mode selection. Both titles stay full white; the highlight block
    // alone marks the active mode.
    UIButton *modeSwipeButton = [UIButton buttonWithType:UIButtonTypeCustom];
    modeSwipeButton.translatesAutoresizingMaskIntoConstraints = NO;
    [modeSwipeButton setTitle:@"视频" forState:UIControlStateNormal];
    [modeSwipeButton setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    modeSwipeButton.titleLabel.font = [UIFont boldSystemFontOfSize:18.0];
    [modeSwipeButton addTarget:controller
                        action:@selector(xlModeSwipeTapped)
              forControlEvents:UIControlEventTouchUpInside];

    UIButton *modeNovelButton = [UIButton buttonWithType:UIButtonTypeCustom];
    modeNovelButton.translatesAutoresizingMaskIntoConstraints = NO;
    [modeNovelButton setTitle:@"小说" forState:UIControlStateNormal];
    [modeNovelButton setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    modeNovelButton.titleLabel.font = [UIFont boldSystemFontOfSize:18.0];
    [modeNovelButton addTarget:controller
                        action:@selector(xlModeNovelTapped)
              forControlEvents:UIControlEventTouchUpInside];

    // Row 2: novel interval. The whole row is one tap target that opens a
    // system alert so the keyboard is owned by the system, not by this tweak.
    UIButton *intervalButton = [UIButton buttonWithType:UIButtonTypeCustom];
    intervalButton.translatesAutoresizingMaskIntoConstraints = NO;
    [intervalButton addTarget:controller
                       action:@selector(xlIntervalTapped)
             forControlEvents:UIControlEventTouchUpInside];

    UILabel *intervalCaption = [UILabel new];
    intervalCaption.translatesAutoresizingMaskIntoConstraints = NO;
    intervalCaption.text = @"间隔";
    intervalCaption.font = [UIFont systemFontOfSize:13.0];
    intervalCaption.textColor = [UIColor colorWithWhite:1.0 alpha:0.78];
    intervalCaption.userInteractionEnabled = NO;

    UILabel *intervalValue = [UILabel new];
    intervalValue.translatesAutoresizingMaskIntoConstraints = NO;
    intervalValue.text = @XLNovelIntervalDefault;
    intervalValue.font = [UIFont boldSystemFontOfSize:15.0];
    intervalValue.textColor = UIColor.whiteColor;
    intervalValue.textAlignment = NSTextAlignmentCenter;
    intervalValue.backgroundColor = [UIColor colorWithWhite:0.16 alpha:0.85];
    intervalValue.layer.cornerRadius = 9.0;
    intervalValue.layer.borderWidth = 1.0;
    intervalValue.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.34].CGColor;
    intervalValue.clipsToBounds = YES;
    intervalValue.userInteractionEnabled = NO;

    [intervalButton addSubview:intervalCaption];
    [intervalButton addSubview:intervalValue];

    // Row 3: pause / close.
    UIButton *pauseButton = [UIButton buttonWithType:UIButtonTypeCustom];
    pauseButton.translatesAutoresizingMaskIntoConstraints = NO;
    [pauseButton setTitle:@"暂停" forState:UIControlStateNormal];
    [pauseButton setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    pauseButton.titleLabel.font = [UIFont boldSystemFontOfSize:18.0];
    [pauseButton addTarget:controller
                    action:@selector(xlPauseTapped)
          forControlEvents:UIControlEventTouchUpInside];

    UIButton *closeButton = [UIButton buttonWithType:UIButtonTypeCustom];
    closeButton.translatesAutoresizingMaskIntoConstraints = NO;
    [closeButton setTitle:@"关闭" forState:UIControlStateNormal];
    [closeButton setTitleColor:actionColor forState:UIControlStateNormal];
    closeButton.titleLabel.font = [UIFont boldSystemFontOfSize:18.0];
    [closeButton addTarget:controller
                    action:@selector(xlCloseTapped)
          forControlEvents:UIControlEventTouchUpInside];

    // Row separators and the vertical splits inside rows 1 and 3.
    UIView *dividerRow1 = [UIView new];
    dividerRow1.translatesAutoresizingMaskIntoConstraints = NO;
    dividerRow1.backgroundColor = dividerColor;
    UIView *dividerRow2 = [UIView new];
    dividerRow2.translatesAutoresizingMaskIntoConstraints = NO;
    dividerRow2.backgroundColor = dividerColor;
    UIView *splitMode = [UIView new];
    splitMode.translatesAutoresizingMaskIntoConstraints = NO;
    splitMode.backgroundColor = dividerColor;
    UIView *splitAction = [UIView new];
    splitAction.translatesAutoresizingMaskIntoConstraints = NO;
    splitAction.backgroundColor = dividerColor;

    [actionPanel addSubview:modeSwipeButton];
    [actionPanel addSubview:modeNovelButton];
    [actionPanel addSubview:splitMode];
    [actionPanel addSubview:intervalButton];
    [actionPanel addSubview:dividerRow2];
    [actionPanel addSubview:pauseButton];
    [actionPanel addSubview:closeButton];
    [actionPanel addSubview:splitAction];
    [actionPanel addSubview:dividerRow1];
    [controller.view addSubview:actionPanel];

    UIButton *status = [UIButton buttonWithType:UIButtonTypeCustom];
    status.translatesAutoresizingMaskIntoConstraints = NO;
    status.userInteractionEnabled = YES;
    status.titleLabel.font = [UIFont boldSystemFontOfSize:20.0];
    [status setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    status.backgroundColor = [UIColor colorWithWhite:0.35 alpha:0.82];
    status.layer.cornerRadius = XLStatusButtonSize / 2.0;
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
        [actionPanel.widthAnchor constraintEqualToConstant:XLPanelOverlap];
    CGFloat halfCell = (XLPanelWidth - XLPanelDividerWidth) / 2.0;
    [NSLayoutConstraint activateConstraints:@[
        [status.leadingAnchor constraintEqualToAnchor:safeArea.leadingAnchor
                                             constant:XLStatusButtonLeading],
        [status.centerYAnchor constraintEqualToAnchor:safeArea.centerYAnchor
                                             constant:XLStatusButtonCenterOffset],
        [status.widthAnchor constraintEqualToConstant:XLStatusButtonSize],
        [status.heightAnchor constraintEqualToConstant:XLStatusButtonSize],
        [actionPanel.leadingAnchor constraintEqualToAnchor:status.centerXAnchor],
        [actionPanel.centerYAnchor constraintEqualToAnchor:status.centerYAnchor],
        panelWidth,
        [actionPanel.heightAnchor constraintEqualToConstant:XLPanelHeight],

        // Rows are pinned to fixed offsets from the panel top so the three
        // 44pt rows plus the two 1pt dividers total exactly XLPanelHeight.
        // Each divider straddles a row boundary rather than consuming space.
        // Row 1: video / novel.
        [modeSwipeButton.leadingAnchor constraintEqualToAnchor:actionPanel.leadingAnchor
                                                     constant:XLPanelOverlap],
        [modeSwipeButton.topAnchor constraintEqualToAnchor:actionPanel.topAnchor],
        [modeSwipeButton.widthAnchor constraintEqualToConstant:halfCell],
        [modeSwipeButton.heightAnchor constraintEqualToConstant:XLPanelRowHeight],
        [splitMode.leadingAnchor constraintEqualToAnchor:modeSwipeButton.trailingAnchor],
        [splitMode.topAnchor constraintEqualToAnchor:actionPanel.topAnchor
                                             constant:9.0],
        [splitMode.widthAnchor constraintEqualToConstant:XLPanelDividerWidth],
        [splitMode.heightAnchor constraintEqualToConstant:XLPanelRowHeight - 18.0],
        [modeNovelButton.leadingAnchor constraintEqualToAnchor:splitMode.trailingAnchor],
        [modeNovelButton.topAnchor constraintEqualToAnchor:actionPanel.topAnchor],
        [modeNovelButton.widthAnchor constraintEqualToConstant:halfCell],
        [modeNovelButton.heightAnchor constraintEqualToConstant:XLPanelRowHeight],
        [dividerRow1.leadingAnchor constraintEqualToAnchor:actionPanel.leadingAnchor
                                                  constant:XLPanelOverlap],
        [dividerRow1.topAnchor constraintEqualToAnchor:actionPanel.topAnchor
                                              constant:XLPanelRowHeight - 0.5],
        [dividerRow1.widthAnchor constraintEqualToConstant:XLPanelWidth - XLPanelOverlap],
        [dividerRow1.heightAnchor constraintEqualToConstant:1.0],

        // Row 2: novel interval, one full width tap target.
        [intervalButton.leadingAnchor constraintEqualToAnchor:actionPanel.leadingAnchor
                                                     constant:XLPanelOverlap],
        [intervalButton.topAnchor constraintEqualToAnchor:actionPanel.topAnchor
                                                 constant:XLPanelRowHeight],
        [intervalButton.widthAnchor constraintEqualToConstant:XLPanelWidth - XLPanelOverlap],
        [intervalButton.heightAnchor constraintEqualToConstant:XLPanelRowHeight],
        [intervalCaption.leadingAnchor constraintEqualToAnchor:intervalButton.leadingAnchor
                                                      constant:10.0],
        [intervalCaption.centerYAnchor constraintEqualToAnchor:intervalButton.centerYAnchor],
        [intervalValue.leadingAnchor constraintEqualToAnchor:intervalButton.leadingAnchor
                                                    constant:44.0],
        [intervalValue.centerYAnchor constraintEqualToAnchor:intervalButton.centerYAnchor],
        [intervalValue.widthAnchor constraintEqualToConstant:72.0],
        [intervalValue.heightAnchor constraintEqualToConstant:XLPanelRowHeight - 18.0],

        // Row 3: pause / close.
        [pauseButton.leadingAnchor constraintEqualToAnchor:actionPanel.leadingAnchor
                                                  constant:XLPanelOverlap],
        [pauseButton.topAnchor constraintEqualToAnchor:actionPanel.topAnchor
                                              constant:2.0 * XLPanelRowHeight],
        [pauseButton.widthAnchor constraintEqualToConstant:halfCell],
        [pauseButton.heightAnchor constraintEqualToConstant:XLPanelRowHeight],
        [splitAction.leadingAnchor constraintEqualToAnchor:pauseButton.trailingAnchor],
        [splitAction.topAnchor constraintEqualToAnchor:actionPanel.topAnchor
                                              constant:2.0 * XLPanelRowHeight + 9.0],
        [splitAction.widthAnchor constraintEqualToConstant:XLPanelDividerWidth],
        [splitAction.heightAnchor constraintEqualToConstant:XLPanelRowHeight - 18.0],
        [closeButton.leadingAnchor constraintEqualToAnchor:splitAction.trailingAnchor],
        [closeButton.topAnchor constraintEqualToAnchor:actionPanel.topAnchor
                                              constant:2.0 * XLPanelRowHeight],
        [closeButton.widthAnchor constraintEqualToConstant:halfCell],
        [closeButton.heightAnchor constraintEqualToConstant:XLPanelRowHeight],

        [dividerRow2.leadingAnchor constraintEqualToAnchor:actionPanel.leadingAnchor
                                                  constant:XLPanelOverlap],
        [dividerRow2.topAnchor constraintEqualToAnchor:actionPanel.topAnchor
                                              constant:2.0 * XLPanelRowHeight - 0.5],
        [dividerRow2.widthAnchor constraintEqualToConstant:XLPanelWidth - XLPanelOverlap],
        [dividerRow2.heightAnchor constraintEqualToConstant:1.0],
    ]];
    xlStatusWindow = window;
    xlOverlayRootView = controller.view;
    xlHomeStatusButton = status;
    xlActionPanel = actionPanel;
    xlPauseButton = pauseButton;
    xlModeSwipeButton = modeSwipeButton;
    xlModeNovelButton = modeNovelButton;
    xlIntervalButton = intervalButton;
    xlIntervalValueLabel = intervalValue;
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
                xlMode = XLReadModePreference();
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
