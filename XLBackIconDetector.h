#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface XLBackIconDetector : NSObject

- (nullable UIImage *)captureScreenWithError:(NSError **)error;
- (double)matchScoreForScreenshot:(UIImage *)screenshot error:(NSError **)error;

@end

NS_ASSUME_NONNULL_END
