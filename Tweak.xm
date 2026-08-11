#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <notify.h>
#import <spawn.h>
#import <signal.h>
#import <sys/types.h>
#import <sys/wait.h>
#import <errno.h>
#import <unistd.h>
#import <objc/message.h>
#import "XingLanSwipeShared.h"

extern char **environ;

static BOOL xlRunning = NO;
static pid_t xlWorkerPID = 0;
static dispatch_source_t xlWorkerExitSource;
static dispatch_source_t xlForegroundTimer;
static UIWindow *xlStatusWindow;
static UILabel *xlHomeStatusLabel;

static NSString *const XLTargetApplicationBundleIdentifier = @"com.baidu.BaiduMobileInfo";

@interface UIApplication (XLFrontmostApplication)
- (id)_accessibilityFrontMostApplication;
@end

@interface NSObject (XLApplicationIdentity)
+ (id)sharedInstance;
- (id)frontmostApplication;
- (NSString *)bundleIdentifier;
@end

@interface XLStatusOverlayWindow : UIWindow
@end

@implementation XLStatusOverlayWindow
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    (void)point;
    (void)event;
    return nil;
}
@end

static void XLWritePreferenceRunning(BOOL running) {
    CFPreferencesSetAppValue(CFSTR(XLRunningPreferenceKey),
        running ? kCFBooleanTrue : kCFBooleanFalse,
        CFSTR(XLPreferenceDomain));
    CFPreferencesAppSynchronize(CFSTR(XLPreferenceDomain));
}

static BOOL XLWriteWorkerFlag(BOOL running) {
    NSString *value = running ? @"1\n" : @"0\n";
    NSString *flagPath = [NSString stringWithUTF8String:XLWorkerRunFlagPath];
    NSError *error = nil;
    BOOL success = [value writeToFile:flagPath
                           atomically:YES
                             encoding:NSUTF8StringEncoding
                                error:&error];
    if (!success) {
        NSLog(@"[XingLanSwipe] worker flag write failed: %@",
              error.localizedDescription ?: @"unknown error");
    }
    return success;
}

static BOOL XLWriteForegroundFlag(BOOL foreground) {
    NSString *value = foreground ? @"1\n" : @"0\n";
    NSString *flagPath = [NSString stringWithUTF8String:XLForegroundFlagPath];
    NSError *error = nil;
    BOOL success = [value writeToFile:flagPath
                           atomically:YES
                             encoding:NSUTF8StringEncoding
                                error:&error];
    if (!success) {
        NSLog(@"[XingLanSwipe] foreground flag write failed: %@",
              error.localizedDescription ?: @"unknown error");
    }
    return success;
}

static BOOL XLTargetApplicationIsForeground(void) {
    UIApplication *application = UIApplication.sharedApplication;
    id frontmostApplication = nil;
    if ([application respondsToSelector:@selector(_accessibilityFrontMostApplication)]) {
        frontmostApplication = [application _accessibilityFrontMostApplication];
    }
    if (!frontmostApplication) {
        Class workspaceClass = NSClassFromString(@"SBMainWorkspace");
        if ([workspaceClass respondsToSelector:@selector(sharedInstance)]) {
            id workspace = [workspaceClass sharedInstance];
            if ([workspace respondsToSelector:@selector(frontmostApplication)]) {
                frontmostApplication = [workspace frontmostApplication];
            }
        }
    }
    if (![frontmostApplication respondsToSelector:@selector(bundleIdentifier)]) {
        return NO;
    }
    return [[frontmostApplication bundleIdentifier]
        isEqualToString:XLTargetApplicationBundleIdentifier];
}

static void XLStopForegroundMonitor(void) {
    if (xlForegroundTimer) {
        dispatch_source_cancel(xlForegroundTimer);
        xlForegroundTimer = nil;
    }
    XLWriteForegroundFlag(NO);
}

static void XLStartForegroundMonitor(void) {
    XLStopForegroundMonitor();
    XLWriteForegroundFlag(XLTargetApplicationIsForeground());
    xlForegroundTimer = dispatch_source_create(
        DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
    dispatch_source_set_timer(
        xlForegroundTimer,
        dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC),
        NSEC_PER_SEC,
        NSEC_PER_SEC / 10);
    dispatch_source_set_event_handler(xlForegroundTimer, ^{
        if (xlRunning) {
            XLWriteForegroundFlag(XLTargetApplicationIsForeground());
        }
    });
    dispatch_resume(xlForegroundTimer);
}

