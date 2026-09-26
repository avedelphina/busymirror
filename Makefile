# Simple build and package helpers for BusyMirror

SCHEME ?= BusyMirror
PROJECT ?= BusyMirror.xcodeproj
DERIVED ?= build/DerivedData
DEST := platform=macOS

# Extract marketing version from project settings
VERSION := $(shell sed -n 's/.*MARKETING_VERSION = \([0-9.]*\);.*/\1/p' $(PROJECT)/project.pbxproj | head -n1)

# Developer ID signing identity (must be in the login keychain: security find-identity -v -p codesigning)
SIGN_IDENTITY ?= Developer ID Application: TOMÁŠ KRÁČMAR (P32JC2N6Y9)
# notarytool credential profile, created once via:
#   xcrun notarytool store-credentials hermes-notary --apple-id <apple-id> --team-id P32JC2N6Y9 --password <app-specific-password>
NOTARY_PROFILE ?= hermes-notary

.PHONY: all clean build-debug build-release sign-app notarize open app dmg package

all: build-release

clean:
	@echo "Cleaning derived data…"
	xcodebuild -scheme $(SCHEME) -project $(PROJECT) -derivedDataPath $(DERIVED) -destination '$(DEST)' CODE_SIGNING_ALLOWED=NO clean >/dev/null
	@echo "Done."

build-debug:
	@echo "Building Debug…"
	xcodebuild -scheme $(SCHEME) -project $(PROJECT) -configuration Debug -destination '$(DEST)' -derivedDataPath $(DERIVED) CODE_SIGNING_ALLOWED=NO build

build-release:
	@echo "Building Release…"
	xcodebuild -scheme $(SCHEME) -project $(PROJECT) -configuration Release -destination '$(DEST)' -derivedDataPath $(DERIVED) CODE_SIGNING_ALLOWED=NO build

# Convenience to open the built app in Finder
open: app
	@open "$<"

# Path to built app (Release)
APP_PATH := $(DERIVED)/Build/Products/Release/BusyMirror.app
SIGNED_APP_PATH := build/ReleaseSigned/BusyMirror.app

# codesign refuses to sign a bundle carrying Finder/resource-fork xattrs, and
# this repo lives under iCloud Drive, which re-tags every freshly written file
# with com.apple.FinderInfo before codesign gets to it — happens regardless of
# copy tool. So signing/notarizing/stapling happens in a local /tmp scratch
# dir (never iCloud-synced) and only the finished, already-signed app is
# copied back into the repo.
SCRATCH := /tmp/busymirror-sign
SCRATCH_APP := $(SCRATCH)/BusyMirror.app

sign-app: build-release
	@echo "Signing release app with Developer ID…"
	@rm -rf "$(SCRATCH)"
	@mkdir -p "$(SCRATCH)"
	@ditto --norsrc "$(APP_PATH)" "$(SCRATCH_APP)"
	@xattr -rc "$(SCRATCH_APP)"
	@codesign --force --options runtime --timestamp \
		--entitlements BusyMirror/BusyMirror.entitlements \
		--sign "$(SIGN_IDENTITY)" "$(SCRATCH_APP)"
	@codesign --verify --deep --strict --verbose=2 "$(SCRATCH_APP)"
	@rm -rf "$(SIGNED_APP_PATH)"
	@mkdir -p "$(dir $(SIGNED_APP_PATH))"
	@ditto "$(SCRATCH_APP)" "$(SIGNED_APP_PATH)"

app: sign-app
	@# Ensure the app exists
	@test -d "$(SIGNED_APP_PATH)" && echo "Built: $(SIGNED_APP_PATH)" || (echo "App not found at $(SIGNED_APP_PATH)" && exit 1)
	@echo "Version: $(VERSION)"
	@echo "OK"

# Submit to Apple notary service and staple the ticket onto the app.
notarize: sign-app
	@echo "Submitting for notarization (this can take a few minutes)…"
	@ditto --norsrc -c -k --keepParent "$(SCRATCH_APP)" "$(SCRATCH)/notarize-submission.zip"
	@xcrun notarytool submit "$(SCRATCH)/notarize-submission.zip" --keychain-profile "$(NOTARY_PROFILE)" --wait
	@xcrun stapler staple "$(SCRATCH_APP)"
	@xcrun stapler validate "$(SCRATCH_APP)"
	@spctl --assess --type execute --verbose=2 "$(SCRATCH_APP)"
	@rm -rf "$(SIGNED_APP_PATH)"
	@mkdir -p "$(dir $(SIGNED_APP_PATH))"
	@ditto "$(SCRATCH_APP)" "$(SIGNED_APP_PATH)"

# Drag-to-Applications disk image around the already-notarized, stapled app. The image itself is
# signed, notarized and stapled too, so Gatekeeper is happy offline. Built in the scratch dir for
# the same iCloud-xattr reason as signing; only the finished DMG is copied into the repo.
DMG := BusyMirror-$(VERSION)-macOS.dmg

dmg: notarize
	@echo "Building $(DMG)…"
	@rm -rf "$(SCRATCH)/dmg-root" "$(SCRATCH)/$(DMG)"
	@mkdir -p "$(SCRATCH)/dmg-root"
	@ditto "$(SCRATCH_APP)" "$(SCRATCH)/dmg-root/BusyMirror.app"
	@ln -s /Applications "$(SCRATCH)/dmg-root/Applications"
	@hdiutil create -volname "BusyMirror" -srcfolder "$(SCRATCH)/dmg-root" -ov -format UDZO "$(SCRATCH)/$(DMG)"
	@codesign --force --timestamp --sign "$(SIGN_IDENTITY)" "$(SCRATCH)/$(DMG)"
	@xcrun notarytool submit "$(SCRATCH)/$(DMG)" --keychain-profile "$(NOTARY_PROFILE)" --wait
	@xcrun stapler staple "$(SCRATCH)/$(DMG)"
	@xcrun stapler validate "$(SCRATCH)/$(DMG)"
	@ditto "$(SCRATCH)/$(DMG)" "$(DMG)"
	@shasum -a 256 "$(DMG)" | awk '{print $$1}' > "$(DMG).sha256"

package: dmg
	@echo "Packaging BusyMirror $(VERSION)…"
	@ditto --norsrc -c -k --keepParent "$(SCRATCH_APP)" "BusyMirror-$(VERSION)-macOS.zip"
	@shasum -a 256 "BusyMirror-$(VERSION)-macOS.zip" | awk '{print $$1}' > "BusyMirror-$(VERSION)-macOS.zip.sha256"
	@rm -rf "$(SCRATCH)"
	@echo "Created $(DMG) and BusyMirror-$(VERSION)-macOS.zip, each with a .sha256"
