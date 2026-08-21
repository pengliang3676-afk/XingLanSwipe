#import "XLAXBackDetector.h"

#import <UIKit/UIKit.h>
#import <dlfcn.h>
#import <unistd.h>

typedef const struct __XLAXUIElement *XLAXUIElementRef;
typedef int32_t XLAXError;

enum {
    XLAXErrorSuccess = 0,
};

typedef XLAXUIElementRef (*XLAXCreateApplicationFunc)(pid_t pid);
typedef XLAXUIElementRef (*XLAXCreateSystemWideFunc)(void);
typedef XLAXError (*XLAXCopyAttributeValueFunc)(XLAXUIElementRef element,
                                                CFStringRef attribute,
                                                CFTypeRef *value);
// iOS AXRuntime uses the out-element as the second argument.
typedef XLAXError (*XLAXCopyElementAtPositionFunc)(XLAXUIElementRef application,
                                                   XLAXUIElementRef *element,
                                                   float x,
                                                   float y);
typedef XLAXError (*XLAXCopyElementAtPositionWithParamsFunc)(XLAXUIElementRef application,
                                                             XLAXUIElementRef *element,
                                                             int flags,
                                                             float x,
                                                             float y);
typedef XLAXError (*XLAXCopyApplicationAndContextAtPositionFunc)(
    XLAXUIElementRef application,
    XLAXUIElementRef *element,
    uint32_t *contextId,
    float x,
    float y);
typedef XLAXError (*XLAXCopyElementUsingContextIdAtPositionFunc)(
    XLAXUIElementRef application,
    uint32_t contextId,
    XLAXUIElementRef *element,
    int options,
    float x,
    float y);
typedef XLAXError (*XLAXSetMessagingTimeoutFunc)(XLAXUIElementRef element, float timeout);
typedef XLAXError (*XLAXGetPidFunc)(XLAXUIElementRef element, pid_t *pid);
typedef void (*XLAXAddAssociatedPidFunc)(pid_t pid, pid_t associatedPid, int displayType);
typedef bool (*XLAXIsPidAssociatedFunc)(pid_t pid);
typedef bool (*XLAXIsPidAssociatedWithDisplayTypeFunc)(pid_t pid, int displayType);
typedef void (*XLAXSetRequestingClientFunc)(uint32_t clientType);

typedef struct {
    BOOL available;
    XLAXCreateApplicationFunc createApplication;
    XLAXCreateSystemWideFunc createSystemWide;
    XLAXCopyAttributeValueFunc copyAttributeValue;
    XLAXCopyElementAtPositionFunc copyElementAtPosition;
    XLAXCopyElementAtPositionWithParamsFunc copyElementAtPositionWithParams;
    XLAXCopyApplicationAndContextAtPositionFunc copyApplicationAndContextAtPosition;
    XLAXCopyElementUsingContextIdAtPositionFunc copyElementUsingContextIdAtPosition;
    XLAXSetMessagingTimeoutFunc setMessagingTimeout;
    XLAXGetPidFunc getPid;
    XLAXAddAssociatedPidFunc addAssociatedPid;
    XLAXIsPidAssociatedFunc isPidAssociated;
    XLAXIsPidAssociatedWithDisplayTypeFunc isPidAssociatedWithDisplayType;
    XLAXSetRequestingClientFunc setRequestingClient;
} XLAXRuntime;

static XLAXRuntime xlAXRuntime;

