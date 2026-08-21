#import <Foundation/Foundation.h>
#import <sys/types.h>

typedef NS_ENUM(NSInteger, XLAXBackDetectionResult) {
    XLAXBackDetectionUnavailable = -1,
    XLAXBackDetectionNotFound = 0,
    XLAXBackDetectionFound = 1,
};

@interface XLAXBackDetector : NSObject

- (XLAXBackDetectionResult)detectBaiduBackButtonAtNormalizedX:(double)x
                                                           y:(double)y
                                                 expectedPid:(pid_t)expectedPid
                                                  diagnostic:(NSString **)diagnostic;

@end
