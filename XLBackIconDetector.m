#import "XLBackIconDetector.h"
#import <dlfcn.h>
#import <math.h>
#import <stdlib.h>

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

static double XLGrayAt(const uint8_t *pixels, size_t width, size_t height,
                       NSInteger x, NSInteger y) {
    if (x < 0 || y < 0 || (size_t)x >= width || (size_t)y >= height) return 0.0;
    return pixels[(size_t)y * width + (size_t)x];
}

static void XLSobelAt(const uint8_t *pixels, size_t width, size_t height,
                      NSInteger x, NSInteger y, double *gradientX,
                      double *gradientY, double *magnitude) {
    double topLeft = XLGrayAt(pixels, width, height, x - 1, y - 1);
    double top = XLGrayAt(pixels, width, height, x, y - 1);
    double topRight = XLGrayAt(pixels, width, height, x + 1, y - 1);
    double left = XLGrayAt(pixels, width, height, x - 1, y);
    double right = XLGrayAt(pixels, width, height, x + 1, y);
    double bottomLeft = XLGrayAt(pixels, width, height, x - 1, y + 1);
    double bottom = XLGrayAt(pixels, width, height, x, y + 1);
    double bottomRight = XLGrayAt(pixels, width, height, x + 1, y + 1);
    double gx = -topLeft - 2.0 * left - bottomLeft +
                topRight + 2.0 * right + bottomRight;
    double gy = -topLeft - 2.0 * top - topRight +
                bottomLeft + 2.0 * bottom + bottomRight;
    if (gradientX) *gradientX = gx;
    if (gradientY) *gradientY = gy;
    if (magnitude) *magnitude = sqrt(gx * gx + gy * gy);
}

// Matches only the two diagonal strokes of a left-facing chevron. Edge
// direction and magnitude are used, so neither icon nor background color is
// fixed.
static double XLChevronScoreAt(const uint8_t *pixels, size_t width, size_t height,
                               NSInteger vertexX, NSInteger centerY,
                               NSInteger armWidth, NSInteger armHeight) {
    double strengthSum = 0.0;
    NSUInteger coveredSamples = 0;
    NSUInteger totalSamples = 0;
    for (NSInteger sign = -1; sign <= 1; sign += 2) {
        for (NSInteger distance = 2; distance <= armHeight - 2; distance += 2) {
            double progress = (double)distance / (double)armHeight;
            NSInteger expectedX = vertexX + (NSInteger)lround(armWidth * progress);
            NSInteger expectedY = centerY + sign * distance;
            double bestStrength = 0.0;
            for (NSInteger offsetY = -2; offsetY <= 2; offsetY++) {
                for (NSInteger offsetX = -2; offsetX <= 2; offsetX++) {
                    double gx = 0.0, gy = 0.0, magnitude = 0.0;
                    XLSobelAt(pixels, width, height,
                              expectedX + offsetX, expectedY + offsetY,
                              &gx, &gy, &magnitude);
                    if (magnitude < 1.0) continue;
                    double normalX = -sign * armHeight;
                    double normalY = armWidth;
                    double normalLength = sqrt(normalX * normalX + normalY * normalY);
                    double directionAgreement = fabs(
                        (gx * normalX + gy * normalY) /
                        (magnitude * normalLength));
                    double strength = magnitude * directionAgreement;
                    if (strength > bestStrength) bestStrength = strength;
                }
            }
            strengthSum += bestStrength;
            if (bestStrength >= 160.0) coveredSamples++;
            totalSamples++;
        }
    }
    if (totalSamples == 0) return 0.0;
    double averageStrength = strengthSum / totalSamples;
    double strengthScore = MIN(1.0, averageStrength / 420.0);
    double coverageScore = (double)coveredSamples / totalSamples;
    return 0.55 * strengthScore + 0.45 * coverageScore;
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

    size_t screenWidth = CGImageGetWidth(screenImage);
    size_t screenHeight = CGImageGetHeight(screenImage);
    if (screenWidth == 0 || screenHeight == 0) {
        CGImageRelease(screenImage);
        XLSetDetectorError(error, 5, @"invalid screen dimensions");
        return -1.0;
    }

    uint8_t *screenPixels = XLCreateGrayscalePixels(
        screenImage, screenWidth, screenHeight);
    CGImageRelease(screenImage);
    if (!screenPixels) {
        free(screenPixels);
        XLSetDetectorError(error, 6, @"could not prepare grayscale images");
        return -1.0;
    }

    double widthScale = (double)screenWidth / 750.0;
    double heightScale = (double)screenHeight / 1334.0;
    double bestScore = 0.0;
    NSInteger bestX = 0, bestY = 0, bestWidth = 0, bestHeight = 0;
    // The fixed SE2 region is visible x=38..60 and y=1266..1306 in a
    // 750x1334 screenshot. The grayscale bitmap rows are vertically flipped.
    NSInteger xStep = MAX(1, (NSInteger)lround(2.0 * widthScale));
    NSInteger yStep = MAX(1, (NSInteger)lround(2.0 * heightScale));
    for (NSInteger vertexX = (NSInteger)lround(32.0 * widthScale);
         vertexX <= (NSInteger)lround(46.0 * widthScale); vertexX += xStep) {
        for (NSInteger centerY = (NSInteger)lround(40.0 * heightScale);
             centerY <= (NSInteger)lround(56.0 * heightScale); centerY += yStep) {
            for (NSInteger armWidth = (NSInteger)lround(16.0 * widthScale);
                 armWidth <= (NSInteger)lround(26.0 * widthScale); armWidth += xStep) {
                for (NSInteger armHeight = (NSInteger)lround(16.0 * heightScale);
                     armHeight <= (NSInteger)lround(26.0 * heightScale); armHeight += yStep) {
                    double score = XLChevronScoreAt(
                        screenPixels, screenWidth, screenHeight,
                        vertexX, centerY, armWidth, armHeight);
                    if (score > bestScore) {
                        bestScore = score;
                        bestX = vertexX;
                        bestY = centerY;
                        bestWidth = armWidth;
                        bestHeight = armHeight;
                    }
                }
            }
        }
    }

    free(screenPixels);
    NSLog(@"[XingLanSwipe] local back-chevron score=%.4f vertex=%ldx%ld arms=%ldx%ld screen=%zux%zu",
          bestScore, (long)bestX, (long)bestY, (long)bestWidth,
          (long)bestHeight, screenWidth, screenHeight);
    return bestScore;
}

@end
