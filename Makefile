# Simple build and package helpers for BusyMirror

SCHEME ?= BusyMirror
PROJECT ?= BusyMirror.xcodeproj
DERIVED ?= build/DerivedData
DEST := platform=macOS

# Extract marketing version from project settings
VERSION := $(shell sed -n 's/.*MARKETING_VERSION = \([0-9.]*\);.*/\1/p' $(PROJECT)/project.pbxproj | head -n1)

.PHONY: all clean build-debug build-release open app package

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

app: build-release
	@# Ensure the app exists
	@test -d "$(APP_PATH)" && echo "Built: $(APP_PATH)" || (echo "App not found at $(APP_PATH)" && exit 1)
	@echo "Version: $(VERSION)"
	@echo "OK"

package: app
	@echo "Packaging BusyMirror $(VERSION)…"
	@zip -qry "BusyMirror-$(VERSION)-macOS.zip" "$(APP_PATH)"
	@shasum -a 256 "BusyMirror-$(VERSION)-macOS.zip" | awk '{print $$1}' > "BusyMirror-$(VERSION)-macOS.zip.sha256"
	@echo "Created BusyMirror-$(VERSION)-macOS.zip and .sha256"

