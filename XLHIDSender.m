#import "XLHIDSender.h"
#import <dlfcn.h>
#import <mach/mach_time.h>
#import <unistd.h>

typedef CFTypeRef IOHIDEventRef;
typedef CFTypeRef IOHIDEventSystemClientRef;

typedef IOHIDEventSystemClientRef (*ClientCreateFn)(CFAllocatorRef allocator);
typedef void (*DispatchEventFn)(IOHIDEventSystemClientRef client, IOHIDEventRef event);
typedef void (*AppendEventFn)(IOHIDEventRef parent, IOHIDEventRef child, uint32_t options);
typedef void (*SetIntegerValueFn)(IOHIDEventRef event, uint32_t field, CFIndex value);
typedef void (*SetFloatValueFn)(IOHIDEventRef event, uint32_t field, double value);
typedef void (*SetSenderIDFn)(IOHIDEventRef event, uint64_t senderID);
typedef IOHIDEventRef (*DigitizerEventFn)(CFAllocatorRef, uint64_t, uint32_t,
    uint32_t, uint32_t, uint32_t, uint32_t, double, double, double, double,
    double, bool, bool, uint32_t);
typedef IOHIDEventRef (*FingerEventFn)(CFAllocatorRef, uint64_t, uint32_t,
    uint32_t, uint32_t, double, double, double, double, double, bool, bool,
    uint32_t);

static const uint32_t XLRange = 1u << 0;
static const uint32_t XLTouch = 1u << 1;
static const uint32_t XLPosition = 1u << 2;
static const uint32_t XLMajorRadius = 0xB0014;
static const uint32_t XLMinorRadius = 0xB0015;
static const uint32_t XLDisplayIntegrated = 0xB0019;

typedef NS_ENUM(NSInteger, XLTouchPhase) {
    XLTouchPhaseDown,
    XLTouchPhaseMove,
    XLTouchPhaseUp
};

@implementation XLHIDSender {
    void *_ioKit;
    IOHIDEventSystemClientRef _client;
    ClientCreateFn _createClient;
    DispatchEventFn _dispatch;
    AppendEventFn _append;
    SetIntegerValueFn _setInteger;
    SetFloatValueFn _setFloat;
    SetSenderIDFn _setSenderID;
    DigitizerEventFn _createDigitizer;
    FingerEventFn _createFinger;
    dispatch_queue_t _queue;
}

- (instancetype)init {
    self = [super init];
    if (!self) return nil;
    _queue = dispatch_queue_create("com.jibeib.xinglanswipe.hid", DISPATCH_QUEUE_SERIAL);
    _ioKit = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW);
    if (_ioKit) {
        _createClient = (ClientCreateFn)dlsym(_ioKit, "IOHIDEventSystemClientCreate");
        _dispatch = (DispatchEventFn)dlsym(_ioKit, "IOHIDEventSystemClientDispatchEvent");
        _append = (AppendEventFn)dlsym(_ioKit, "IOHIDEventAppendEvent");
        _setInteger = (SetIntegerValueFn)dlsym(_ioKit, "IOHIDEventSetIntegerValue");
        _setFloat = (SetFloatValueFn)dlsym(_ioKit, "IOHIDEventSetFloatValue");
        _setSenderID = (SetSenderIDFn)dlsym(_ioKit, "IOHIDEventSetSenderID");
        _createDigitizer = (DigitizerEventFn)dlsym(_ioKit, "IOHIDEventCreateDigitizerEvent");
        _createFinger = (FingerEventFn)dlsym(_ioKit, "IOHIDEventCreateDigitizerFingerEvent");
        if (_createClient) _client = _createClient(kCFAllocatorDefault);
    }
    return self;
}

- (void)dealloc {
    if (_client) CFRelease(_client);
    if (_ioKit) dlclose(_ioKit);
}

- (BOOL)ready {
    return _client && _dispatch && _append && _setInteger && _setFloat &&
        _setSenderID &&
        _createDigitizer && _createFinger;
}

- (BOOL)sendX:(double)x y:(double)y phase:(XLTouchPhase)phase {
    if (![self ready]) return NO;
    BOOL touching = phase != XLTouchPhaseUp;
    uint32_t childMask = 0;
    switch (phase) {
        case XLTouchPhaseDown:
            childMask = XLTouch | XLRange;
            break;
        case XLTouchPhaseMove:
            childMask = XLPosition;
            break;
        case XLTouchPhaseUp:
            childMask = XLTouch;
            break;
    }
    uint64_t timestamp = mach_absolute_time();

    IOHIDEventRef parent = _createDigitizer(kCFAllocatorDefault, timestamp,
        3, 99, 1, 0, 0, 0, 0, 0, 0, 0, false, false, 0);
    IOHIDEventRef finger = _createFinger(kCFAllocatorDefault, timestamp,
        1, 3, childMask, x, y, 0, touching ? 1.0 : 0.0, 0,
        touching, touching, 0);
    if (!parent || !finger) {
        if (parent) CFRelease(parent);
        if (finger) CFRelease(finger);
        return NO;
    }

    _setInteger(parent, XLDisplayIntegrated, 1);
    _setInteger(parent, 0x4, 1);
    _setInteger(finger, XLDisplayIntegrated, 1);
    _setFloat(finger, XLMajorRadius, 0.04);
    _setFloat(finger, XLMinorRadius, 0.04);
    _append(parent, finger, 0);
    // TrollVNC uses this BackBoard-compatible sender identity. Without it,
    // dispatch may return normally while the foreground app ignores the event.
    _setSenderID(parent, 0x8000000817319371ULL);
    _dispatch(_client, parent);
    CFRelease(finger);
    CFRelease(parent);
    return YES;
}

static double XLRandom(double minimum, double maximum) {
    return minimum + ((double)arc4random_uniform(10001) / 10000.0) *
        (maximum - minimum);
}

- (void)performNaturalUpSwipeWithCompletion:(XLHIDCompletion)completion {
    dispatch_async(_queue, ^{
        if (![self ready]) {
            dispatch_async(dispatch_get_main_queue(), ^{
                if (completion) completion(NO);
            });
            return;
        }

        // Keep the gesture in the central content area so app buttons, edge
        // gestures and horizontal carousels are less likely to consume it.
        double startX = XLRandom(0.47, 0.53);
        double startY = XLRandom(0.82, 0.87);
        double endX = XLRandom(0.47, 0.53);
        double endY = XLRandom(0.20, 0.27);
        double controlOffset = XLRandom(-0.018, 0.018);
        double duration = 0.30;
        NSInteger steps = 30;
        BOOL success = [self sendX:startX y:startY phase:XLTouchPhaseDown];
        if (success) usleep(30000 + arc4random_uniform(18001));

        for (NSInteger i = 1; success && i <= steps; i++) {
            double t = (double)i / (double)steps;
            double eased = t * t * (3.0 - 2.0 * t);
            double curve = 4.0 * t * (1.0 - t) * controlOffset;
            double x = startX + (endX - startX) * eased + curve;
            double y = startY + (endY - startY) * eased;
            success = [self sendX:x y:y phase:XLTouchPhaseMove];
            usleep((useconds_t)((duration / (double)steps) * 1000000.0));
        }
        if (success) {
            usleep(12000 + arc4random_uniform(9001));
            success = [self sendX:endX y:endY phase:XLTouchPhaseUp];
        }

        dispatch_async(dispatch_get_main_queue(), ^{
            if (completion) completion(success);
        });
    });
}

@end
