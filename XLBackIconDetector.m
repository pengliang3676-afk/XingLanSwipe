#import "XLBackIconDetector.h"
#import <dlfcn.h>
#import <math.h>
#import <stdlib.h>
#import <string.h>

typedef UIImage *(*XLCreateScreenImageFn)(void);

typedef struct {
    size_t width;
    size_t height;
    uint8_t *pixels;
} XLGrayImage;

static NSString *const XLDetectorErrorDomain = @"com.jibeib.xinglanswipe.detector";
static const CGFloat XLTemplateReferenceScreenWidth = 525.0;
static const CGFloat XLTemplateReferenceWidth = 38.0;
static const CGFloat XLTemplateReferenceHeight = 34.0;

static void XLSetDetectorError(NSError **error, NSInteger code, NSString *message) {
    if (!error) return;
    *error = [NSError errorWithDomain:XLDetectorErrorDomain code:code
                              userInfo:@{NSLocalizedDescriptionKey: message}];
}

static void XLFreeGrayImage(XLGrayImage *image) {
    if (!image) return;
    free(image->pixels);
    memset(image, 0, sizeof(*image));
}

static BOOL XLCreateGrayImage(CGImageRef source, size_t width, size_t height,
                              XLGrayImage *output) {
    if (!source || width == 0 || height == 0 || !output) return NO;
    memset(output, 0, sizeof(*output));
    uint8_t *pixels = calloc(width * height, sizeof(uint8_t));
    if (!pixels) return NO;

    CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceGray();
    CGContextRef context = CGBitmapContextCreate(pixels, width, height, 8, width,
        colorSpace, (CGBitmapInfo)kCGImageAlphaNone);
    CGColorSpaceRelease(colorSpace);
    if (!context) {
        free(pixels);
        return NO;
    }
    CGContextSetInterpolationQuality(context, kCGInterpolationHigh);
    CGContextTranslateCTM(context, 0.0, (CGFloat)height);
    CGContextScaleCTM(context, 1.0, -1.0);
    CGContextDrawImage(context, CGRectMake(0, 0, width, height), source);
    CGContextRelease(context);
    output->width = width;
    output->height = height;
    output->pixels = pixels;
    return YES;
}

static double XLScoreAt(const XLGrayImage *screen, const XLGrayImage *templateImage,
                        size_t originX, size_t originY) {
    double templateSum = 0.0, screenSum = 0.0;
    double templateSquares = 0.0, screenSquares = 0.0, crossSum = 0.0;
    size_t count = templateImage->width * templateImage->height;
    for (size_t y = 0; y < templateImage->height; y++) {
        const uint8_t *templateRow = templateImage->pixels + y * templateImage->width;
        const uint8_t *screenRow = screen->pixels + (originY + y) * screen->width + originX;
        for (size_t x = 0; x < templateImage->width; x++) {
            double a = templateRow[x];
            double b = screenRow[x];
            templateSum += a;
            screenSum += b;
            templateSquares += a * a;
            screenSquares += b * b;
            crossSum += a * b;
        }
    }
    double n = (double)count;
    double numerator = n * crossSum - templateSum * screenSum;
    double left = n * templateSquares - templateSum * templateSum;
    double right = n * screenSquares - screenSum * screenSum;
    double denominator = sqrt(MAX(0.0, left * right));
    return denominator < 1.0e-9 ? -1.0 : numerator / denominator;
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

@implementation XLBackIconDetector {
    UIImage *_templateImage;
}

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

- (UIImage *)templateImageWithError:(NSError **)error {
    if (_templateImage) return _templateImage;
    NSArray<NSString *> *paths = @[
        @"/var/jb/Library/ControlCenter/Bundles/XingLanSwipeModule.bundle/return_chevron.png",
        @"/Library/ControlCenter/Bundles/XingLanSwipeModule.bundle/return_chevron.png"
    ];
    for (NSString *path in paths) {
        UIImage *image = [UIImage imageWithContentsOfFile:path];
        if (image.CGImage) {
            _templateImage = image;
            return image;
        }
    }
    XLSetDetectorError(error, 3, @"return chevron template unavailable");
    return nil;
}

- (double)matchScoreForScreenshot:(UIImage *)screenshot error:(NSError **)error {
    UIImage *templateSource = [self templateImageWithError:error];
    if (!templateSource || !screenshot.CGImage) return -1.0;

    size_t sourceWidth = CGImageGetWidth(screenshot.CGImage);
    size_t sourceHeight = CGImageGetHeight(screenshot.CGImage);
    CGFloat scale = MIN(1.0, 420.0 / (CGFloat)sourceWidth);
    size_t screenWidth = MAX((size_t)1, (size_t)llround(sourceWidth * scale));
    size_t screenHeight = MAX((size_t)1, (size_t)llround(sourceHeight * scale));
    size_t templateWidth = MAX((size_t)8, (size_t)llround(
        screenWidth * XLTemplateReferenceWidth / XLTemplateReferenceScreenWidth));
    size_t templateHeight = MAX((size_t)8, (size_t)llround(
        screenWidth * XLTemplateReferenceHeight / XLTemplateReferenceScreenWidth));
    if (templateWidth >= screenWidth || templateHeight >= screenHeight) {
        XLSetDetectorError(error, 4, @"template dimensions invalid");
        return -1.0;
    }

    XLGrayImage screen = {0}, templateImage = {0};
    if (!XLCreateGrayImage(screenshot.CGImage, screenWidth, screenHeight, &screen) ||
        !XLCreateGrayImage(templateSource.CGImage, templateWidth, templateHeight,
                           &templateImage)) {
        XLFreeGrayImage(&screen);
        XLFreeGrayImage(&templateImage);
        XLSetDetectorError(error, 5, @"could not prepare image matcher");
        return -1.0;
    }

    size_t minX = 0;
    size_t maxX = MIN(screenWidth - templateWidth, (size_t)llround(screenWidth * 0.20));
    size_t minY = MIN(screenHeight - templateHeight, (size_t)llround(screenHeight * 0.88));
    size_t maxY = screenHeight - templateHeight;
    double bestScore = -1.0;
    for (size_t y = minY; y <= maxY; y++) {
        for (size_t x = minX; x <= maxX; x++) {
            bestScore = MAX(bestScore, XLScoreAt(&screen, &templateImage, x, y));
        }
    }
    XLFreeGrayImage(&screen);
    XLFreeGrayImage(&templateImage);
    return bestScore;
}

@end
