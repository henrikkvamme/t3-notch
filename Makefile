APP := build/T3 Notch.app
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
	mkdir -p "$(APP)/Contents/Resources"
	cp Resources/AppIcon.icns "$(APP)/Contents/Resources/AppIcon.icns"
	codesign --force --sign "$(or $(SIGN_ID),-)" "$(APP)"

install: app
	-pkill -x T3Notch
	sleep 1 # let the old instance exit, or `open` fails with -600
	rm -rf "$(INSTALL_DIR)/T3 Notch.app"
	cp -R "$(APP)" "$(INSTALL_DIR)/"
	open "$(INSTALL_DIR)/T3 Notch.app"

run: app
	-pkill -x T3Notch
	open "$(APP)"

clean:
	rm -rf .build build
