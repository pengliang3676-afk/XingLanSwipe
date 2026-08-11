#import <Foundation/Foundation.h>
#import <CoreFoundation/CoreFoundation.h>
#import <arpa/inet.h>
#import <errno.h>
#import <fcntl.h>
#import <limits.h>
#import <signal.h>
#import <spawn.h>
#import <sys/socket.h>
#import <sys/stat.h>
#import <sys/wait.h>
#import <string.h>
#import <unistd.h>

extern char **environ;

static NSString *const XLStatusPath =
    @"/var/mobile/Library/Preferences/com.jibeib.xinglanswipe.daemon.status";
static NSString *const XLFlagPath =
    @"/var/mobile/Library/Preferences/com.jibeib.xinglanswipe.worker";
static NSString *const XLServiceLogPath =
    @"/var/mobile/Library/Preferences/com.jibeib.xinglanswipe.autogo-service.log";
static NSString *const XLAutoGoBundleIdentifier = @"com.auto.go";
static CFStringRef const XLAutoGoDebugEnableNotification =
    CFSTR("com.autogo.floatball.debug.enable_request");
static const uint16_t XLAutoGoPort = 8820;

static volatile sig_atomic_t XLShouldStop = 0;
static pid_t XLOverlayPID = 0;
static pid_t XLFloatballPID = 0;
static NSString *XLLastStatus;

static void XLSignalHandler(int signalNumber) {
    (void)signalNumber;
    XLShouldStop = 1;
}

static void XLWriteStatus(NSString *status) {
    if ([XLLastStatus isEqualToString:status]) return;
    XLLastStatus = [status copy];
    [status writeToFile:XLStatusPath
             atomically:YES
               encoding:NSUTF8StringEncoding
                  error:nil];
    chmod(XLStatusPath.fileSystemRepresentation, 0644);
}

static BOOL XLWorkerEnabled(void) {
    NSString *value = [NSString stringWithContentsOfFile:XLFlagPath
                                                 encoding:NSUTF8StringEncoding
                                                    error:nil];
    value = [value stringByTrimmingCharactersInSet:
        NSCharacterSet.whitespaceAndNewlineCharacterSet];
    return [value isEqualToString:@"1"];
}

static BOOL XLPortOpen(void) {
    int socketFD = socket(AF_INET, SOCK_STREAM, 0);
    if (socketFD < 0) return NO;

    struct sockaddr_in address;
    memset(&address, 0, sizeof(address));
    address.sin_family = AF_INET;
    address.sin_port = htons(XLAutoGoPort);
    address.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    BOOL connected = connect(socketFD, (struct sockaddr *)&address,
                             sizeof(address)) == 0;
    close(socketFD);
    return connected;
}

static NSString *XLValidAutoGoBundle(NSString *bundlePath) {
    if (bundlePath.length == 0) return nil;
    NSFileManager *fileManager = NSFileManager.defaultManager;
    NSDictionary *info = [NSDictionary dictionaryWithContentsOfFile:
        [bundlePath stringByAppendingPathComponent:@"Info.plist"]];
    if (![info[@"CFBundleIdentifier"] isEqualToString:XLAutoGoBundleIdentifier]) {
        return nil;
    }

    for (NSString *name in @[@"agoverlayd", @"floatball"]) {
        NSString *path = [bundlePath stringByAppendingPathComponent:name];
        if (![fileManager isExecutableFileAtPath:path]) return nil;
    }
    BOOL isDirectory = NO;
    NSString *runtime = [bundlePath stringByAppendingPathComponent:@"Runtime"];
    if (![fileManager fileExistsAtPath:runtime isDirectory:&isDirectory] ||
        !isDirectory) return nil;
    return bundlePath;
}

static NSString *XLFindAutoGoBundle(void) {
    NSArray<NSString *> *fixedCandidates = @[
        @"/Applications/com.auto.go.app",
        @"/var/jb/Applications/com.auto.go.app",
    ];
    for (NSString *candidate in fixedCandidates) {
        NSString *valid = XLValidAutoGoBundle(candidate);
        if (valid) return valid;
    }

    NSString *applicationsRoot = @"/var/containers/Bundle/Application";
    NSFileManager *fileManager = NSFileManager.defaultManager;
    NSArray<NSString *> *containers =
        [fileManager contentsOfDirectoryAtPath:applicationsRoot error:nil];
    for (NSString *containerName in containers) {
        NSString *container = [applicationsRoot stringByAppendingPathComponent:containerName];
        NSArray<NSString *> *items =
            [fileManager contentsOfDirectoryAtPath:container error:nil];
        for (NSString *item in items) {
            if (![item.pathExtension.lowercaseString isEqualToString:@"app"]) continue;
            NSString *valid = XLValidAutoGoBundle(
                [container stringByAppendingPathComponent:item]);
            if (valid) return valid;
        }
    }
    return nil;
}

static void XLReapPID(pid_t *pid) {
    if (*pid <= 0) return;
    pid_t result = waitpid(*pid, NULL, WNOHANG);
    if (result == *pid || (result < 0 && errno == ECHILD)) *pid = 0;
}

