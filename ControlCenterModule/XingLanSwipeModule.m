#import <UIKit/UIKit.h>
#import <ControlCenterUIKit/CCUIToggleModule.h>
#import "../XingLanSwipeShared.h"

static BOOL XLReadRunningState(void) {
    CFPropertyListRef value = CFPreferencesCopyAppValue(
        CFSTR(XLRunningPreferenceKey), CFSTR(XLPreferenceDomain));
    BOOL running = (value && CFEqual(value, kCFBooleanTrue));
    if (value) CFRelease(value);
    return running;
}

static void XLWriteRunningState(BOOL running) {
    CFPreferencesSetAppValue(CFSTR(XLRunningPreferenceKey),
        running ? kCFBooleanTrue : kCFBooleanFalse,
        CFSTR(XLPreferenceDomain));
    CFPreferencesAppSynchronize(CFSTR(XLPreferenceDomain));
    CFNotificationCenterPostNotification(
        CFNotificationCenterGetDarwinNotifyCenter(),
        CFSTR(XLControlCenterStateNotification),
        NULL, NULL, YES);
}

@interface XingLanSwipeModule : CCUIToggleModule
@end

@implementation XingLanSwipeModule

- (UIImage *)iconGlyph {
    UIImageSymbolConfiguration *configuration =
        [UIImageSymbolConfiguration configurationWithPointSize:25.0 weight:UIImageSymbolWeightBold];
    return [UIImage systemImageNamed:@"hand.point.up.left.fill"
                    withConfiguration:configuration];
}

- (BOOL)isSelected {
    return XLReadRunningState();
}

- (void)setSelected:(BOOL)selected {
    XLWriteRunningState(selected);
}

@end
