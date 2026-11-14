APP := build/T3 Notch.app
INSTALL_DIR := $(HOME)/Applications

.PHONY: build app install run clean

build:
	swift build -c release

# Wraps the release binary in an .app bundle with an ad-hoc signature.
app: build
	rm -rf "$(APP)"
	mkdir -p "$(APP)/Contents/MacOS"
	cp .build/release/T3Notch "$(APP)/Contents/MacOS/T3Notch"
	cp Resources/Info.plist "$(APP)/Contents/Info.plist"
	codesign --force --sign - "$(APP)"

install: app
	-pkill -x T3Notch
	rm -rf "$(INSTALL_DIR)/T3 Notch.app"
	cp -R "$(APP)" "$(INSTALL_DIR)/"
	open "$(INSTALL_DIR)/T3 Notch.app"

run: app
	-pkill -x T3Notch
	open "$(APP)"

clean:
	rm -rf .build build