static BOOL XLSpawnService(NSString *bundlePath, NSString *name, pid_t *pid) {
    XLReapPID(pid);
    if (*pid > 0 && kill(*pid, 0) == 0) return YES;
    *pid = 0;

    NSString *executable = [bundlePath stringByAppendingPathComponent:name];
    NSString *runtime = [bundlePath stringByAppendingPathComponent:@"Runtime"];
    const char *path = executable.fileSystemRepresentation;
    const char *runtimePath = runtime.fileSystemRepresentation;
    if (!path || !runtimePath) return NO;

    char oldDirectory[PATH_MAX] = {0};
    (void)getcwd(oldDirectory, sizeof(oldDirectory));
    if (chdir(bundlePath.fileSystemRepresentation) != 0) return NO;

    posix_spawn_file_actions_t actions;
    posix_spawn_file_actions_init(&actions);
    posix_spawn_file_actions_addopen(&actions, STDOUT_FILENO,
        XLServiceLogPath.fileSystemRepresentation,
        O_WRONLY | O_CREAT | O_APPEND, 0644);
    posix_spawn_file_actions_addopen(&actions, STDERR_FILENO,
        XLServiceLogPath.fileSystemRepresentation,
        O_WRONLY | O_CREAT | O_APPEND, 0644);

    char *const arguments[] = {(char *)path, (char *)runtimePath, NULL};
    pid_t child = 0;
    int result = posix_spawn(&child, path, &actions, NULL, arguments, environ);
    posix_spawn_file_actions_destroy(&actions);
    if (oldDirectory[0] != '\0') (void)chdir(oldDirectory);
    if (result != 0 || child <= 0) {
        XLWriteStatus([NSString stringWithFormat:@"E%@%d",
            [name isEqualToString:@"agoverlayd"] ? @"O" : @"F", result]);
        return NO;
    }
    *pid = child;
    return YES;
}

static void XLRequestDebugService(void) {
    CFNotificationCenterPostNotification(
        CFNotificationCenterGetDarwinNotifyCenter(),
        XLAutoGoDebugEnableNotification, NULL, NULL, YES);
}

static BOOL XLEnsureAutoGoService(void) {
    if (XLPortOpen()) {
        XLWriteStatus(@"SERVICE_RUNNING");
        return YES;
    }

    NSString *bundlePath = XLFindAutoGoBundle();
    if (!bundlePath) {
        XLWriteStatus(@"AUTO_GO_NOT_FOUND");
        return NO;
    }

    BOOL overlayOK = XLSpawnService(bundlePath, @"agoverlayd", &XLOverlayPID);
    BOOL floatballOK = XLSpawnService(bundlePath, @"floatball", &XLFloatballPID);
    if (!overlayOK || !floatballOK) return NO;

    for (NSUInteger attempt = 0;
         attempt < 30 && !XLShouldStop && XLWorkerEnabled();
         attempt++) {
        if (attempt % 4 == 0) XLRequestDebugService();
        if (XLPortOpen()) {
            XLWriteStatus(@"SERVICE_RUNNING");
            return YES;
        }
        usleep(250 * 1000);
    }
    XLWriteStatus(@"SERVICE_TIMEOUT");
    return NO;
}

static void XLStopService(pid_t *pid) {
    XLReapPID(pid);
    if (*pid <= 0) return;
    kill(*pid, SIGTERM);
    for (NSUInteger attempt = 0; attempt < 20; attempt++) {
        pid_t result = waitpid(*pid, NULL, WNOHANG);
        if (result == *pid || (result < 0 && errno == ECHILD)) {
            *pid = 0;
            return;
        }
        usleep(100 * 1000);
    }
    kill(*pid, SIGKILL);
    waitpid(*pid, NULL, 0);
    *pid = 0;
}

int main(int argc, char **argv) {
    (void)argc;
    (void)argv;
    @autoreleasepool {
        signal(SIGTERM, XLSignalHandler);
        signal(SIGINT, XLSignalHandler);
        XLWriteStatus(@"IDLE");
        NSUInteger consecutiveFailures = 0;

        while (!XLShouldStop) {
            if (!XLWorkerEnabled()) {
                XLStopService(&XLFloatballPID);
                XLStopService(&XLOverlayPID);
                consecutiveFailures = 0;
                XLWriteStatus(@"IDLE");
                usleep(1000 * 1000);
                continue;
            }

            XLReapPID(&XLOverlayPID);
            XLReapPID(&XLFloatballPID);

            BOOL serviceReady = XLEnsureAutoGoService();
            if (serviceReady) {
                consecutiveFailures = 0;
            } else {
                consecutiveFailures++;
            }

            NSUInteger waitSeconds = serviceReady ? 60 :
                (consecutiveFailures <= 3 ? 5 : 30);
            NSUInteger ticks = waitSeconds * 2;
            for (NSUInteger tick = 0;
                 tick < ticks && !XLShouldStop && XLWorkerEnabled();
                 tick++) {
                usleep(500 * 1000);
            }
        }

        XLStopService(&XLFloatballPID);
        XLStopService(&XLOverlayPID);
        XLWriteStatus(@"STOPPED");
    }
    return 0;
}
