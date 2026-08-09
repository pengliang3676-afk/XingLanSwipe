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

static NSString *XLTemplatePath(void) {
    NSMutableArray<NSString *> *candidates = [NSMutableArray array];
    Dl_info info = {0};
    if (dladdr((const void *)&XLTemplatePath, &info) != 0 && info.dli_fname) {
        NSString *dylibPath = [NSString stringWithUTF8String:info.dli_fname];
        NSString *marker = @"/Library/MobileSubstrate/DynamicLibraries/";
        NSRange range = [dylibPath rangeOfString:marker];
        if (range.location != NSNotFound) {
            NSString *prefix = [dylibPath substringToIndex:range.location];
            [candidates addObject:[prefix stringByAppendingString:
                @"/Library/ControlCenter/Bundles/XingLanSwipeModule.bundle/my_tab.png"]];
        }
    }
    [candidates addObject:
        @"/Library/ControlCenter/Bundles/XingLanSwipeModule.bundle/my_tab.png"];
    [candidates addObject:
        @"/var/jb/Library/ControlCenter/Bundles/XingLanSwipeModule.bundle/my_tab.png"];

    for (NSString *path in candidates) {
        if ([NSFileManager.defaultManager fileExistsAtPath:path]) return path;
    }
    return nil;
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

    size_t startX = (size_t)floor((double)screenWidth * 0.70);
    size_t startY = (size_t)floor((double)screenHeight * 0.88);
    size_t endX = screenWidth - patternWidth;
    size_t endY = screenHeight - patternHeight;
    if (startX > endX || startY > endY) return 0.0;

    size_t step = MAX((size_t)1, (size_t)floor((double)screenWidth / 750.0));
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

    NSString *templatePath = XLTemplatePath();
    UIImage *templateImage = templatePath ?
        [UIImage imageWithContentsOfFile:templatePath] : nil;
    if (!templateImage.CGImage) {
        CGImageRelease(screenImage);
        XLSetDetectorError(error, 4, @"profile template unavailable");
        return -1.0;
    }

    size_t screenWidth = CGImageGetWidth(screenImage);
    size_t screenHeight = CGImageGetHeight(screenImage);
    double scale = (double)screenWidth / 750.0;
    size_t templateWidth = MAX((size_t)24,
        (size_t)lround((double)CGImageGetWidth(templateImage.CGImage) * scale));
    size_t templateHeight = MAX((size_t)12,
        (size_t)lround((double)CGImageGetHeight(templateImage.CGImage) * scale));

    uint8_t *screenPixels = XLCreateGrayscalePixels(
        screenImage, screenWidth, screenHeight);
    uint8_t *templatePixels = XLCreateGrayscalePixels(
        templateImage.CGImage, templateWidth, templateHeight);
    CGImageRelease(screenImage);
    if (!screenPixels || !templatePixels) {
        free(screenPixels);
        free(templatePixels);
        XLSetDetectorError(error, 5, @"could not prepare images for matching");
        return -1.0;
    }

    double score = XLBestTemplateCorrelation(screenPixels, screenWidth, screenHeight,
                                             templatePixels, templateWidth, templateHeight);
    free(screenPixels);
    free(templatePixels);
    NSLog(@"[XingLanSwipe] profile template %@ score %.4f at %zux%zu",
          templatePath.lastPathComponent, score, screenWidth, screenHeight);
    return score;
}

@end