static BOOL XLAXBindRuntimeFromHandle(void *handle) {
    if (!handle) return NO;

    XLAXCreateApplicationFunc createApplication =
        (XLAXCreateApplicationFunc)dlsym(handle, "AXUIElementCreateApplication");
    if (!createApplication) {
        createApplication =
            (XLAXCreateApplicationFunc)dlsym(handle, "_AXUIElementCreateAppElementWithPid");
    }
    XLAXCreateSystemWideFunc createSystemWide =
        (XLAXCreateSystemWideFunc)dlsym(handle, "AXUIElementCreateSystemWide");
    XLAXCopyAttributeValueFunc copyAttributeValue =
        (XLAXCopyAttributeValueFunc)dlsym(handle, "AXUIElementCopyAttributeValue");
    XLAXCopyElementAtPositionFunc copyElementAtPosition =
        (XLAXCopyElementAtPositionFunc)dlsym(handle, "AXUIElementCopyElementAtPosition");
    XLAXCopyElementAtPositionWithParamsFunc copyElementAtPositionWithParams =
        (XLAXCopyElementAtPositionWithParamsFunc)dlsym(
            handle, "AXUIElementCopyElementAtPositionWithParams");
    XLAXCopyApplicationAndContextAtPositionFunc copyApplicationAndContextAtPosition =
        (XLAXCopyApplicationAndContextAtPositionFunc)dlsym(
            handle, "AXUIElementCopyApplicationAndContextAtPosition");
    XLAXCopyElementUsingContextIdAtPositionFunc copyElementUsingContextIdAtPosition =
        (XLAXCopyElementUsingContextIdAtPositionFunc)dlsym(
            handle, "AXUIElementCopyElementUsingContextIdAtPosition");

    BOOL hasSeed = createApplication || createSystemWide;
    BOOL hasContextHitTest = copyApplicationAndContextAtPosition &&
        copyElementUsingContextIdAtPosition;
    BOOL hasHitTest = copyElementAtPosition || copyElementAtPositionWithParams ||
        hasContextHitTest;
    if (!hasSeed || !hasHitTest || !copyAttributeValue) return NO;

    xlAXRuntime.createApplication = createApplication;
    xlAXRuntime.createSystemWide = createSystemWide;
    xlAXRuntime.copyAttributeValue = copyAttributeValue;
    xlAXRuntime.copyElementAtPosition = copyElementAtPosition;
    xlAXRuntime.copyElementAtPositionWithParams = copyElementAtPositionWithParams;
    xlAXRuntime.copyApplicationAndContextAtPosition =
        copyApplicationAndContextAtPosition;
    xlAXRuntime.copyElementUsingContextIdAtPosition =
        copyElementUsingContextIdAtPosition;
    xlAXRuntime.setMessagingTimeout =
        (XLAXSetMessagingTimeoutFunc)dlsym(handle, "AXUIElementSetMessagingTimeout");
    xlAXRuntime.getPid = (XLAXGetPidFunc)dlsym(handle, "AXUIElementGetPid");
    xlAXRuntime.addAssociatedPid =
        (XLAXAddAssociatedPidFunc)dlsym(handle, "_AXAddAssociatedPid");
    xlAXRuntime.isPidAssociated =
        (XLAXIsPidAssociatedFunc)dlsym(handle, "_AXIsPidAssociated");
    xlAXRuntime.isPidAssociatedWithDisplayType =
        (XLAXIsPidAssociatedWithDisplayTypeFunc)dlsym(
            handle, "_AXIsPidAssociatedWithDisplayType");
    xlAXRuntime.setRequestingClient =
        (XLAXSetRequestingClientFunc)dlsym(handle, "__AXSetRequestingClient");
    xlAXRuntime.available = YES;
    return YES;
}

static BOOL XLAXEnsureRuntime(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        if (XLAXBindRuntimeFromHandle(RTLD_DEFAULT)) return;

        const char *paths[] = {
            "/System/Library/PrivateFrameworks/AXRuntime.framework/AXRuntime",
            "/System/Library/Frameworks/Accessibility.framework/Accessibility",
            "/System/Library/PrivateFrameworks/Accessibility.framework/Accessibility",
            "/System/Library/Frameworks/ApplicationServices.framework/Frameworks/HIServices.framework/HIServices",
            "/usr/lib/libAccessibility.dylib",
        };
        for (size_t index = 0; index < sizeof(paths) / sizeof(paths[0]); index++) {
            void *handle = dlopen(paths[index], RTLD_NOW | RTLD_GLOBAL);
            if (handle && XLAXBindRuntimeFromHandle(handle)) return;
        }
    });
    return xlAXRuntime.available;
}

