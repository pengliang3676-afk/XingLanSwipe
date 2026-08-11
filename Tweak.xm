#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <notify.h>
#import <spawn.h>
#import <signal.h>
#import <arpa/inet.h>
#import <fcntl.h>
#import <netinet/in.h>
#import <sys/socket.h>
#import <sys/stat.h>
#import <sys/types.h>
#import <errno.h>
#import <string.h>
#import <unistd.h>
#import <objc/message.h>
#import "XingLanSwipeShared.h"

extern char **environ;

static BOOL xlRunning = NO;
static BOOL xlRequestedRunning = NO;
static BOOL xlStartInProgress = NO;
static int xlRunSocket = -1;
static dispatch_queue_t xlWorkerQueue;
#if XL_ROOT_HIDE
static pid_t xlDirectWorkerPID = 0;
static dispatch_source_t xlDirectWorkerExitSource;
#endif
static UIWindow *xlStatusWindow;
static UILabel *xlHomeStatusLabel;

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

static void XLUpdateUI(void) {
    if (!xlHomeStatusLabel) return;
    xlHomeStatusLabel.hidden = !xlRunning;
    xlHomeStatusLabel.text = @"开";
}

static BOOL XLWriteAll(int socketFD, const void *bytes, size_t length) {
    const uint8_t *cursor = (const uint8_t *)bytes;
    while (length > 0) {
        ssize_t written = send(socketFD, cursor, length, 0);
        if (written < 0 && errno == EINTR) continue;
        if (written <= 0) return NO;
        cursor += written;
        length -= (size_t)written;
    }
    return YES;
}

static BOOL XLReadAll(int socketFD, void *bytes, size_t length) {
    uint8_t *cursor = (uint8_t *)bytes;
    while (length > 0) {
        ssize_t received = recv(socketFD, cursor, length, 0);
        if (received < 0 && errno == EINTR) continue;
        if (received <= 0) return NO;
        cursor += received;
        length -= (size_t)received;
    }
    return YES;
}

static int XLConnectAutoGoService(void) {
    int socketFD = socket(AF_INET, SOCK_STREAM, 0);
    if (socketFD < 0) return -1;

    struct timeval timeout = {.tv_sec = 15, .tv_usec = 0};
    setsockopt(socketFD, SOL_SOCKET, SO_SNDTIMEO, &timeout, sizeof(timeout));
    setsockopt(socketFD, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(timeout));

    struct sockaddr_in address;
    memset(&address, 0, sizeof(address));
    address.sin_family = AF_INET;
    address.sin_port = htons(XLAutoGoServicePort);
    address.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    if (connect(socketFD, (struct sockaddr *)&address, sizeof(address)) != 0) {
        close(socketFD);
        return -1;
    }
    return socketFD;
}

static void XLRequestAutoGoDebugService(void);

static id XLCallObject(id target, SEL selector) {
    if (!target || !selector || ![target respondsToSelector:selector]) return nil;
    return ((id (*)(id, SEL))objc_msgSend)(target, selector);
}

static id XLCallObjectWithObject(id target, SEL selector, id argument) {
    if (!target || !selector || ![target respondsToSelector:selector]) return nil;
    return ((id (*)(id, SEL, id))objc_msgSend)(target, selector, argument);
}

static NSString *XLValidAutoGoBundlePath(NSString *bundlePath) {
    if (bundlePath.length == 0) return nil;
    NSFileManager *fileManager = NSFileManager.defaultManager;
    NSArray<NSString *> *required = @[@"agoverlayd", @"floatball", @"Runtime"];
    for (NSString *item in required) {
        NSString *path = [bundlePath stringByAppendingPathComponent:item];
        BOOL isDirectory = NO;
        if (![fileManager fileExistsAtPath:path isDirectory:&isDirectory]) return nil;
        if (![item isEqualToString:@"Runtime"] &&
            ![fileManager isExecutableFileAtPath:path]) return nil;
        if ([item isEqualToString:@"Runtime"] && !isDirectory) return nil;
    }
    return bundlePath;
}

