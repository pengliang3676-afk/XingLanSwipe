#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <notify.h>
#import "XLBackIconDetector.h"
#import "XingLanSwipeShared.h"

static const NSTimeInterval XLRecognitionDelay = 4.0;

static BOOL xlRunning = NO;
static NSUInteger xlRunGeneration = 0;
static XLBackIconDetector *xlDetector;
static dispatch_queue_t xlRecognitionQueue;
static UIWindow *xlStatusWindow;
static UILabel *xlStatusLabel;

@interface XLStatusOverlayWindow : UIWindow
@end

@implementation XLStatusOverlayWindow
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    (void)point;
    (void)event;
    return nil;
}
@end

static void XLWriteRunningPreference(BOOL running) {
    CFPreferencesSetAppValue(CFSTR(XLRunningPreferenceKey),
        running ? kCFBooleanTrue : kCFBooleanFalse,
        CFSTR(XLPreferenceDomain));
    CFPreferencesAppSynchronize(CFSTR(XLPreferenceDomain));
}

static void XLSetStatus(NSString *text) {
    if (!xlStatusLabel) return;
    xlStatusLabel.hidden = !xlRunning;
    xlStatusLabel.text = text ?: @"";
}

static void XLPerformOneShotRecognition(NSUInteger generation) {
    if (!xlRunning || generation != xlRunGeneration) return;

    XLSetStatus(@"识");
    NSError *captureError = nil;
    UIImage *screenshot = [xlDetector captureScreenWithError:&captureError];
    if (!screenshot) {
        NSLog(@"[XingLanSwipe] native capture failed: %@",
              captureError.localizedDescription ?: @"unknown error");
        XLSetStatus(@"图错");
        return;
    }

    dispatch_async(xlRecognitionQueue, ^{
        @autoreleasepool {
            NSError *recognitionError = nil;
            BOOL found = [xlDetector containsMyTextInScreenshot:screenshot
                                                           error:&recognitionError];
            dispatch_async(dispatch_get_main_queue(), ^{
                if (!xlRunning || generation != xlRunGeneration) return;
                if (recognitionError) {
                    NSLog(@"[XingLanSwipe] native Vision OCR failed: %@",
                          recognitionError.localizedDescription ?: @"unknown error");
                    XLSetStatus(@"识错");
                    return;
                }

                NSLog(@"[XingLanSwipe] native Vision OCR result=%@",
                      found ? @"MY_FOUND" : @"MY_NOT_FOUND");
                XLSetStatus(found ? @"有我" : @"无我");
            });
        }
    });
}

static void XLSetRunning(BOOL running) {
    xlRunGeneration++;
    xlRunning = running;
    XLWriteRunningPreference(running);

    if (!running) {
        XLSetStatus(nil);
        return;
    }

    NSUInteger generation = xlRunGeneration;
    XLSetStatus(@"等");
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                 (int64_t)(XLRecognitionDelay * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        XLPerformOneShotRecognition(generation);
    });
}

static void XLInstallStatusOverlay(void) {
    if (xlStatusWindow) return;

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
    status.adjustsFontSizeToFitWidth = YES;
    status.minimumScaleFactor = 0.60;
    status.font = [UIFont boldSystemFontOfSize:18.0];
    status.textColor = UIColor.whiteColor;
    status.backgroundColor = [UIColor colorWithRed:0.05 green:0.46 blue:0.94 alpha:0.88];
    status.layer.cornerRadius = 27.0;
    status.layer.borderWidth = 1.5;
    status.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.85].CGColor;
    status.clipsToBounds = YES;
    status.hidden = YES;
    [controller.view addSubview:status];

    UILayoutGuide *safeArea = controller.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [status.leadingAnchor constraintEqualToAnchor:safeArea.leadingAnchor constant:5.0],
        [status.centerYAnchor constraintEqualToAnchor:safeArea.centerYAnchor],
        [status.widthAnchor constraintEqualToConstant:54.0],
        [status.heightAnchor constraintEqualToConstant:54.0],
    ]];

    xlStatusWindow = window;
    xlStatusLabel = status;
    window.hidden = NO;
}

static void XLLockCallback(CFNotificationCenterRef center, void *observer,
                           CFStringRef name, const void *object,
                           CFDictionaryRef userInfo) {
    (void)center;
    (void)observer;
    (void)name;
    (void)object;
    (void)userInfo;
    dispatch_async(dispatch_get_main_queue(), ^{ XLSetRunning(NO); });
}

static void XLControlCenterStateCallback(CFNotificationCenterRef center, void *observer,
                                         CFStringRef name, const void *object,
                                         CFDictionaryRef userInfo) {
    (void)center;
    (void)observer;
    (void)name;
    (void)object;
    (void)userInfo;

    CFPropertyListRef value = CFPreferencesCopyAppValue(
        CFSTR(XLRunningPreferenceKey), CFSTR(XLPreferenceDomain));
    BOOL running = value && CFEqual(value, kCFBooleanTrue);
    if (value) CFRelease(value);
    dispatch_async(dispatch_get_main_queue(), ^{ XLSetRunning(running); });
}

__attribute__((constructor))
static void XingLanSwipeInit(void) {
    @autoreleasepool {
        if (![NSBundle.mainBundle.bundleIdentifier isEqualToString:@"com.apple.springboard"]) {
            return;
        }

        dispatch_async(dispatch_get_main_queue(), ^{
            xlDetector = [XLBackIconDetector new];
            xlRecognitionQueue = dispatch_queue_create(
                "com.jibeib.xinglanswipe.native-vision", DISPATCH_QUEUE_SERIAL);
            XLInstallStatusOverlay();
            XLSetRunning(NO);

            CFNotificationCenterAddObserver(
                CFNotificationCenterGetDarwinNotifyCenter(),
                NULL,
                XLLockCallback,
                CFSTR("com.apple.springboard.lockcomplete"),
                NULL,
                CFNotificationSuspensionBehaviorDeliverImmediately);
            CFNotificationCenterAddObserver(
                CFNotificationCenterGetDarwinNotifyCenter(),
                NULL,
                XLControlCenterStateCallback,
                CFSTR(XLControlCenterStateNotification),
                NULL,
                CFNotificationSuspensionBehaviorDeliverImmediately);

            NSLog(@"[XingLanSwipe] native one-shot Vision OCR test loaded");
        });
    }
}
