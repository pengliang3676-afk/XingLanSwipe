#import "XLBackIconDetector.h"
#import <dlfcn.h>
#import <math.h>
#import <stdlib.h>

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

static NSString *const XLEmbeddedProfileTemplate =
@"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";

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

static double XLBestTemplateCorrelation(const uint8_t *screen,
                                        size_t screenWidth,
                                        size_t screenHeight,
                                        const uint8_t *pattern,
                                        size_t patternWidth,
                                        size_t patternHeight) {
    if (!screen || !pattern || patternWidth == 0 || patternHeight == 0 ||
        patternWidth >= screenWidth || patternHeight >= screenHeight) return 0.0;

    const size_t count = patternWidth * patternHeight;
    double patternSum = 0.0;
    double patternSquareSum = 0.0;
    for (size_t index = 0; index < count; index++) {
        double value = pattern[index];
        patternSum += value;
        patternSquareSum += value * value;
    }
    double patternVariance = patternSquareSum - patternSum * patternSum / count;
    if (patternVariance <= 1.0) return 0.0;

    size_t startX = (size_t)floor((double)screenWidth * 0.76);
    size_t startY = (size_t)floor((double)screenHeight * 0.91);
    size_t endX = screenWidth - patternWidth;
    size_t endY = screenHeight - patternHeight;
    if (startX > endX || startY > endY) return 0.0;

    size_t step = MAX((size_t)1, (size_t)lround((double)screenWidth / 375.0));
    double best = -1.0;
    for (size_t y = startY; y <= endY; y += step) {
        for (size_t x = startX; x <= endX; x += step) {
            double imageSum = 0.0;
            double imageSquareSum = 0.0;
            double productSum = 0.0;
            for (size_t row = 0; row < patternHeight; row++) {
                const uint8_t *screenRow = screen + (y + row) * screenWidth + x;
                const uint8_t *patternRow = pattern + row * patternWidth;
                for (size_t column = 0; column < patternWidth; column++) {
                    double imageValue = screenRow[column];
                    double patternValue = patternRow[column];
                    imageSum += imageValue;
                    imageSquareSum += imageValue * imageValue;
                    productSum += imageValue * patternValue;
                }
            }

            double imageVariance = imageSquareSum - imageSum * imageSum / count;
            if (imageVariance <= 1.0) continue;
            double covariance = productSum - imageSum * patternSum / count;
            double correlation = covariance / sqrt(imageVariance * patternVariance);
            if (correlation > best) best = correlation;
        }
    }
    return MAX(0.0, best);
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

    NSData *templateData = [[NSData alloc]
        initWithBase64EncodedString:XLEmbeddedProfileTemplate options:0];
    UIImage *templateImage = templateData ? [UIImage imageWithData:templateData] : nil;
    if (!templateImage.CGImage) {
        CGImageRelease(screenImage);
        XLSetDetectorError(error, 4, @"profile template unavailable");
        return -1.0;
    }

    size_t screenWidth = CGImageGetWidth(screenImage);
    size_t screenHeight = CGImageGetHeight(screenImage);
    double scale = (double)screenWidth / 750.0;
    uint8_t *screenPixels = XLCreateGrayscalePixels(
        screenImage, screenWidth, screenHeight);
    CGImageRelease(screenImage);
    if (!screenPixels) {
        free(screenPixels);
        XLSetDetectorError(error, 5, @"could not prepare images for matching");
        return -1.0;
    }

    // The app can render its tab text at slightly different effective sizes on
    // different display modes. Search several nearby scales instead of
    // requiring one pixel-exact size.
    static const double scaleAdjustments[] = {0.84, 0.92, 1.00, 1.08, 1.16};
    double score = 0.0;
    size_t bestWidth = 0;
    size_t bestHeight = 0;
    for (size_t index = 0;
         index < sizeof(scaleAdjustments) / sizeof(scaleAdjustments[0]);
         index++) {
        double candidateScale = scale * scaleAdjustments[index];
        size_t templateWidth = MAX((size_t)24,
            (size_t)lround((double)CGImageGetWidth(templateImage.CGImage) *
                           candidateScale));
        size_t templateHeight = MAX((size_t)12,
            (size_t)lround((double)CGImageGetHeight(templateImage.CGImage) *
                           candidateScale));
        uint8_t *templatePixels = XLCreateGrayscalePixels(
            templateImage.CGImage, templateWidth, templateHeight);
        if (!templatePixels) continue;
        double candidateScore = XLBestTemplateCorrelation(
            screenPixels, screenWidth, screenHeight,
            templatePixels, templateWidth, templateHeight);
        free(templatePixels);
        if (candidateScore > score) {
            score = candidateScore;
            bestWidth = templateWidth;
            bestHeight = templateHeight;
        }
    }
    free(screenPixels);
    NSLog(@"[XingLanSwipe] embedded profile template score %.4f at %zux%zu "
           "using %zux%zu template",
          score, screenWidth, screenHeight, bestWidth, bestHeight);
    return score;
}

@end
