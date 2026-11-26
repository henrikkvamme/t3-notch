# Local builds are "T3 Notch Dev" (bundle id dev.t3notch.app.dev), so they keep their own
# permissions, settings and logs and can run beside the release build, which `scripts/release.sh`
# makes from Resources/Info.plist unchanged.
DEV_NAME := T3 Notch Dev
DEV_ID := dev.t3notch.app.dev
APP := build/$(DEV_NAME).app
# Sign with a stable identity (the first Apple Development certificate) so macOS keeps the
# Screen Recording and Accessibility permissions across rebuilds. Ad-hoc ("-") changes the
# signature on every build, which resets them. Override with `make SIGN_ID=... app`.
SIGN_ID ?= $(shell security find-identity -v -p codesigning | grep "Apple Development" | head -1 | awk '{print $$2}')
INSTALL_DIR := $(HOME)/Applications

.PHONY: build app install run clean

build:
	swift build -c release

# Wraps the release binary in an .app bundle and signs it (see SIGN_ID).
app: build
	rm -rf "$(APP)"
	mkdir -p "$(APP)/Contents/MacOS"
	cp .build/release/T3Notch "$(APP)/Contents/MacOS/T3Notch"
	cp Resources/Info.plist "$(APP)/Contents/Info.plist"
	/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $(DEV_ID)" \
		-c "Set :CFBundleName $(DEV_NAME)" -c "Set :CFBundleDisplayName $(DEV_NAME)" "$(APP)/Contents/Info.plist"
	mkdir -p "$(APP)/Contents/Resources"
	cp Resources/AppIcon.icns "$(APP)/Contents/Resources/AppIcon.icns"
	@if [ -z "$(SIGN_ID)" ]; then echo "warning: no Apple Development certificate, so the app is signed ad-hoc." \
		"macOS drops its Screen Recording and Accessibility grants after each build; grant them again from the island." >&2; fi
	cp -R Extension "$(APP)/Contents/Resources/Extension"
	codesign --force --sign "$(or $(SIGN_ID),-)" "$(APP)"

# Quits only the dev copy (matched by its path), never the release one.
install: app
	-pkill -f "/$(DEV_NAME).app/Contents/MacOS/"
	sleep 1 # let the old instance exit, or `open` fails with -600
	rm -rf "$(INSTALL_DIR)/$(DEV_NAME).app"
	cp -R "$(APP)" "$(INSTALL_DIR)/"
	open "$(INSTALL_DIR)/$(DEV_NAME).app"

run: app
	-pkill -f "/$(DEV_NAME).app/Contents/MacOS/"
	open "$(APP)"

clean:
	rm -rf .build build
