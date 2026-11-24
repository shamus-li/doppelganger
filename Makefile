APP := build/Doppelganger.app
INSTALLED := $(HOME)/Applications/Doppelganger.app
# An Apple Development certificate (create one in Xcode › Settings › Accounts). Its team keeps the
# app's identity across builds, so macOS remembers its permissions (network volumes, Full Disk
# Access) and keeps starting the folder setup helper; without a team, macOS ties that helper to the
# first build that registered it.
IDENTITY := Apple Development: hello.shamus@gmail.com
VERSION := $(shell /usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Support/Info.plist)
RELEASE := build/release/$(VERSION)
# Sparkle's tools, which SwiftPM downloads with the package.
SPARKLE_BIN := .build/artifacts/sparkle/Sparkle/bin

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
	ditto .build/release/Sparkle.framework "$(APP)/Contents/Frameworks/Sparkle.framework"
	cp Support/Info.plist "$(APP)/Contents/"
	/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $$(git rev-list --count HEAD)" "$(APP)/Contents/Info.plist"
	cp Support/Icon/Assets.car Support/Icon/Doppelganger.icns "$(APP)/Contents/Resources/"
	cp Support/com.shamusli.Doppelganger.service.plist "$(APP)/Contents/Library/LaunchAgents/"
	cp Support/com.shamusli.Doppelganger.folders-*.plist "$(APP)/Contents/Library/LaunchDaemons/"
	sshfs/bundle-libs.sh "$(APP)/Contents/MacOS/sshfs" "$(APP)/Contents/Frameworks"
	@# The hardened runtime makes macOS refuse injected code and libraries not signed by the same team.
	@# sshfs is let off the second only because macFUSE's libfuse loads macFUSE's own MFMount framework.
	codesign --force --options runtime --sign "$(IDENTITY)" "$(APP)"/Contents/Frameworks/*.dylib
	@# Sparkle's helpers, inside out, as Sparkle's documentation lays out.
	codesign --force --options runtime --sign "$(IDENTITY)" "$(APP)/Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices/Installer.xpc"
	codesign --force --options runtime --preserve-metadata=entitlements --sign "$(IDENTITY)" "$(APP)/Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices/Downloader.xpc"
	codesign --force --options runtime --sign "$(IDENTITY)" "$(APP)/Contents/Frameworks/Sparkle.framework/Versions/B/Autoupdate"
	codesign --force --options runtime --sign "$(IDENTITY)" "$(APP)/Contents/Frameworks/Sparkle.framework/Versions/B/Updater.app"
	codesign --force --options runtime --sign "$(IDENTITY)" "$(APP)/Contents/Frameworks/Sparkle.framework"
	codesign --force --options runtime --entitlements Support/sshfs.entitlements --sign "$(IDENTITY)" "$(APP)/Contents/MacOS/sshfs"
	codesign --force --options runtime --sign "$(IDENTITY)" "$(APP)"

# sshfs against macFUSE, with the patches in sshfs/patches.
build/sshfs/sshfs: sshfs/build.sh $(wildcard sshfs/patches/*.patch)
	sshfs/build.sh $@

# Publish the committed code as a GitHub release with the version in Support/Info.plist. Installed
# apps find it through the appcast.xml on the latest release, signed with the key that Sparkle's
# generate_keys keeps in the login keychain.
release: clean-tree app
	mkdir -p "$(RELEASE)"
	ditto -c -k --keepParent "$(APP)" "$(RELEASE)/Doppelganger-$(VERSION).zip"
	$(SPARKLE_BIN)/generate_appcast --download-url-prefix https://github.com/shamus-li/doppelganger/releases/download/v$(VERSION)/ "$(RELEASE)"
	gh release create v$(VERSION) "$(RELEASE)/Doppelganger-$(VERSION).zip" "$(RELEASE)/appcast.xml" \
		--title $(VERSION) --target "$$(git rev-parse HEAD)" --generate-notes

# The build number is the commit count, so a release is built from committed code.
clean-tree:
	@test -z "$$(git status --porcelain)" || { echo "Commit or stash your changes before releasing."; exit 1; }
	@! git ls-remote --exit-code --tags origin "v$(VERSION)" >/dev/null || { echo "v$(VERSION) is released; raise CFBundleShortVersionString in Support/Info.plist."; exit 1; }

test:
	swift test

# Recompile the app icon after editing Support/Doppelganger.icon in Icon Composer. Needs Xcode.
icon:
	/Applications/Xcode.app/Contents/Developer/usr/bin/actool Support/Doppelganger.icon \
		--compile Support/Icon --app-icon Doppelganger --platform macosx --target-device mac \
		--minimum-deployment-target 15.0 --output-partial-info-plist /dev/null

.PHONY: install app release clean-tree test icon