static NSString *XLFindAutoGoBundlePath(void) {
    NSString *bundleIdentifier = [NSString stringWithUTF8String:XLAutoGoBundleIdentifier];
    Class proxyClass = NSClassFromString(@"LSApplicationProxy");
    id proxy = XLCallObjectWithObject(
        proxyClass,
        NSSelectorFromString(@"applicationProxyForIdentifier:"),
        bundleIdentifier);
    NSURL *bundleURL = XLCallObject(proxy, NSSelectorFromString(@"bundleURL"));
    NSString *resolved = XLValidAutoGoBundlePath(bundleURL.path);
    if (resolved) return resolved;

    // TrollStore uses a changing UUID directory. Only use this scan if
    // LSApplicationProxy does not expose the bundle URL on the current system.
    NSString *applicationsRoot = @"/var/containers/Bundle/Application";
    NSFileManager *fileManager = NSFileManager.defaultManager;
    NSArray<NSString *> *containers =
        [fileManager contentsOfDirectoryAtPath:applicationsRoot error:nil];
    for (NSString *containerName in containers) {
        NSString *containerPath = [applicationsRoot stringByAppendingPathComponent:containerName];
        NSArray<NSString *> *items =
            [fileManager contentsOfDirectoryAtPath:containerPath error:nil];
        for (NSString *item in items) {
            if (![item.pathExtension.lowercaseString isEqualToString:@"app"]) continue;
            NSString *bundlePath = [containerPath stringByAppendingPathComponent:item];
            NSDictionary *info = [NSDictionary dictionaryWithContentsOfFile:
                [bundlePath stringByAppendingPathComponent:@"Info.plist"]];
            if (![info[@"CFBundleIdentifier"] isEqualToString:bundleIdentifier]) continue;
            resolved = XLValidAutoGoBundlePath(bundlePath);
            if (resolved) return resolved;
        }
    }
    return nil;
}

static BOOL XLSpawnAutoGoService(NSString *bundlePath, NSString *executableName) {
    NSString *executable = [bundlePath stringByAppendingPathComponent:executableName];
    NSString *runtime = [bundlePath stringByAppendingPathComponent:@"Runtime"];
    const char *path = executable.fileSystemRepresentation;
    const char *runtimePath = runtime.fileSystemRepresentation;
    if (!path || !runtimePath) return NO;

    char *const arguments[] = {
        (char *)path,
        (char *)runtimePath,
        NULL,
    };
    pid_t pid = 0;
    int result = posix_spawn(&pid, path, NULL, NULL, arguments, environ);
    NSLog(@"[XingLanSwipe] AutoGo service %@ spawn result=%d pid=%d",
          executableName, result, pid);
    return result == 0 && pid > 0;
}

static BOOL XLStartAutoGoServicesOnDemand(void) {
    int socketFD = XLConnectAutoGoService();
    if (socketFD >= 0) {
        close(socketFD);
        return YES;
    }

    // A running floatball may only need the debug listener enabled.
    XLRequestAutoGoDebugService();
    usleep(350 * 1000);
    socketFD = XLConnectAutoGoService();
    if (socketFD >= 0) {
        close(socketFD);
        return YES;
    }

    NSString *bundlePath = XLFindAutoGoBundlePath();
    if (bundlePath.length == 0) {
        NSLog(@"[XingLanSwipe] TrollStore AutoGo bundle was not found");
        return NO;
    }

    BOOL overlayStarted = XLSpawnAutoGoService(bundlePath, @"agoverlayd");
    usleep(250 * 1000);
    BOOL floatballStarted = XLSpawnAutoGoService(bundlePath, @"floatball");
    return overlayStarted && floatballStarted;
}

static void XLRequestAutoGoDebugService(void) {
    CFNotificationCenterPostNotification(
        CFNotificationCenterGetDarwinNotifyCenter(),
        CFSTR(XLAutoGoDebugEnableNotification),
        NULL, NULL, YES);
}

static BOOL __attribute__((unused)) XLWaitForAutoGoService(void) {
    (void)XLStartAutoGoServicesOnDemand();
    for (NSUInteger attempt = 0; attempt < 50; attempt++) {
        int socketFD = XLConnectAutoGoService();
        if (socketFD >= 0) {
            close(socketFD);
            return YES;
        }

        if (attempt % 5 == 0) XLRequestAutoGoDebugService();
        usleep(200 * 1000);
    }

    NSLog(@"[XingLanSwipe] AutoGo background service did not open port %d",
          XLAutoGoServicePort);
    return NO;
}

static BOOL XLSendFrame(int socketFD, uint8_t command,
                        const void *payload, uint32_t payloadLength) {
    uint8_t header[5] = {command, 0, 0, 0, 0};
    uint32_t networkLength = htonl(payloadLength);
    memcpy(header + 1, &networkLength, sizeof(networkLength));
    if (!XLWriteAll(socketFD, header, sizeof(header))) return NO;
    return payloadLength == 0 || XLWriteAll(socketFD, payload, payloadLength);
}

