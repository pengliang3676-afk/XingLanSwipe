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
static const CGFloat XLTemplateReferenceScreenWidth = 750.0;
static const CGFloat XLTemplateReferenceWidth = 86.0;
static const CGFloat XLTemplateReferenceHeight = 40.0;
static NSString *const XLProfileTabTemplateBase64 = @"iVBORw0KGgoAAAANSUhEUgAAAFYAAAAoCAYAAABkfg1GAAAAAXNSR0IArs4c6QAAAARnQU1BAACxjwv8YQUAAAAJcEhZcwAADsMAAA7DAcdvqGQAAAr+SURB"
@"VGhD7dr701ZTGwfwO6FyikIHyjkGYxzSOE1FRcxIoZxFUiSHDo6JlGNUDqUISaVfjJ/y9y3PZ+X7WG7PvD3zzry924wfvrP2XodrXdd3fde119733RsxYkT5"
@"TzjrrLNKr9crp512Wlm8eHH56quvym+//VZ+/fXX8tlnn5V9+/aVvXv3lvXr15cbb7yxjB8/vkycOLFMnTq1nHPOOeXMM88cBFvqJk+eXC688MJyySWXlHnz"
@"5pV33nmnHD58uPz000/l66+/rvZ2795dPvzww9pv7Nix1Rd+pISRI0f+xdcu4ZjEJogTTjihjBs3rtxyyy1l48aN5eeffy779+8ve/bsKd9880354YcfysGD"
@"B8uhQ4fKd999V0l/9913y44dO8r27dvLtm3bBqHuiy++KF9++WUdx8auXbvKjz/+WH755ZdK7pIlS8qECRPqvPHhxBNPrGh9GsrnLmDYxLYBUeMTTzxRPv/8"
@"86o0JB84cKCq99tvv61qA4SnVI9woEj36i0Ecqn1+++/L6tXry7Tpk2rajz55JMHyVOedNJJtS5K/UcTe/rppw+SKrBTTjmljBkzpm7P8847r8yePbu89tpr"
@"lRyk7dy5sxJEfZQHUTTyLUIWA6kff/xx3fLPP/98TSVSxqhRo8ro0aP/RqRSXcCvfn+7gmEpVhCCimITGALOPvvsWtq2c+fOLU899VRZunRpWbZsWVm7dm3N"
@"vbBu3bryyiuvVEWuXLmyPPPMM7Xv5ZdfXlNM5mttn3rqqZU8c0edLbn/aGIhhAqKggWV+5Zs6hIsuKY6JWgPQe0W1re1r1/mdO9aGYJbxEYXcUxiQ1aCawlE"
@"EPKQkCd/SIri9D333HNr6mhJdEJgSx/32vQ1Tn36uYb40C6M9n5/u4JjEosQwSbQkCnPKgUr755xxhkVCdbxLGPctyUgq+2Thco1ku2OqDOE9iN+dg3DSgVI"
@"pDBAokDVC4ziEKoOGYjR5jybPupSZqxrdpVZoPTJnMh3HWgP9I+tLmJYxCYIQQfqs3VTJ2D1uc84i5E0QY3uXSOODYtjnHoq1id2+4nsR3zsGoaVY0MU5KiF"
@"DMSknkIRoz4kxgaiosB2yyMPOSEPqSFZX2PM7zpjQ2jGZI6u4ZjEIkBAAlSGSEFFVXJhXn0hJGuPOgFxSHEdctKGxLQF7A5FbAjVp9/fruCYxAomgYUIwQna"
@"e/+kSZPKVVddNdgfQfogUf886FJnrPvrrrvuL4tjMZQUy16bd4PMoV+Quq5hWIoVlA8n8+fPLy+//HJZtWpVufXWWyu5Dvnemi6++OKyaNGi8sADD9RxiDLO"
@"eC8RSuqDGTNmlDVr1lSVeznQxj6Sr7/++vLSSy+VK6+88m8KHgr9/nYFPYqkDk4KJIHKk4899lh9W/LRxIeSjz76qBJ71113VSIozxsWUK5X0vfee6+88cYb"
@"1UbUaA7XSSWPPPJIffNKvTo7wunCwhhvYbzN6WMxol5OW9DY7Q+oK+hxuFUGZxFNVe+//34lAXHe6R966KEaMDIEKXBqfe655+pYREsP7n258jElZAKF+gxI"
@"5T5BqpMeQq58bK5nn322PiDTrt59CK2OD5T87g+oK+ghkVqQgrT27Qm0IeT1118vTz75ZFWVPKjNWJ/3fAtIoEpp4fHHHx88OQCFU+mGDRsq6XaBdPDiiy/W"
@"DzkWwHcD9XaGT45btmwpmzZtqrsELKw59bWwFmSooLqAmmNDYnIi2H5KZJ1//vnlrbfeqmQlGCq69NJLy7333ltThnrqoqw8rGIDsVOmTCmvvvpqXSDbXT5e"
@"vnx5+eCDD6oNC+red9wHH3xw8GOOfO7agviQE5vIhTaYLqGmAo4iBSHI9VT2FWrr1q3147VfDSBKoiofrKnJ50Afsn06/PTTT2u7T4U+hsuVHly2MOJWrFhR"
@"SUO0OeVlqYTq5Wd2FixYUNvbPGqx9LEw2f6x0R9QVzDg259bPiRLCbfddlu55557aikF+PkEUXKj0wGCbE3bGeGu5UfbmgIfffTR+hkRsX6queCCC2rKuP/+"
@"++scQPFOAOrN5Tq5Va42lkI9UOV6PkSp6vMw6yJ6nOZkvRkISEktURr4xQC51JT8mkVAJDVfdNFF9R6MkZeTEqQJDzq74M4776x1cqVcTLFPP/10ueyyy8rV"
@"V19dSdRXH35JOeoslu+7mQM6TWzrKKikXmQIjHoRRVVyHrUgl7KkD8qSGq699to6HtF+EaDA2GML0WzImdOnT687QSl1yLfmRKiffKgT8dKH+RCrj74WK4sb"
@"+11ED2kCEDzkSxWnkScwDy9qcQzS/+abb67n22uuuaaqWYqgZlte/ZtvvlkJZ48d9szhweV3sk8++aT+hIMo9xYBWUi74447ar0FshjyMD8Qa3zsKf9xilVS"
@"ELU6dyLNU9kPg0eOHKm/XcmxiKRqKrRV5V7qvfvuuwftWCgEIEk+1k+9LX7FFVfU45ZThQXMvOZzhnb8ig1KjmItrnoEt8F0CT0BC7INjBIdfTZv3lx/CPTT"
@"tCe9OrlUn/Q13nHID4jU5yil3lZmVz+gYMelpAhqlmPZzMsCApXmoGqkq5N/HfWcg2MPzDFUUF3AgH9HnaSqXPspxf8HZs2aVX+Jpcz8CIgsSnHgpxxGLIRX"
@"XlsVEQJmTz+waIh1yL/vvvuq6kB6kDaomB221fNBCpBr2TMW+Y5r2tiPz20wXcKAf0e3lG3vJEBJHkpRj0CR61Rg+zs2RbFy38yZM8vbb79d/1Mgv4YYSvbd"
@"ACnsWwR5mg33bCDPiwdic8zK/K49zLJQ5pfLs1hSkD5DBdUFDL55pQQKywuDe3lWHl24cGFdAHWIcEzKQ4i6KdqTHmlKr6Q5zulPnc6izri+J7zwwgt1LGKN"
@"MWfmNs48IZptC9f62AbSNQz4eFSxwNmoUWPIRabzpsO9/IcYb13elObMmVNzJfUhziH/hhtuqPmRyhBDrdqlCsQiyYPMCwViqdic2SUgTST3e8hJRea1SHzi"
@"J/QH1BUMxHD0IB5yBeMeGb6JOrt6OHna+wOb/JtXUwYQxoZ8J9c6w3qd9Tbm6KRNP98KkOjVVF/bW1px//DDD9cF0NdiSiMeWPKqI55FlDK8QMRfJX/bYLqE"
@"Af+OkhIFgDOl/EadAvLkvv322+uZNUG14yyCrY4s/yD0BKfuPOj01YZcyMMnxLhOCezddNNN9RQgL1OqbwmeAemXxVEGCaq11dYdTwzMfdTJKNbWs9XkOGqM"
@"02mHBBHnwWIg0nXypGvB62scwsC1Om1p19eiGRub0D+PsfoF8U+/Fu34/wd6cSwQmG2JJOToJBj11Kl0H8cRpY8xVJs2tkJciGyhTlsWAyxOXqFbO61v8YGN"
@"tr3ffmz21x8v9DiawJXuKUHJYWQJ2H2cBcHpR92uU49gajeun5Dcu1bnWn+l+dPOjpJtD7HMXx3+o42vkDEJKH2Ctv54oiewBKl0n2BbB4dCNTBQCjxbH2Ij"
@"k1gA6kQOuFaX8UH/fQttrX/tQnWSWAFyOGrltLoQSzUhQnvU3TqOVNsXwaCPtpwwMjYkuE59FiD23LNhrGtzx6f2ns/GDUVsa6+//nhhMMcig7OCDtHqE0Ac"
@"jbMCRbp+IRKcRbW5Vh9CMy621GlzfENkxmdce98PY82BZNcQ2+0c0F9/vDAw95/OhqQAqalHQkhXl3HQPmyiLNd/TDAIY6GtA/bYNjbIPHHUtbr4ENvq235B"
@"bPfXHy8c8w8b/+K/w7/E/k8wovwOcbb/izW/e+IAAAAASUVORK5CYII=";

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
    uint8_t *rgbaPixels = calloc(width * height * 4, sizeof(uint8_t));
    if (!rgbaPixels) return NO;

    CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
    CGContextRef context = CGBitmapContextCreate(rgbaPixels, width, height, 8, width * 4,
        colorSpace, kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
    CGColorSpaceRelease(colorSpace);
    if (!context) {
        free(rgbaPixels);
        return NO;
    }
    CGContextSetInterpolationQuality(context, kCGInterpolationHigh);
    CGContextTranslateCTM(context, 0.0, (CGFloat)height);
    CGContextScaleCTM(context, 1.0, -1.0);
    CGContextDrawImage(context, CGRectMake(0, 0, width, height), source);
    CGContextRelease(context);

    uint8_t *pixels = calloc(width * height, sizeof(uint8_t));
    if (!pixels) {
        free(rgbaPixels);
        return NO;
    }
    for (size_t index = 0; index < width * height; index++) {
        size_t offset = index * 4;
        pixels[index] = (uint8_t)((77 * rgbaPixels[offset] +
                                   150 * rgbaPixels[offset + 1] +
                                   29 * rgbaPixels[offset + 2]) >> 8);
    }
    free(rgbaPixels);
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
    NSData *data = [[NSData alloc] initWithBase64EncodedString:XLProfileTabTemplateBase64
                                                        options:0];
    UIImage *image = [UIImage imageWithData:data];
    if (image.CGImage) {
        _templateImage = image;
        return image;
    }
    XLSetDetectorError(error, 3, @"embedded profile tab template unavailable");
    return nil;
}

