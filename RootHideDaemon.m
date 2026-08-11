#import <Foundation/Foundation.h>
#import <roothide.h>
#import <errno.h>
#import <fcntl.h>
#import <signal.h>
#import <spawn.h>
#import <sys/stat.h>
#import <sys/wait.h>
#import <unistd.h>

extern char **environ;

static NSString *const XLFlagPath =
    @"/var/mobile/Library/Preferences/com.jibeib.xinglanswipe.worker";
static NSString *const XLStatusPath =
    @"/var/mobile/Library/Preferences/com.jibeib.xinglanswipe.daemon.status";
static NSString *const XLLogPath =
    @"/var/mobile/Library/Preferences/com.jibeib.xinglanswipe.worker.log";
static volatile sig_atomic_t XLShouldStop = 0;
static pid_t XLWorkerPID = 0;
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

static BOOL XLStartWorker(void) {
    NSFileManager *fileManager = NSFileManager.defaultManager;
    NSString *runtime = jbroot(@"/usr/libexec/XingLanAutoGoRuntime");
    NSString *workerPath = [runtime stringByAppendingPathComponent:@"app"];
    if (![fileManager isExecutableFileAtPath:workerPath]) {
        XLWriteStatus(@"E2");
        return NO;
    }

    if (chdir(runtime.fileSystemRepresentation) != 0) {
        XLWriteStatus([NSString stringWithFormat:@"EC%d", errno]);
        return NO;
    }

    const char *path = workerPath.fileSystemRepresentation;
    char *const arguments[] = {(char *)path, NULL};
    [fileManager removeItemAtPath:XLLogPath error:nil];
    posix_spawn_file_actions_t actions;
    posix_spawn_file_actions_init(&actions);
    posix_spawn_file_actions_addopen(&actions, STDOUT_FILENO,
        XLLogPath.fileSystemRepresentation, O_WRONLY | O_CREAT | O_APPEND, 0644);
    posix_spawn_file_actions_addopen(&actions, STDERR_FILENO,
        XLLogPath.fileSystemRepresentation, O_WRONLY | O_CREAT | O_APPEND, 0644);

    pid_t pid = 0;
    int result = posix_spawn(&pid, path, &actions, NULL, arguments, environ);
    posix_spawn_file_actions_destroy(&actions);
    if (result != 0 || pid <= 0) {
        XLWriteStatus([NSString stringWithFormat:@"E%d", result]);
        return NO;
    }

    XLWorkerPID = pid;
    for (NSUInteger attempt = 0; attempt < 32; attempt++) {
        int childStatus = 0;
        pid_t waitResult = waitpid(pid, &childStatus, WNOHANG);
        if (waitResult == pid || (waitResult < 0 && errno == ECHILD)) {
            XLWorkerPID = 0;
            XLWriteStatus([NSString stringWithFormat:@"EXIT%d", childStatus]);
            return NO;
        }

        NSString *logText = [NSString stringWithContentsOfFile:XLLogPath
                                                       encoding:NSUTF8StringEncoding
                                                          error:nil];
        if ([logText containsString:@"FORMAL_LOOP_STARTED=true"]) {
            XLWriteStatus(@"RUNNING");
            return YES;
        }
        if ([logText containsString:@"FATAL=OCR_INIT_FAILED"]) {
            XLWriteStatus(@"EO");
            return NO;
        }
        usleep(250 * 1000);
    }

    XLWriteStatus(@"EL");
    return NO;
}

static void XLStopWorker(void) {
    if (XLWorkerPID <= 0) return;
    kill(XLWorkerPID, SIGTERM);
    for (NSUInteger attempt = 0; attempt < 20; attempt++) {
        pid_t result = waitpid(XLWorkerPID, NULL, WNOHANG);
        if (result == XLWorkerPID || (result < 0 && errno == ECHILD)) {
            XLWorkerPID = 0;
            return;
        }
        usleep(100 * 1000);
    }
    kill(XLWorkerPID, SIGKILL);
    waitpid(XLWorkerPID, NULL, 0);
    XLWorkerPID = 0;
}

int main(int argc, char **argv) {
    (void)argc;
    (void)argv;
    @autoreleasepool {
        signal(SIGTERM, XLSignalHandler);
        signal(SIGINT, XLSignalHandler);
        XLWriteStatus(@"READY");

        while (!XLShouldStop) {
            if (XLWorkerPID > 0) {
                int childStatus = 0;
                pid_t result = waitpid(XLWorkerPID, &childStatus, WNOHANG);
                if (result == XLWorkerPID || (result < 0 && errno == ECHILD)) {
                    XLWorkerPID = 0;
                    XLWriteStatus([NSString stringWithFormat:@"EXIT%d", childStatus]);
                }
            }

            BOOL enabled = XLWorkerEnabled();
            if (enabled && XLWorkerPID <= 0) {
                (void)XLStartWorker();
            } else if (!enabled && XLWorkerPID > 0) {
                XLStopWorker();
                XLWriteStatus(@"READY");
            } else if (!enabled) {
                XLWriteStatus(@"READY");
            }
            usleep(500 * 1000);
        }

        XLStopWorker();
        XLWriteStatus(@"STOPPED");
    }
    return 0;
}