static BOOL XLReadFrame(int socketFD, uint8_t *command, NSData **payload) {
    uint8_t header[5];
    if (!XLReadAll(socketFD, header, sizeof(header))) return NO;

    uint32_t networkLength = 0;
    memcpy(&networkLength, header + 1, sizeof(networkLength));
    uint32_t payloadLength = ntohl(networkLength);
    if (payloadLength > XLMaximumAutoGoFrameSize) return NO;

    NSMutableData *framePayload = [NSMutableData dataWithLength:payloadLength];
    if (payloadLength > 0 &&
        !XLReadAll(socketFD, framePayload.mutableBytes, payloadLength)) {
        return NO;
    }
    if (command) *command = header[0];
    if (payload) *payload = framePayload;
    return YES;
}

static BOOL XLReadOKFrame(int socketFD) {
    uint8_t command = 0;
    NSData *payload = nil;
    if (!XLReadFrame(socketFD, &command, &payload)) return NO;
    static const uint8_t expected[] = {'O', 'K'};
    return command == XLAutoGoAckCommand &&
           payload.length == sizeof(expected) &&
           memcmp(payload.bytes, expected, sizeof(expected)) == 0;
}

static NSString *XLWorkerResourcePath(void) {
    NSBundle *moduleBundle = [NSBundle bundleWithIdentifier:
        [NSString stringWithUTF8String:XLControlCenterBundleIdentifier]];
    NSString *bundledWorker = [moduleBundle pathForResource:@"AutoGoWorker" ofType:nil];
    if ([NSFileManager.defaultManager isReadableFileAtPath:bundledWorker]) {
        return bundledWorker;
    }

    NSArray<NSString *> *candidates = @[
        @"/var/jb/Library/ControlCenter/Bundles/XingLanSwipeModule.bundle/AutoGoWorker",
        @"/Library/ControlCenter/Bundles/XingLanSwipeModule.bundle/AutoGoWorker",
    ];
    for (NSString *path in candidates) {
        if ([NSFileManager.defaultManager isReadableFileAtPath:path]) return path;
    }
    return nil;
}

#if XL_ROOT_HIDE
static BOOL XLDirectWorkerIsAlive(void) {
    if (xlDirectWorkerPID <= 0) return NO;
    if (kill(xlDirectWorkerPID, 0) == 0) return YES;
    return errno == EPERM;
}

static void XLCleanupDirectWorkerState(void) {
    xlDirectWorkerPID = 0;
    if (xlDirectWorkerExitSource) {
        dispatch_source_cancel(xlDirectWorkerExitSource);
        xlDirectWorkerExitSource = nil;
    }
}

static void XLHandleDirectWorkerExit(pid_t pid) {
    if (pid != xlDirectWorkerPID) return;
    XLCleanupDirectWorkerState();
    xlStartInProgress = NO;
    if (xlRequestedRunning) {
        xlRequestedRunning = NO;
        xlRunning = NO;
        XLWritePreferenceRunning(NO);
        XLWriteWorkerFlag(NO);
        XLUpdateUI();
        NSLog(@"[XingLanSwipe] RootHide direct worker exited unexpectedly");
    }
}

static NSString *XLPrepareRootHideWorker(NSString *bundlePath) {
    NSString *runtime = [bundlePath stringByAppendingPathComponent:@"Runtime"];
    NSString *destination = [runtime stringByAppendingPathComponent:@"xinglan_worker"];
    NSString *source = XLWorkerResourcePath();
    NSFileManager *fileManager = NSFileManager.defaultManager;
    NSError *error = nil;

    if (source.length > 0) {
        [fileManager removeItemAtPath:destination error:nil];
        if ([fileManager copyItemAtPath:source toPath:destination error:&error] &&
            chmod(destination.fileSystemRepresentation, 0755) == 0 &&
            [fileManager isExecutableFileAtPath:destination]) {
            return destination;
        }
        NSLog(@"[XingLanSwipe] RootHide worker staging failed: %@",
              error.localizedDescription ?: @"chmod failed");
    }

    // The supplied TrollStore IPA also contains the same formal worker as
    // Runtime/app, so it is a safe fallback if its app bundle is read-only.
    NSString *fallback = [runtime stringByAppendingPathComponent:@"app"];
    return [fileManager isExecutableFileAtPath:fallback] ? fallback : nil;
}

