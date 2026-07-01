PROJECT_DIR := src
PROJECT := $(PROJECT_DIR)/AppleContainerDesktop.xcodeproj
SCHEME := AppleContainerDesktop
DERIVED_DATA := build/DerivedData
DEBUG_APP := $(DERIVED_DATA)/Build/Products/Debug/AppleContainerDesktop.app
RELEASE_APP := $(DERIVED_DATA)/Build/Products/Release/AppleContainerDesktop.app
VERSION ?= 0.1.0
DMG_PATH := build/AppleContainerDesktop-$(VERSION).dmg
NOTARY_ZIP := build/AppleContainerDesktop-$(VERSION).zip
DESTINATION := platform=macOS

-include .env
export APPLE_ID APPLE_TEAM_ID APPLE_APP_PASSWORD

.PHONY: generate build test run launch-check release notarize dmg clean docs docs-build

generate:
	cd $(PROJECT_DIR) && xcodegen generate

build: generate
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) -configuration Debug -destination '$(DESTINATION)' -derivedDataPath $(DERIVED_DATA) build

test: generate
	xcodebuild test -project $(PROJECT) -scheme $(SCHEME) -configuration Debug -destination '$(DESTINATION)' -derivedDataPath $(DERIVED_DATA)

run: build
	open "$(DEBUG_APP)"
	osascript -e 'tell application id "dev.jp27.AppleContainerDesktop" to activate'

launch-check: build
	sh scripts/launch-smoke-test.sh "$(DEBUG_APP)"

release: generate
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) -configuration Release -destination '$(DESTINATION)' -derivedDataPath $(DERIVED_DATA) build

notarize: release
	@test -n "$(APPLE_ID)" || (echo "APPLE_ID is required" && exit 1)
	@test -n "$(APPLE_TEAM_ID)" || (echo "APPLE_TEAM_ID is required" && exit 1)
	@test -n "$(APPLE_APP_PASSWORD)" || (echo "APPLE_APP_PASSWORD is required" && exit 1)
	mkdir -p build
	ditto -c -k --keepParent "$(RELEASE_APP)" "$(NOTARY_ZIP)"
	xcrun notarytool submit "$(NOTARY_ZIP)" --apple-id "$(APPLE_ID)" --team-id "$(APPLE_TEAM_ID)" --password "$(APPLE_APP_PASSWORD)" --wait
	xcrun stapler staple "$(RELEASE_APP)"

dmg: release
	mkdir -p build/dmg-staging
	rm -rf build/dmg-staging/* "$(DMG_PATH)"
	cp -R "$(RELEASE_APP)" build/dmg-staging/
	ln -s /Applications build/dmg-staging/Applications
	hdiutil create -volname "Apple Container Desktop" -srcfolder build/dmg-staging -ov -format UDZO "$(DMG_PATH)"

clean:
	rm -rf build "$(PROJECT)"

docs:
	@echo "No docs site is configured yet. See README/README_ja once documentation is added."

docs-build:
	@echo "No docs site is configured yet. See README/README_ja once documentation is added."

