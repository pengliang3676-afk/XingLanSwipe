#import "XLBackIconDetector.h"
#import <dlfcn.h>
#import <math.h>
#import <stdlib.h>

typedef UIImage *(*XLCreateScreenImageFn)(void);

static NSString *const XLDetectorErrorDomain = @"com.jibeib.xinglanswipe.detector";
static NSString *const XLModuleBundleIdentifier = @"com.jibeib.xinglanswipe.module";

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

static CGImageRef XLCreateUprightImage(UIImage *sourceImage) {
    if (!sourceImage.CGImage || sourceImage.size.width <= 0.0 ||
        sourceImage.size.height <= 0.0) return nil;
    UIGraphicsBeginImageContextWithOptions(sourceImage.size, YES, sourceImage.scale);
    [sourceImage drawInRect:(CGRect){.origin = CGPointZero, .size = sourceImage.size}];
    UIImage *uprightImage = UIGraphicsGetImageFromCurrentImageContext();
    CGImageRef image = uprightImage.CGImage ? CGImageRetain(uprightImage.CGImage) : nil;
    UIGraphicsEndImageContext();
    return image;
}

static UIImage *XLLoadMyTemplateImage(void) {
    NSBundle *bundle = [NSBundle bundleWithIdentifier:XLModuleBundleIdentifier];
    NSString *path = [bundle pathForResource:@"my_tab" ofType:@"png"];
    if (!path) {
        for (NSBundle *candidate in NSBundle.allBundles) {
            if ([candidate.bundleIdentifier isEqualToString:XLModuleBundleIdentifier] ||
                [candidate.bundlePath.lastPathComponent isEqualToString:
                    @"XingLanSwipeModule.bundle"]) {
                path = [candidate pathForResource:@"my_tab" ofType:@"png"];
                if (path) break;
            }
        }
    }
    if (!path) {
        NSArray<NSString *> *fallbackPaths = @[
            @"/var/jb/Library/ControlCenter/Bundles/XingLanSwipeModule.bundle/my_tab.png",
            @"/Library/ControlCenter/Bundles/XingLanSwipeModule.bundle/my_tab.png"
        ];
        for (NSString *candidate in fallbackPaths) {
            if ([NSFileManager.defaultManager fileExistsAtPath:candidate]) {
                path = candidate;
                break;
            }
        }
    }
    return path ? [UIImage imageWithContentsOfFile:path] : nil;
}

static uint8_t *XLCreateGrayscalePixels(CGImageRef image, size_t width, size_t height) {
    if (!image || width == 0 || height == 0) return NULL;
    uint8_t *pixels = calloc(width * height, sizeof(uint8_t));
    if (!pixels) return NULL;
    CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceGray();
    CGContextRef context = CGBitmapContextCreate(
        pixels, width, height, 8, width, colorSpace, kCGImageAlphaNone);
    CGColorSpaceRelease(colorSpace);
    if (!context) {
        free(pixels);
        return NULL;
    }
    CGContextSetInterpolationQuality(context, kCGInterpolationHigh);
    CGContextTranslateCTM(context, 0.0, (CGFloat)height);
    CGContextScaleCTM(context, 1.0, -1.0);
    CGContextDrawImage(context, CGRectMake(0.0, 0.0, width, height), image);
    CGContextRelease(context);
    return pixels;
}

