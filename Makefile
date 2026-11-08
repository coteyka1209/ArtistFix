# ArtistFix — splits compound artist tags ("Artist 1; Artist 2") for the iOS 6 Music.app
#
# Tested on: iPhone 4S (iPhone4,1), iOS 6.1.3 (10B329), ARMv7

export ARCHS = armv7
export TARGET = iphone:clang:6.1:6.0
export THEOS_DEVICE_IP = 192.168.31.179
export DEBUG = 0

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = ArtistFix

ArtistFix_FILES = Tweak.xm
ArtistFix_CFLAGS = -fobjc-arc
ArtistFix_LIBRARIES = substrate
ArtistFix_LDFLAGS = -framework MediaPlayer -framework UIKit

include $(THEOS_MAKE_PATH)/tweak.mk

after-install::
	install.exec "killall -9 Music~iphone 2>/dev/null; true"
	install.exec "rm -f /var/mobile/Documents/ArtistFix.log /tmp/ArtistFix.log /var/tmp/ArtistFix.log"
