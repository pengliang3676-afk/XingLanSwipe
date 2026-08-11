ARCHS = arm64 arm64e
TARGET = iphone:clang:latest:15.0

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = XingLanSwipe
XingLanSwipe_FILES = Tweak.xm
XingLanSwipe_CFLAGS = -fobjc-arc -Wall -Wextra
ifeq ($(THEOS_PACKAGE_SCHEME),roothide)
XingLanSwipe_CFLAGS += -DXL_ROOT_HIDE=1
endif
XingLanSwipe_FRAMEWORKS = UIKit Foundation

BUNDLE_NAME = XingLanSwipeModule
XingLanSwipeModule_FILES = ControlCenterModule/XingLanSwipeModule.m
XingLanSwipeModule_INSTALL_PATH = /Library/ControlCenter/Bundles
XingLanSwipeModule_RESOURCE_DIRS = ControlCenterModule/Resources
XingLanSwipeModule_CFLAGS = -fobjc-arc -Wall -Wextra
XingLanSwipeModule_FRAMEWORKS = UIKit Foundation
XingLanSwipeModule_LDFLAGS = -undefined dynamic_lookup

include $(THEOS_MAKE_PATH)/tweak.mk
include $(THEOS_MAKE_PATH)/bundle.mk