static void XLUpdateUI(void) {
    if (!xlHomeStatusLabel) return;
    xlHomeStatusLabel.hidden = !xlRunning;
    xlHomeStatusLabel.text = @"开";
}

static BOOL XLWorkerIsAlive(void) {
    if (xlWorkerPID <= 0) return NO;
    if (kill(xlWorkerPID, 0) == 0) return YES;
    return errno == EPERM;
}

static id XLCallObject(id target, SEL selector) {
    if (!target || !selector || ![target respondsToSelector:selector]) return nil;
    return ((id (*)(id, SEL))objc_msgSend)(target, selector);
}

static id XLCallObjectWithObject(id target, SEL selector, id argument) {
    if (!target || !selector || ![target respondsToSelector:selector]) return nil;
    return ((id (*)(id, SEL, id))objc_msgSend)(target, selector, argument);
}

static NSString *XLWorkerPathInsideBundle(NSString *bundlePath) {
    if (bundlePath.length == 0) return nil;
    NSString *candidate = [bundlePath stringByAppendingPathComponent:@"Runtime/app"];
    return [NSFileManager.defaultManager isExecutableFileAtPath:candidate] ? candidate : nil;
}

static NSString *XLFindWorkerByBundleIdentifier(void) {
    NSString *bundleIdentifier = [NSString stringWithUTF8String:XLWorkerBundleIdentifier];

    NSString *rootlessPath = @"/var/jb/Applications/com.auto.go.app/Runtime/app";
    if ([NSFileManager.defaultManager isExecutableFileAtPath:rootlessPath]) {
        return rootlessPath;
    }

    // TrollStore installs apps in a UUID directory. Resolve that directory by
    // bundle identifier so the path remains valid after reinstalling AutoGo.
    Class proxyClass = NSClassFromString(@"LSApplicationProxy");
    SEL proxySelector = NSSelectorFromString(@"applicationProxyForIdentifier:");
    id proxy = XLCallObjectWithObject(proxyClass, proxySelector, bundleIdentifier);
    NSURL *bundleURL = XLCallObject(proxy, NSSelectorFromString(@"bundleURL"));
    NSString *resolved = XLWorkerPathInsideBundle(bundleURL.path);
    if (resolved) return resolved;

    // Fallback for systems where LSApplicationProxy does not expose bundleURL.
    NSString *applicationsRoot = @"/var/containers/Bundle/Application";
    NSFileManager *fileManager = NSFileManager.defaultManager;
    NSArray<NSString *> *containers = [fileManager contentsOfDirectoryAtPath:applicationsRoot error:nil];
    for (NSString *containerName in containers) {
        NSString *containerPath = [applicationsRoot stringByAppendingPathComponent:containerName];
        NSArray<NSString *> *items = [fileManager contentsOfDirectoryAtPath:containerPath error:nil];
        for (NSString *item in items) {
            if (![item.pathExtension.lowercaseString isEqualToString:@"app"]) continue;
            NSString *bundlePath = [containerPath stringByAppendingPathComponent:item];
            NSDictionary *info = [NSDictionary dictionaryWithContentsOfFile:
                [bundlePath stringByAppendingPathComponent:@"Info.plist"]];
            if (![info[@"CFBundleIdentifier"] isEqualToString:bundleIdentifier]) continue;
            resolved = XLWorkerPathInsideBundle(bundlePath);
            if (resolved) return resolved;
        }
    }

    return nil;
}

static void XLCleanupWorkerState(void) {
    xlWorkerPID = 0;
    if (xlWorkerExitSource) {
        dispatch_source_cancel(xlWorkerExitSource);
        xlWorkerExitSource = nil;
    }
}

