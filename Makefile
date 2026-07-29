ARCHS = arm64 arm64e
TARGET = iphone:clang:latest:15.0

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = XingLanSwipe
XingLanSwipe_FILES = Tweak.m XLHIDSender.m
XingLanSwipe_CFLAGS = -fobjc-arc -Wall -Wextra
XingLanSwipe_FRAMEWORKS = UIKit Foundation IOKit

include $(THEOS_MAKE_PATH)/tweak.mk