static BOOL XLStartRootHideDirectWorker(void) {
    if (XLDirectWorkerIsAlive()) return YES;
    XLCleanupDirectWorkerState();

    NSString *bundlePath = XLFindAutoGoBundlePath();
    if (bundlePath.length == 0) {
        NSLog(@"[XingLanSwipe] RootHide TrollStore AutoGo bundle was not found");
        return NO;
    }
    NSString *executable = XLPrepareRootHideWorker(bundlePath);
    if (executable.length == 0) {
        NSLog(@"[XingLanSwipe] RootHide direct worker is unavailable");
        return NO;
    }

    const char *path = executable.fileSystemRepresentation;
    char *const arguments[] = {(char *)path, NULL};
    pid_t pid = 0;
    int result = posix_spawn(&pid, path, NULL, NULL, arguments, environ);
    if (result != 0 || pid <= 0) {
        NSLog(@"[XingLanSwipe] RootHide direct worker spawn failed result=%d", result);
        return NO;
    }

    xlDirectWorkerPID = pid;
    xlDirectWorkerExitSource = dispatch_source_create(
        DISPATCH_SOURCE_TYPE_PROC,
        (uintptr_t)pid,
        DISPATCH_PROC_EXIT,
        dispatch_get_main_queue());
    if (xlDirectWorkerExitSource) {
        dispatch_source_set_event_handler(xlDirectWorkerExitSource, ^{
            XLHandleDirectWorkerExit(pid);
        });
        dispatch_resume(xlDirectWorkerExitSource);
    }

    dispatch_async(dispatch_get_main_queue(), ^{
        if (!xlRequestedRunning) {
            kill(pid, SIGTERM);
            return;
        }
        xlStartInProgress = NO;
        xlRunning = YES;
        XLWritePreferenceRunning(YES);
        XLUpdateUI();
        NSLog(@"[XingLanSwipe] RootHide direct worker started pid=%d", pid);
    });
    return YES;
}
#endif

static BOOL __attribute__((unused)) XLUploadWorker(void) {
    NSString *workerPath = XLWorkerResourcePath();
    if (!workerPath) {
        NSLog(@"[XingLanSwipe] bundled AutoGo worker is missing");
        return NO;
    }

    int workerFD = open(workerPath.fileSystemRepresentation, O_RDONLY);
    if (workerFD < 0) return NO;

    struct stat workerStat;
    if (fstat(workerFD, &workerStat) != 0 || workerStat.st_size <= 0 ||
        (uint64_t)workerStat.st_size > UINT32_MAX - 7) {
        close(workerFD);
        return NO;
    }

    int socketFD = XLConnectAutoGoService();
    if (socketFD < 0) {
        close(workerFD);
        NSLog(@"[XingLanSwipe] AutoGo service 127.0.0.1:%d is unavailable",
              XLAutoGoServicePort);
        return NO;
    }

    const char remoteName[] = "debug";
    uint32_t payloadLength = (uint32_t)workerStat.st_size +
                             2 + (uint32_t)(sizeof(remoteName) - 1);
    uint8_t header[5] = {XLAutoGoPushCommand, 0, 0, 0, 0};
    uint32_t networkPayloadLength = htonl(payloadLength);
    memcpy(header + 1, &networkPayloadLength, sizeof(networkPayloadLength));
    uint16_t networkNameLength = htons((uint16_t)(sizeof(remoteName) - 1));

    BOOL success = XLWriteAll(socketFD, header, sizeof(header)) &&
                   XLWriteAll(socketFD, &networkNameLength, sizeof(networkNameLength)) &&
                   XLWriteAll(socketFD, remoteName, sizeof(remoteName) - 1);
    uint8_t buffer[64 * 1024];
    while (success) {
        ssize_t count = read(workerFD, buffer, sizeof(buffer));
        if (count < 0 && errno == EINTR) continue;
        if (count < 0) {
            success = NO;
            break;
        }
        if (count == 0) break;
        success = XLWriteAll(socketFD, buffer, (size_t)count);
    }
    close(workerFD);

    if (success) success = XLReadOKFrame(socketFD);
    close(socketFD);
    NSLog(@"[XingLanSwipe] AutoGo worker upload %@", success ? @"succeeded" : @"failed");
    return success;
}