static void XLAXPrepareRemotePid(pid_t remotePid) {
    if (xlAXRuntime.setRequestingClient) xlAXRuntime.setRequestingClient(2);
    if (remotePid <= 0 || !xlAXRuntime.addAssociatedPid ||
        !xlAXRuntime.isPidAssociated) return;

    pid_t localPid = getpid();
    BOOL remoteAssociated = xlAXRuntime.isPidAssociated(remotePid);
    BOOL localAssociated = xlAXRuntime.isPidAssociated(localPid);
    BOOL remoteDisplayAssociated = xlAXRuntime.isPidAssociatedWithDisplayType
        ? xlAXRuntime.isPidAssociatedWithDisplayType(remotePid, 1)
        : remoteAssociated;
    BOOL localDisplayAssociated = xlAXRuntime.isPidAssociatedWithDisplayType
        ? xlAXRuntime.isPidAssociatedWithDisplayType(localPid, 1)
        : localAssociated;

    if (!remoteDisplayAssociated) xlAXRuntime.addAssociatedPid(localPid, remotePid, 1);
    if (!localDisplayAssociated) xlAXRuntime.addAssociatedPid(remotePid, localPid, 1);
    if (!remoteAssociated) xlAXRuntime.addAssociatedPid(localPid, remotePid, 0);
    if (!localAssociated) xlAXRuntime.addAssociatedPid(remotePid, localPid, 0);
}

static NSString *XLAXCopyStringAttribute(XLAXUIElementRef element,
                                         CFStringRef attribute) {
    if (!element || !xlAXRuntime.copyAttributeValue) return nil;
    CFTypeRef value = NULL;
    XLAXError error = xlAXRuntime.copyAttributeValue(element, attribute, &value);
    if (error != XLAXErrorSuccess || !value) {
        if (value) CFRelease(value);
        return nil;
    }
    id object = CFBridgingRelease(value);
    if ([object isKindOfClass:NSString.class]) return object;
    if ([object respondsToSelector:@selector(stringValue)]) return [object stringValue];
    return nil;
}

static NSNumber *XLAXCopyNumberAttribute(XLAXUIElementRef element,
                                         CFStringRef attribute) {
    if (!element || !xlAXRuntime.copyAttributeValue) return nil;
    CFTypeRef value = NULL;
    XLAXError error = xlAXRuntime.copyAttributeValue(element, attribute, &value);
    if (error != XLAXErrorSuccess || !value) {
        if (value) CFRelease(value);
        return nil;
    }
    id object = CFBridgingRelease(value);
    return [object isKindOfClass:NSNumber.class] ? object : nil;
}

static BOOL XLAXLabelIsBaidu(NSString *label) {
    NSString *trimmed = [label stringByTrimmingCharactersInSet:
        NSCharacterSet.whitespaceAndNewlineCharacterSet];
    return [trimmed isEqualToString:@"百度"] ||
        [trimmed isEqualToString:@"百度按钮"];
}

static BOOL XLAXElementIsBaiduButton(XLAXUIElementRef element,
                                     NSString **diagnostic) {
    NSString *label = XLAXCopyStringAttribute(element, CFSTR("AXLabel"));
    NSString *role = XLAXCopyStringAttribute(element, CFSTR("AXRole"));
    NSNumber *traits = XLAXCopyNumberAttribute(element, CFSTR("AXTraits"));
    BOOL buttonRole = role.length > 0 &&
        [role rangeOfString:@"button"
                    options:NSCaseInsensitiveSearch].location != NSNotFound;
    BOOL buttonTrait = traits &&
        ((traits.unsignedLongLongValue & UIAccessibilityTraitButton) != 0);
    if (diagnostic) {
        *diagnostic = [NSString stringWithFormat:@"label=%@ role=%@ traits=%@",
            label ?: @"(nil)", role ?: @"(nil)", traits ?: @"(nil)"];
    }
    return XLAXLabelIsBaidu(label) && (buttonRole || buttonTrait);
}

