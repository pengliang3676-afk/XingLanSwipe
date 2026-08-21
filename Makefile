ARCHS = arm64 arm64e
TARGET = iphone:clang:latest:15.0

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = XingLanSwipe
XingLanSwipe_FILES = Tweak.xm XLHIDSender.m XLAXBackDetector.m
XingLanSwipe_CFLAGS = -fobjc-arc -Wall -Wextra
XingLanSwipe_FRAMEWORKS = UIKit Foundation IOKit

BUNDLE_NAME = XingLanSwipeModule
XingLanSwipeModule_FILES = ControlCenterModule/XingLanSwipeModule.m
XingLanSwipeModule_INSTALL_PATH = /Library/ControlCenter/Bundles
XingLanSwipeModule_RESOURCE_DIRS = ControlCenterModule/Resources
XingLanSwipeModule_CFLAGS = -fobjc-arc -Wall -Wextra
XingLanSwipeModule_FRAMEWORKS = UIKit Foundation
XingLanSwipeModule_LDFLAGS = -undefined dynamic_lookup

include $(THEOS_MAKE_PATH)/tweak.mk
include $(THEOS_MAKE_PATH)/bundle.mk