static BOOL __attribute__((unused)) XLRunWorkerSession(void) {
    int socketFD = XLConnectAutoGoService();
    if (socketFD < 0) return NO;

    static const char runMode[] = "bin";
    if (!XLSendFrame(socketFD, XLAutoGoRunCommand,
                     runMode, (uint32_t)(sizeof(runMode) - 1)) ||
        !XLReadOKFrame(socketFD)) {
        close(socketFD);
        return NO;
    }

    if (!xlRequestedRunning) {
        close(socketFD);
        return YES;
    }

    struct timeval noTimeout = {.tv_sec = 0, .tv_usec = 0};
    setsockopt(socketFD, SOL_SOCKET, SO_RCVTIMEO, &noTimeout, sizeof(noTimeout));

    dispatch_async(dispatch_get_main_queue(), ^{
        if (!xlRequestedRunning) {
            shutdown(socketFD, SHUT_RDWR);
            return;
        }
        xlRunSocket = socketFD;
        xlRunning = YES;
        xlStartInProgress = NO;
        XLWritePreferenceRunning(YES);
        XLUpdateUI();
        NSLog(@"[XingLanSwipe] AutoGo worker started through debug service");
    });

    for (;;) {
        uint8_t command = 0;
        NSData *payload = nil;
        if (!XLReadFrame(socketFD, &command, &payload)) break;
        if (command == XLAutoGoLogCommand) continue;
        if (command == XLAutoGoExitCommand) break;
        if (command == XLAutoGoAckCommand && payload.length == 2 &&
            memcmp(payload.bytes, "OK", 2) != 0) {
            break;
        }
    }

    close(socketFD);
    dispatch_async(dispatch_get_main_queue(), ^{
        if (xlRunSocket == socketFD) xlRunSocket = -1;
        xlStartInProgress = NO;
        if (xlRequestedRunning) {
            xlRequestedRunning = NO;
            xlRunning = NO;
            XLWritePreferenceRunning(NO);
            XLWriteWorkerFlag(NO);
            XLUpdateUI();
            NSLog(@"[XingLanSwipe] AutoGo worker session ended unexpectedly");
        }
    });
    return YES;
}

static void __attribute__((unused)) XLSendStopCommand(void) {
    int socketFD = XLConnectAutoGoService();
    if (socketFD >= 0) {
        (void)XLSendFrame(socketFD, XLAutoGoStopCommand, NULL, 0);
        close(socketFD);
    }
}

static void XLStartWorker(void) {
    if (xlRunning || xlStartInProgress) return;
    if (!XLWriteWorkerFlag(YES)) {
        xlRequestedRunning = NO;
        XLWritePreferenceRunning(NO);
        XLUpdateUI();
        return;
    }

    xlStartInProgress = YES;
    dispatch_async(xlWorkerQueue, ^{
#if XL_ROOT_HIDE
        if (!XLStartRootHideDirectWorker()) {
            dispatch_async(dispatch_get_main_queue(), ^{
                xlStartInProgress = NO;
                xlRequestedRunning = NO;
                xlRunning = NO;
                XLWritePreferenceRunning(NO);
                XLWriteWorkerFlag(NO);
                XLUpdateUI();
            });
        }
        return;
#else
        if (!XLWaitForAutoGoService()) {
            dispatch_async(dispatch_get_main_queue(), ^{
                xlStartInProgress = NO;
                xlRequestedRunning = NO;
                xlRunning = NO;
                XLWritePreferenceRunning(NO);
                XLWriteWorkerFlag(NO);
                XLUpdateUI();
            });
            return;
        }
        if (!XLUploadWorker()) {
            dispatch_async(dispatch_get_main_queue(), ^{
                xlStartInProgress = NO;
                xlRequestedRunning = NO;
                xlRunning = NO;
                XLWritePreferenceRunning(NO);
                XLWriteWorkerFlag(NO);
                XLUpdateUI();
            });
            return;
        }
        if (!xlRequestedRunning || !XLRunWorkerSession()) {
            dispatch_async(dispatch_get_main_queue(), ^{
                xlStartInProgress = NO;
                if (xlRequestedRunning) {
                    xlRequestedRunning = NO;
                    XLWritePreferenceRunning(NO);
                }
                xlRunning = NO;
                XLWriteWorkerFlag(NO);
                XLUpdateUI();
            });
        }
#endif
    });
}

static void XLStopWorker(void) {
    XLWriteWorkerFlag(NO);
#if XL_ROOT_HIDE
    pid_t pid = xlDirectWorkerPID;
    if (pid > 0 && kill(pid, SIGTERM) != 0 && errno != ESRCH) {
        NSLog(@"[XingLanSwipe] RootHide direct worker stop failed pid=%d errno=%d",
              pid, errno);
    }
#else
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        XLSendStopCommand();
        int socketFD = xlRunSocket;
        if (socketFD >= 0) shutdown(socketFD, SHUT_RDWR);
    });
#endif
}

static void XLSetRunning(BOOL requestedRunning) {
    xlRequestedRunning = requestedRunning;
    if (requestedRunning) {
        XLStartWorker();
        return;
    }

    xlRunning = NO;
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
            xlWorkerQueue = dispatch_queue_create(
                "com.jibeib.xinglanswipe.autogo", DISPATCH_QUEUE_SERIAL);
            XLWriteWorkerFlag(NO);
            XLWritePreferenceRunning(NO);
            XLInstallStatusOverlay();
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