static double XLCorrelationAt(const uint8_t *screen, size_t screenWidth,
                              const uint8_t *reference, size_t refWidth,
                              size_t refHeight, size_t startX, size_t startY) {
    double screenSum = 0.0, referenceSum = 0.0;
    double screenSquares = 0.0, referenceSquares = 0.0, products = 0.0;
    size_t count = refWidth * refHeight;
    for (size_t y = 0; y < refHeight; y++) {
        const uint8_t *screenRow = screen + (startY + y) * screenWidth + startX;
        const uint8_t *referenceRow = reference + y * refWidth;
        for (size_t x = 0; x < refWidth; x++) {
            double a = screenRow[x];
            double b = referenceRow[x];
            screenSum += a;
            referenceSum += b;
            screenSquares += a * a;
            referenceSquares += b * b;
            products += a * b;
        }
    }
    double screenVariance = screenSquares - screenSum * screenSum / count;
    double referenceVariance = referenceSquares - referenceSum * referenceSum / count;
    if (screenVariance <= 1.0 || referenceVariance <= 1.0) return 0.0;
    double covariance = products - screenSum * referenceSum / count;
    return MAX(0.0, covariance / sqrt(screenVariance * referenceVariance));
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
    CGImageRef screenImage = XLCreateUprightImage(screenshot);
    if (!screenImage) {
        XLSetDetectorError(error, 3, @"screen image unavailable");
        return -1.0;
    }

    UIImage *templateImage = XLLoadMyTemplateImage();
    if (!templateImage.CGImage) {
        CGImageRelease(screenImage);
        XLSetDetectorError(error, 4, @"my template unavailable");
        return -1.0;
    }

    size_t screenWidth = CGImageGetWidth(screenImage);
    size_t screenHeight = CGImageGetHeight(screenImage);
    if (screenWidth == 0 || screenHeight == 0) {
        CGImageRelease(screenImage);
        XLSetDetectorError(error, 5, @"invalid screen dimensions");
        return -1.0;
    }

    double widthScale = (double)screenWidth / 750.0;
    size_t templateWidth = MAX(8, (size_t)lround(86.0 * widthScale));
    size_t templateHeight = MAX(5, (size_t)lround(40.0 * widthScale));
    uint8_t *screenPixels = XLCreateGrayscalePixels(
        screenImage, screenWidth, screenHeight);
    uint8_t *templatePixels = XLCreateGrayscalePixels(
        templateImage.CGImage, templateWidth, templateHeight);
    CGImageRelease(screenImage);
    if (!screenPixels || !templatePixels) {
        free(screenPixels);
        free(templatePixels);
        XLSetDetectorError(error, 6, @"could not prepare grayscale images");
        return -1.0;
    }

    size_t searchStartX = MIN(screenWidth - 1,
        (size_t)lround((double)screenWidth * 0.70));
    // CGBitmapContext exposes the UIKit screenshot rows bottom-up. The visible
    // bottom navigation bar therefore lives in the first 10% of this buffer.
    size_t searchStartY = 0;
    size_t searchEndX = screenWidth > templateWidth ? screenWidth - templateWidth : 0;
    size_t bufferBottomEdge = MIN(screenHeight,
        (size_t)lround((double)screenHeight * 0.10));
    size_t searchEndY = bufferBottomEdge >= templateHeight ?
        bufferBottomEdge - templateHeight : 0;
    if (searchStartX > searchEndX || searchStartY > searchEndY) {
        free(screenPixels);
        free(templatePixels);
        XLSetDetectorError(error, 7, @"screen is smaller than search area");
        return -1.0;
    }

    double bestScore = 0.0;
    size_t bestX = searchStartX, bestY = searchStartY;
    for (size_t y = searchStartY; y <= searchEndY; y += 2) {
        for (size_t x = searchStartX; x <= searchEndX; x += 2) {
            double score = XLCorrelationAt(screenPixels, screenWidth,
                                           templatePixels, templateWidth,
                                           templateHeight, x, y);
            if (score > bestScore) {
                bestScore = score;
                bestX = x;
                bestY = y;
            }
        }
    }

    size_t refineStartX = MAX(searchStartX, bestX > 3 ? bestX - 3 : 0);
    size_t refineStartY = MAX(searchStartY, bestY > 3 ? bestY - 3 : 0);
    size_t refineEndX = MIN(searchEndX, bestX + 3);
    size_t refineEndY = MIN(searchEndY, bestY + 3);
    for (size_t y = refineStartY; y <= refineEndY; y++) {
        for (size_t x = refineStartX; x <= refineEndX; x++) {
            double score = XLCorrelationAt(screenPixels, screenWidth,
                                           templatePixels, templateWidth,
                                           templateHeight, x, y);
            if (score > bestScore) {
                bestScore = score;
                bestX = x;
                bestY = y;
            }
        }
    }

    free(screenPixels);
    free(templatePixels);
    NSLog(@"[XingLanSwipe] local my-template score=%.4f position=%zux%zu screen=%zux%zu template=%zux%zu",
          bestScore, bestX, bestY, screenWidth, screenHeight,
          templateWidth, templateHeight);
    return bestScore;
}

@end
