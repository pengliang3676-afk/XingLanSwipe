#import "XLBackIconDetector.h"
#import <dlfcn.h>
#import <math.h>
#import <stdlib.h>

typedef UIImage *(*XLCreateScreenImageFn)(void);

static NSString *const XLDetectorErrorDomain = @"com.jibeib.xinglanswipe.detector";

// A compact grayscale reference of the complete Baidu bottom navigation bar,
// taken from the user's confirmed device screenshot. Matching the full bar is
// much more reliable than matching the tiny two-character label alone.
static NSString *const XLEmbeddedBottomBarTemplate =
@"iVBORw0KGgoAAAANSUhEUgAAAI8AAAAXCAAAAAAXPUNhAAAEAklEQVR42s1VS2xbVRCduff9/I9REjshbpyfmkRJSUAIwQZRSgWtlLYEqQSJFWxZsGUNaxbACokVCCSkUJCoACG1kSK6QXVZkIoqaUqxE8eNU3/yPn7vftjAwva7b527Ppo598w5M3i6LqHrEe6aHUsTEPqIi2kJ6LcToHzSRgQAHtekCkI6HgWQIkF7IFof0o69Mnd/w7ZC66Az/cacANr6/iZVtEKhXchIAPRuNVWEiFN4FhHA3nT1bggddLuh3lNv0ZvTrzmVsH7oFz9awLhlPPGSWzKl4utruW3Pdpv55RKqRD6ztnfo2MdjZ7ccGqUPeisL63fx3sylyXW9vx/yK9m6GZjcYZc39w0ZSjmX+cwnxNVuvD991wrlzFIr35QsRPhp9dIXejfVbmSQm/10K2Gldj6ZHPX7fye1ET9Wfu9j2wzSAzz89yLOIW2y5+aQJ0UoBP3i4R9vLhla9t3fh9I8gg+K1J5tuOgSdqAYB2j16s8fBoQLpZ0pG3j75TXgRAFBmf7nhYur1uhsFR/3WIz0FtOD2TPNmUVfYUUEiR6doABSnS+t1l79fNtQMgYRL934pTGev36kYXS+UBB/5SL8QMOLSYHB2LnFC74gVB141K796KYaELES5Lob3xC56R2HRPEhdka7s/vkQd1K8bBGbHvJHviAOTJWr+lSNQ4WWKPVRiBRyYc6hfODD2+9On97qNwVC61XaX/1DumMF0/7YfGR+ncLcz4nSeRfHSTCJcRAyyw9E5hbGzpXiKM/ePHqfOlXfTz97dTiTpdRsXs/I7cuD3lEGM1r7TAHYZBanQwkYddLhkoe9nqxsfnX2Nmhw68VEUR/Yvm3h0aQu2IUvvwzig+A5yEYgstYeL6w0/E1nQmZVPEBCcl9SHveSIdRFWfPtwyQ/tjz92931+nlg2MotX09CXYrfLUOO1OPqiOQqVeI0hzJWOyBMdjq+Mp8pYjktoWCOz13qe9enFrKs9q5wnCsjGGzyF4tLmXoO/J8bVfhZwxmYoNk7+nxXKNNVY7PLi9OoVeYP1UPMDJfx6TSbts+kU2JIf1I4PBqG/bpESEKOiIxumseDTIuE7pyR3lNqBwn840sFTRyH6L5aE/GKgeNmgwrxtMD9yaqTtaIdxS9JHHLru0d12XF4soFRbTWCCWiJTokcl7I8sW8Z5v5mH8U5g96DAmWccv240ZFOQxreNI8LOwmWU1TRbBo+F4N/87GnFZ3mb58oUYDRoUwmOJ8gWeCbzqW+n5JA4GRjsmU+1ACEAmMMto7oD4+IABRIqiWqwQigAgiMOIagCQyEvGfkv0W7VeUAAACqIohSASJMqoZAkI04n/a/d0lnKinNemJ4kNOljzwL/Y31mCpET2lAAAAAElFTkSuQmCC";

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

static double XLCorrelation(const uint8_t *first, const uint8_t *second,
                            size_t count) {
    if (!first || !second || count == 0) return 0.0;
    double firstSum = 0.0, secondSum = 0.0;
    double firstSquares = 0.0, secondSquares = 0.0, products = 0.0;
    for (size_t index = 0; index < count; index++) {
        double a = first[index], b = second[index];
        firstSum += a; secondSum += b;
        firstSquares += a * a; secondSquares += b * b;
        products += a * b;
    }
    double firstVariance = firstSquares - firstSum * firstSum / count;
    double secondVariance = secondSquares - secondSum * secondSum / count;
    if (firstVariance <= 1.0 || secondVariance <= 1.0) return 0.0;
    double covariance = products - firstSum * secondSum / count;
    return MAX(0.0, covariance / sqrt(firstVariance * secondVariance));
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
        initWithBase64EncodedString:XLEmbeddedBottomBarTemplate options:0];
    UIImage *templateImage = templateData ? [UIImage imageWithData:templateData] : nil;
    if (!templateImage.CGImage) {
        CGImageRelease(screenImage);
        XLSetDetectorError(error, 4, @"bottom bar template unavailable");
        return -1.0;
    }

    const size_t outputWidth = CGImageGetWidth(templateImage.CGImage);
    const size_t outputHeight = CGImageGetHeight(templateImage.CGImage);
    uint8_t *templatePixels = XLCreateGrayscalePixels(
        templateImage.CGImage, outputWidth, outputHeight);
    if (!templatePixels) {
        CGImageRelease(screenImage);
        XLSetDetectorError(error, 5, @"could not prepare bottom bar template");
        return -1.0;
    }

    size_t screenWidth = CGImageGetWidth(screenImage);
    size_t screenHeight = CGImageGetHeight(screenImage);
    static const double heightRatios[] = {42.0 / 350.0, 45.0 / 350.0, 48.0 / 350.0};
    double bestScore = 0.0;
    for (size_t index = 0; index < 3; index++) {
        size_t cropWidth = MIN(screenWidth,
            (size_t)lround((double)screenWidth * 285.0 / 350.0));
        size_t cropHeight = MIN(screenHeight,
            (size_t)lround((double)screenWidth * heightRatios[index]));
        if (cropWidth == 0 || cropHeight == 0) continue;
        CGRect cropRect = CGRectMake(0.0, (CGFloat)(screenHeight - cropHeight),
                                     (CGFloat)cropWidth, (CGFloat)cropHeight);
        CGImageRef cropImage = CGImageCreateWithImageInRect(screenImage, cropRect);
        if (!cropImage) continue;
        uint8_t *cropPixels = XLCreateGrayscalePixels(
            cropImage, outputWidth, outputHeight);
        CGImageRelease(cropImage);
        if (!cropPixels) continue;
        double score = XLCorrelation(cropPixels, templatePixels,
                                     outputWidth * outputHeight);
        free(cropPixels);
        if (score > bestScore) bestScore = score;
    }
    free(templatePixels);
    CGImageRelease(screenImage);
    NSLog(@"[XingLanSwipe] bottom navigation score %.4f at %zux%zu",
          bestScore, screenWidth, screenHeight);
    return bestScore;
}

@end
