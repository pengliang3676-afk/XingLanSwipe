#import "XLBackIconDetector.h"
#import <Vision/Vision.h>
#import <dlfcn.h>

typedef UIImage *(*XLCreateScreenImageFn)(void);

static NSString *const XLDetectorErrorDomain = @"com.jibeib.xinglanswipe.detector";

static void XLSetDetectorError(NSError **error, NSInteger code, NSString *message) {
    if (!error) return;
    *error = [NSError errorWithDomain:XLDetectorErrorDomain
                                 code:code
                             userInfo:@{NSLocalizedDescriptionKey: message}];
}

static XLCreateScreenImageFn XLScreenCaptureFunction(void) {
    static XLCreateScreenImageFn function;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        function = (XLCreateScreenImageFn)dlsym(RTLD_DEFAULT, "_UICreateScreenUIImage");
        if (function) return;
        void *handle = dlopen(
            "/System/Library/PrivateFrameworks/UIKitCore.framework/UIKitCore",
            RTLD_LAZY | RTLD_LOCAL);
        if (handle) {
            function = (XLCreateScreenImageFn)dlsym(handle, "_UICreateScreenUIImage");
        }
    });
    return function;
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

- (BOOL)containsMyTextInScreenshot:(UIImage *)screenshot error:(NSError **)error {
    CGImageRef screen = screenshot.CGImage;
    if (!screen) {
        XLSetDetectorError(error, 3, @"screen image unavailable");
        return NO;
    }

    size_t screenWidth = CGImageGetWidth(screen);
    size_t screenHeight = CGImageGetHeight(screen);
    if (screenWidth == 0 || screenHeight == 0) {
        XLSetDetectorError(error, 4, @"invalid screen dimensions");
        return NO;
    }

    // The confirmed device is 750x1334. Keep the same bottom-right OCR region
    // proportionally so Retina scale does not change the area being recognized.
    size_t cropX = MIN(screenWidth - 1,
        (size_t)((double)screenWidth * 520.0 / 750.0));
    size_t cropY = MIN(screenHeight - 1,
        (size_t)((double)screenHeight * 1130.0 / 1334.0));
    CGRect cropRect = CGRectMake(
        (CGFloat)cropX,
        (CGFloat)cropY,
        (CGFloat)(screenWidth - cropX),
        (CGFloat)(screenHeight - cropY));
    CGImageRef crop = CGImageCreateWithImageInRect(screen, cropRect);
    if (!crop) {
        XLSetDetectorError(error, 5, @"could not crop OCR region");
        return NO;
    }

    __block BOOL found = NO;
    __block NSError *recognitionError = nil;
    VNRecognizeTextRequest *request =
        [[VNRecognizeTextRequest alloc] initWithCompletionHandler:
            ^(VNRequest *completedRequest, NSError *requestError) {
                if (requestError) {
                    recognitionError = requestError;
                    return;
                }
                for (VNRecognizedTextObservation *observation in completedRequest.results) {
                    VNRecognizedText *candidate = [observation topCandidates:1].firstObject;
                    NSString *text = candidate.string ?: @"";
                    NSString *compact = [[text stringByReplacingOccurrencesOfString:@" " withString:@""]
                        stringByReplacingOccurrencesOfString:@"\n" withString:@""];
                    NSLog(@"[XingLanSwipe] Vision OCR text=%@", compact);
                    if ([compact containsString:@"我的"]) {
                        found = YES;
                        break;
                    }
                }
            }];
    request.recognitionLevel = VNRequestTextRecognitionLevelAccurate;
    request.usesLanguageCorrection = YES;
    request.recognitionLanguages = @[@"zh-Hans", @"zh-Hant"];
    request.minimumTextHeight = 0.025;

    VNImageRequestHandler *handler =
        [[VNImageRequestHandler alloc] initWithCGImage:crop options:@{}];
    BOOL performed = [handler performRequests:@[request] error:&recognitionError];
    CGImageRelease(crop);

    if (!performed || recognitionError) {
        if (error) {
            *error = recognitionError ?: [NSError errorWithDomain:XLDetectorErrorDomain
                                                              code:6
                                                          userInfo:@{
                    NSLocalizedDescriptionKey: @"Vision OCR request failed"
                }];
        }
        return NO;
    }

    NSLog(@"[XingLanSwipe] Vision OCR MY_FOUND=%@", found ? @"true" : @"false");
    return found;
}

@end
