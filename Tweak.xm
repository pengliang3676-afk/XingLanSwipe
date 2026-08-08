#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <notify.h>
#import "XLHIDSender.h"
#import "XingLanSwipeShared.h"

static const uint32_t XLMinimumDelay = 180;
static const uint32_t XLMaximumDelay = 300;

static dispatch_source_t xlTimer;
static XLHIDSender *xlSender;
static BOOL xlRunning = NO;
static UILabel *xlHomeStatusLabel;

static void XLUpdateUI(void) {
    UILabel *status = xlHomeStatusLabel;
    if (status) {
        status.hidden = !xlRunning;
        status.text = @"A";
    }
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
    if (xlRunning) {
        XLScheduleNext();
        NSLog(@"[XingLanSwipe] started from Control Center");
    } else {
        XLCancelTimer();
        NSLog(@"[XingLanSwipe] stopped");
    }
    XLUpdateUI();
}

static void XLInstallHomeStatus(UIView *homeView) {
    if (!homeView) return;
    if (xlHomeStatusLabel.superview == homeView) {
        XLUpdateUI();
        return;
    }

    [xlHomeStatusLabel removeFromSuperview];
    UILabel *status = [UILabel new];
    status.translatesAutoresizingMaskIntoConstraints = NO;
    status.userInteractionEnabled = NO;
    status.textAlignment = NSTextAlignmentCenter;
    status.font = [UIFont boldSystemFontOfSize:12.0];
    status.textColor = UIColor.whiteColor;
    status.backgroundColor = [UIColor colorWithRed:0.04 green:0.45 blue:0.25 alpha:0.92];
    status.layer.cornerRadius = 10.0;
    status.layer.borderWidth = 1.0;
    status.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.30].CGColor;
    status.layer.shadowColor = [UIColor colorWithRed:0.10 green:0.95 blue:0.50 alpha:1.0].CGColor;
    status.layer.shadowOpacity = 0.72;
    status.layer.shadowRadius = 4.0;
    status.layer.shadowOffset = CGSizeZero;
    status.clipsToBounds = YES;
    [homeView addSubview:status];

    UILayoutGuide *safeArea = homeView.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [status.leadingAnchor constraintEqualToAnchor:safeArea.leadingAnchor constant:5.0],
        [status.centerYAnchor constraintEqualToAnchor:safeArea.centerYAnchor],
        [status.widthAnchor constraintEqualToConstant:20.0],
        [status.heightAnchor constraintEqualToConstant:20.0],
    ]];
    xlHomeStatusLabel = status;
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

// 运行状态只显示在桌面左侧正中，作为不可点击的 A 高亮提示。
%hook SBHomeScreenViewController
- (void)viewDidAppear:(BOOL)animated {
    %orig;
    XLInstallHomeStatus(((UIViewController *)self).view);
}
%end

__attribute__((constructor))
static void XingLanSwipeInit(void) {
    @autoreleasepool {
        dispatch_async(dispatch_get_main_queue(), ^{
            xlSender = [XLHIDSender new];
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
