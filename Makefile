TARGET := iphone:clang:latest:17.0
ARCHS := arm64 arm64e

include $(THEOS)/makefiles/common.mk

APPLICATION_NAME := SuperKill

SuperKill_FILES := $(wildcard Sources/*.m)
SuperKill_FRAMEWORKS := Foundation UIKit Security
SuperKill_CODESIGN_FLAGS := -SEntitlements/SuperKill.entitlements
SuperKill_INFOPLIST := Resources/Info.plist

include $(THEOS_MAKE_PATH)/application.mk

after-install::
	install.exec "killall -9 SuperKill || true"
