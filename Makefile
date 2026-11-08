APP := build/Doppelganger.app
INSTALLED := $(HOME)/Applications/Doppelganger.app
# An Apple Development certificate (create one in Xcode › Settings › Accounts). Its team keeps the
# app's identity across builds, so macOS remembers its permissions (network volumes, Full Disk
# Access) and keeps starting the folder setup helper; without a team, macOS ties that helper to the
# first build that registered it.
IDENTITY := Apple Development: hello.shamus@gmail.com

# Build, sign, and install to ~/Applications.
install: app
	@# Quit only the menu bar app; the background service runs the same executable with --service.
	osascript -e 'tell application id "com.shamusli.Doppelganger" to quit'
	@while pgrep -f 'MacOS/Doppelganger$$' >/dev/null; do sleep 0.2; done
	@sleep 1 # Launch Services refuses to reopen an app in the moment after it quits.
	mkdir -p "$(HOME)/Applications"
	rm -rf "$(INSTALLED)"
	ditto "$(APP)" "$(INSTALLED)"
	open "$(INSTALLED)"

app: build/sshfs/sshfs
	swift build -c release --product Doppelganger
	rm -rf "$(APP)"
	mkdir -p "$(APP)/Contents/MacOS" "$(APP)/Contents/Resources" "$(APP)/Contents/Library/LaunchAgents" "$(APP)/Contents/Library/LaunchDaemons"
	cp .build/release/Doppelganger build/sshfs/sshfs "$(APP)/Contents/MacOS/"
	cp Support/Info.plist "$(APP)/Contents/"
	/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $$(git rev-list --count HEAD)" "$(APP)/Contents/Info.plist"
	cp Support/Icon/Assets.car Support/Icon/Doppelganger.icns "$(APP)/Contents/Resources/"
	cp Support/com.shamusli.Doppelganger.service.plist "$(APP)/Contents/Library/LaunchAgents/"
	cp Support/com.shamusli.Doppelganger.folders-*.plist "$(APP)/Contents/Library/LaunchDaemons/"
	sshfs/bundle-libs.sh "$(APP)/Contents/MacOS/sshfs" "$(APP)/Contents/Frameworks"
	@# The hardened runtime makes macOS refuse injected code and libraries not signed by the same team.
	@# sshfs is let off the second only because macFUSE's libfuse loads macFUSE's own MFMount framework.
	codesign --force --options runtime --sign "$(IDENTITY)" "$(APP)"/Contents/Frameworks/*.dylib
	codesign --force --options runtime --entitlements Support/sshfs.entitlements --sign "$(IDENTITY)" "$(APP)/Contents/MacOS/sshfs"
	codesign --force --options runtime --sign "$(IDENTITY)" "$(APP)"

# sshfs against macFUSE, with the patches in sshfs/patches.
build/sshfs/sshfs: sshfs/build.sh $(wildcard sshfs/patches/*.patch)
	sshfs/build.sh $@

test:
	swift test

# Recompile the app icon after editing Support/Doppelganger.icon in Icon Composer. Needs Xcode.
icon:
	/Applications/Xcode.app/Contents/Developer/usr/bin/actool Support/Doppelganger.icon \
		--compile Support/Icon --app-icon Doppelganger --platform macosx --target-device mac \
		--minimum-deployment-target 15.0 --output-partial-info-plist /dev/null

.PHONY: install app test icon