- (double)matchScoreForScreenshot:(UIImage *)screenshot error:(NSError **)error {
    UIImage *templateSource = [self templateImageWithError:error];
    if (!templateSource || !screenshot.CGImage) return -1.0;

    size_t sourceWidth = CGImageGetWidth(screenshot.CGImage);
    size_t sourceHeight = CGImageGetHeight(screenshot.CGImage);
    // Keep the original capture pixels: the small bottom-tab characters lose their
    // distinguishing strokes when the screenshot is downsampled first.
    CGFloat scale = 1.0;
    size_t screenWidth = MAX((size_t)1, (size_t)llround(sourceWidth * scale));
    size_t screenHeight = MAX((size_t)1, (size_t)llround(sourceHeight * scale));
    size_t nominalTemplateWidth = MAX((size_t)8, (size_t)llround(
        screenWidth * XLTemplateReferenceWidth / XLTemplateReferenceScreenWidth));
    size_t nominalTemplateHeight = MAX((size_t)8, (size_t)llround(
        screenWidth * XLTemplateReferenceHeight / XLTemplateReferenceScreenWidth));
    if (nominalTemplateWidth >= screenWidth || nominalTemplateHeight >= screenHeight) {
        XLSetDetectorError(error, 4, @"template dimensions invalid");
        return -1.0;
    }

    XLGrayImage screen = {0};
    if (!XLCreateGrayImage(screenshot.CGImage, screenWidth, screenHeight, &screen)) {
        XLFreeGrayImage(&screen);
        XLSetDetectorError(error, 5, @"could not prepare image matcher");
        return -1.0;
    }

    double bestScore = -1.0;
    static const CGFloat scaleCandidates[] = {0.90, 1.00, 1.10};
    for (size_t candidate = 0; candidate < sizeof(scaleCandidates) / sizeof(scaleCandidates[0]);
         candidate++) {
        size_t templateWidth = MAX((size_t)8, (size_t)llround(
            nominalTemplateWidth * scaleCandidates[candidate]));
        size_t templateHeight = MAX((size_t)8, (size_t)llround(
            nominalTemplateHeight * scaleCandidates[candidate]));
        if (templateWidth >= screenWidth || templateHeight >= screenHeight) continue;

        XLGrayImage templateImage = {0};
        if (!XLCreateGrayImage(templateSource.CGImage, templateWidth, templateHeight,
                               &templateImage)) {
            continue;
        }
        size_t minX = MIN(screenWidth - templateWidth, (size_t)llround(screenWidth * 0.82));
        size_t maxX = screenWidth - templateWidth;
        size_t minY = MIN(screenHeight - templateHeight, (size_t)llround(screenHeight * 0.94));
        size_t maxY = screenHeight - templateHeight;
        for (size_t y = minY; y <= maxY; y++) {
            for (size_t x = minX; x <= maxX; x++) {
                bestScore = MAX(bestScore, XLScoreAt(&screen, &templateImage, x, y));
            }
        }
        XLFreeGrayImage(&templateImage);
    }
    XLFreeGrayImage(&screen);
    return bestScore;
}

@end
