#import "XLBackIconDetector.h"
#import <Vision/Vision.h>
#import <dlfcn.h>

typedef UIImage *(*XLCreateScreenImageFn)(void);

static NSString *const XLDetectorErrorDomain = @"com.jibeib.xinglanswipe.detector";

static void XLSetDetectorError(NSError **error, NSInteger code, NSString *message) {
    if (!error) return;
    *error = [NSError errorWithDomain:XLDetectorErrorDomain code:code
                              userInfo:@{NSLocalizedDescriptionKey: message}];
}

static XLCreateScreenImageFn XLScreenCaptureFunction(void) {
    static XLCreateScreenImageFn function;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        function = (XLCreateScreenImageFn)dlsym(RTLD_DEFAULT, "_UICreateScreenUIImage");
        if (function) return;
        void *handle = dlopen("/System/Library/PrivateFrameworks/UIKitCore.framework/UIKitCore",
                              RTLD_LAZY | RTLD_LOCAL);
        if (handle) function = (XLCreateScreenImageFn)dlsym(handle, "_UICreateScreenUIImage");
    });
    return function;
}

static BOOL XLIsLowerRightText(VNRecognizedTextObservation *observation) {
    CGRect box = observation.boundingBox;
    return CGRectGetMidX(box) >= 0.72 && CGRectGetMidY(box) <= 0.14;
}

@implementation XLBackIconDetector

- (UIImage *)captureScreenWithError:(NSError **)error {
    NSAssert(NSThread.isMainThread, @"capture must run on the main thread");
    XLCreateScreenImageFn function = XLScreenCaptureFunction();
    if (!function) {
        XLSetDetectorError(error, 1, @"screen capture function unavailable");
        return nil;
    }
    UIImage *image = function();
    if (!image.CGImage) {
        XLSetDetectorError(error, 2, @"screen capture returned no image");
        return nil;
    }
    return image;
}

- (double)matchScoreForScreenshot:(UIImage *)screenshot error:(NSError **)error {
    if (!screenshot.CGImage) {
        XLSetDetectorError(error, 3, @"screenshot image unavailable");
        return -1.0;
    }

    VNRecognizeTextRequest *request = [VNRecognizeTextRequest new];
    request.recognitionLevel = VNRequestTextRecognitionLevelAccurate;
    request.recognitionLanguages = @[@"zh-Hans"];
    request.customWords = @[@"我的"];
    request.usesLanguageCorrection = NO;
    request.minimumTextHeight = 0.008;

    VNImageRequestHandler *handler = [[VNImageRequestHandler alloc]
        initWithCGImage:screenshot.CGImage options:@{}];
    NSError *visionError = nil;
    if (![handler performRequests:@[request] error:&visionError]) {
        XLSetDetectorError(error, 4,
                           visionError.localizedDescription ?: @"text recognition failed");
        return -1.0;
    }

    for (VNRecognizedTextObservation *observation in request.results) {
        if (!XLIsLowerRightText(observation)) continue;
        for (VNRecognizedText *candidate in [observation topCandidates:3]) {
            NSString *text = [[candidate.string
                stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet]
                stringByReplacingOccurrencesOfString:@" " withString:@""];
            if ([text containsString:@"我的"]) return 1.0;
        }
    }
    return 0.0;
}

@end
