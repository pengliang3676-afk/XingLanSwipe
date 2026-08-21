#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface XLBackIconDetector : NSObject

- (nullable UIImage *)captureBackRegionWithError:(NSError **)error;
- (double)matchScoreForBackRegion:(UIImage *)backRegion
                            error:(NSError **)error;

@end

NS_ASSUME_NONNULL_END