static void XLHandleWorkerExit(pid_t pid) {
    int status = 0;
    (void)waitpid(pid, &status, WNOHANG);
    if (pid != xlWorkerPID) return;

    XLCleanupWorkerState();
    if (xlRunning) {
        xlRunning = NO;
        XLStopForegroundMonitor();
        XLWritePreferenceRunning(NO);
        XLWriteWorkerFlag(NO);
        XLUpdateUI();
        NSLog(@"[XingLanSwipe] AutoGo worker exited unexpectedly status=%d", status);
    } else {
        NSLog(@"[XingLanSwipe] AutoGo worker stopped status=%d", status);
    }
}

static BOOL XLStartWorker(void) {
    if (XLWorkerIsAlive()) {
        NSLog(@"[XingLanSwipe] AutoGo worker is already running pid=%d", xlWorkerPID);
        return YES;
    }
    XLCleanupWorkerState();

    NSString *executable = XLFindWorkerByBundleIdentifier();
    if (executable.length == 0) {
        NSLog(@"[XingLanSwipe] AutoGo worker missing for bundle: %s",
              XLWorkerBundleIdentifier);
        return NO;
    }
    if (!XLWriteWorkerFlag(YES)) return NO;
    if (!XLWriteForegroundFlag(XLTargetApplicationIsForeground())) {
        XLWriteWorkerFlag(NO);
        return NO;
    }

    const char *path = executable.fileSystemRepresentation;
    char *const arguments[] = {(char *)path, NULL};
    pid_t pid = 0;
    int result = posix_spawn(&pid, path, NULL, NULL, arguments, environ);
    if (result != 0 || pid <= 0) {
        XLWriteWorkerFlag(NO);
        NSLog(@"[XingLanSwipe] AutoGo worker launch failed result=%d", result);
        return NO;
    }

    xlWorkerPID = pid;
    xlWorkerExitSource = dispatch_source_create(
        DISPATCH_SOURCE_TYPE_PROC,
        (uintptr_t)pid,
        DISPATCH_PROC_EXIT,
        dispatch_get_main_queue());
    if (xlWorkerExitSource) {
        dispatch_source_set_event_handler(xlWorkerExitSource, ^{
            XLHandleWorkerExit(pid);
        });
        dispatch_resume(xlWorkerExitSource);
    }

    NSLog(@"[XingLanSwipe] AutoGo worker started pid=%d", pid);
    return YES;
}

static void XLStopWorker(void) {
    XLWriteWorkerFlag(NO);
    if (!XLWorkerIsAlive()) {
        XLCleanupWorkerState();
        return;
    }

    pid_t pid = xlWorkerPID;
    if (kill(pid, SIGTERM) != 0 && errno != ESRCH) {
        NSLog(@"[XingLanSwipe] AutoGo worker SIGTERM failed pid=%d errno=%d", pid, errno);
    } else {
        NSLog(@"[XingLanSwipe] AutoGo worker stop requested pid=%d", pid);
    }
}

static void XLSetRunning(BOOL requestedRunning) {
    if (requestedRunning) {
        if (xlRunning && XLWorkerIsAlive()) {
            XLUpdateUI();
            return;
        }

        BOOL started = XLStartWorker();
        xlRunning = started;
        if (started) {
            XLStartForegroundMonitor();
        } else {
            XLStopForegroundMonitor();
        }
        XLWritePreferenceRunning(started);
        XLUpdateUI();
        return;
    }

    xlRunning = NO;
    XLStopForegroundMonitor();
    XLWritePreferenceRunning(NO);
    XLStopWorker();
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
    BOOL requestedRunning = value && CFEqual(value, kCFBooleanTrue);
    if (value) CFRelease(value);
    dispatch_async(dispatch_get_main_queue(), ^{ XLSetRunning(requestedRunning); });
}

__attribute__((constructor))
static void XingLanSwipeInit(void) {
    @autoreleasepool {
        NSString *bundleIdentifier = NSBundle.mainBundle.bundleIdentifier;
        if (![bundleIdentifier isEqualToString:@"com.apple.springboard"]) return;

        dispatch_async(dispatch_get_main_queue(), ^{
            XLWriteWorkerFlag(NO);
            XLWriteForegroundFlag(NO);
            XLWritePreferenceRunning(NO);
            XLInstallStatusOverlay();
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
            NSLog(@"[XingLanSwipe] controller loaded; AutoGo worker is stopped");
        });
    }
}
