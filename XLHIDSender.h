#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef void (^XLHIDCompletion)(BOOL success);

@interface XLHIDSender : NSObject
- (void)performNaturalUpSwipeWithCompletion:(XLHIDCompletion)completion;
- (void)performTapAtNormalizedX:(double)x
                              y:(double)y
                     completion:(XLHIDCompletion)completion;
@end

NS_ASSUME_NONNULL_END