static XLAXUIElementRef XLAXCreateSeed(pid_t expectedPid) {
    XLAXUIElementRef seed = NULL;
    if (expectedPid > 0 && xlAXRuntime.createApplication) {
        seed = xlAXRuntime.createApplication(expectedPid);
    }
    if (!seed && xlAXRuntime.createSystemWide) {
        seed = xlAXRuntime.createSystemWide();
    }
    if (seed && xlAXRuntime.setMessagingTimeout) {
        xlAXRuntime.setMessagingTimeout(seed, 0.20f);
    }
    return seed;
}

static XLAXUIElementRef XLAXCopyContextHitElement(CGPoint point,
                                                   pid_t expectedPid,
                                                   NSString **diagnostic) {
    if (!xlAXRuntime.copyApplicationAndContextAtPosition ||
        !xlAXRuntime.copyElementUsingContextIdAtPosition) return NULL;

    XLAXUIElementRef seeds[3] = { NULL, NULL, NULL };
    const char *seedNames[3] = { "pid0", "system", "springboard" };
    if (xlAXRuntime.createApplication) {
        seeds[0] = xlAXRuntime.createApplication(0);
    }
    if (xlAXRuntime.createSystemWide) {
        seeds[1] = xlAXRuntime.createSystemWide();
    }
    if (xlAXRuntime.createApplication) {
        seeds[2] = xlAXRuntime.createApplication(getpid());
    }

    XLAXError lastError = -1;
    for (NSUInteger seedIndex = 0; seedIndex < 3; seedIndex++) {
        XLAXUIElementRef seed = seeds[seedIndex];
        if (!seed) continue;
        if (xlAXRuntime.setMessagingTimeout) {
            xlAXRuntime.setMessagingTimeout(seed, 0.20f);
        }

        XLAXUIElementRef appElement = NULL;
        uint32_t contextId = 0;
        XLAXError appError = xlAXRuntime.copyApplicationAndContextAtPosition(
            seed, &appElement, &contextId, point.x, point.y);
        lastError = appError;
        if (appError != XLAXErrorSuccess || !appElement || contextId == 0) {
            if (appElement) CFRelease(appElement);
            continue;
        }
        if (xlAXRuntime.setMessagingTimeout) {
            xlAXRuntime.setMessagingTimeout(appElement, 0.20f);
        }

        if (expectedPid > 0 && xlAXRuntime.getPid) {
            pid_t resolvedPid = 0;
            XLAXError pidError = xlAXRuntime.getPid(appElement, &resolvedPid);
            if (pidError == XLAXErrorSuccess && resolvedPid > 0 &&
                resolvedPid != expectedPid) {
                CFRelease(appElement);
                continue;
            }
        }

        for (int option = 0; option <= 2; option++) {
            XLAXUIElementRef hitElement = NULL;
            XLAXError hitError = xlAXRuntime.copyElementUsingContextIdAtPosition(
                appElement, contextId, &hitElement, option, point.x, point.y);
            lastError = hitError;
            if (hitError == XLAXErrorSuccess && hitElement) {
                if (xlAXRuntime.setMessagingTimeout) {
                    xlAXRuntime.setMessagingTimeout(hitElement, 0.20f);
                }
                CFRelease(appElement);
                for (NSUInteger releaseIndex = 0; releaseIndex < 3; releaseIndex++) {
                    if (seeds[releaseIndex]) CFRelease(seeds[releaseIndex]);
                }
                if (diagnostic) {
                    *diagnostic = [NSString stringWithFormat:
                        @"context seed=%s ctx=%u option=%d",
                        seedNames[seedIndex], contextId, option];
                }
                return hitElement;
            }
            if (hitElement) CFRelease(hitElement);
        }
        CFRelease(appElement);
    }

    for (NSUInteger releaseIndex = 0; releaseIndex < 3; releaseIndex++) {
        if (seeds[releaseIndex]) CFRelease(seeds[releaseIndex]);
    }
    if (diagnostic) {
        *diagnostic = [NSString stringWithFormat:@"context hit-test error=%d",
            (int)lastError];
    }
    return NULL;
}

@implementation XLAXBackDetector

- (XLAXBackDetectionResult)detectBaiduBackButtonAtNormalizedX:(double)x
                                                           y:(double)y
                                                 expectedPid:(pid_t)expectedPid
                                                  diagnostic:(NSString **)diagnostic {
    if (!XLAXEnsureRuntime()) {
        if (diagnostic) *diagnostic = @"AX runtime unavailable";
        return XLAXBackDetectionUnavailable;
    }

    XLAXPrepareRemotePid(expectedPid);
    XLAXUIElementRef seed = XLAXCreateSeed(expectedPid);
    if (!seed) {
        if (diagnostic) *diagnostic = @"AX seed unavailable";
        return XLAXBackDetectionUnavailable;
    }

    CGSize screenSize = UIScreen.mainScreen.bounds.size;
    CGPoint point = CGPointMake(screenSize.width * x, screenSize.height * y);
    NSString *contextDiagnostic = nil;
    XLAXUIElementRef hitElement = XLAXCopyContextHitElement(
        point, expectedPid, &contextDiagnostic);
    XLAXError hitError = hitElement ? XLAXErrorSuccess : -1;
    if (!hitElement && xlAXRuntime.copyElementAtPositionWithParams) {
        hitError = xlAXRuntime.copyElementAtPositionWithParams(
            seed, &hitElement, 1, point.x, point.y);
    }
    if ((hitError != XLAXErrorSuccess || !hitElement) &&
        xlAXRuntime.copyElementAtPosition) {
        if (hitElement) {
            CFRelease(hitElement);
            hitElement = NULL;
        }
        hitError = xlAXRuntime.copyElementAtPosition(
            seed, &hitElement, point.x, point.y);
    }
    CFRelease(seed);

    if (hitError != XLAXErrorSuccess || !hitElement) {
        if (hitElement) CFRelease(hitElement);
        if (diagnostic) {
            *diagnostic = [NSString stringWithFormat:@"%@; direct error=%d",
                contextDiagnostic ?: @"context unavailable", (int)hitError];
        }
        return XLAXBackDetectionNotFound;
    }

    if (xlAXRuntime.setMessagingTimeout) {
        xlAXRuntime.setMessagingTimeout(hitElement, 0.20f);
    }
    if (expectedPid > 0 && xlAXRuntime.getPid) {
        pid_t hitPid = 0;
        XLAXError pidError = xlAXRuntime.getPid(hitElement, &hitPid);
        if (pidError == XLAXErrorSuccess && hitPid > 0 && hitPid != expectedPid) {
            CFRelease(hitElement);
            if (diagnostic) {
                *diagnostic = [NSString stringWithFormat:@"AX hit pid=%d expected=%d",
                    hitPid, expectedPid];
            }
            return XLAXBackDetectionNotFound;
        }
    }

    NSString *elementDiagnostic = nil;
    BOOL found = XLAXElementIsBaiduButton(hitElement, &elementDiagnostic);
    CFRelease(hitElement);
    if (diagnostic) {
        *diagnostic = [NSString stringWithFormat:@"%@; %@",
            contextDiagnostic ?: @"direct", elementDiagnostic ?: @""];
    }
    return found ? XLAXBackDetectionFound : XLAXBackDetectionNotFound;
}

@end
