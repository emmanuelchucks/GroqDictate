.POSIX:
SHELL := /bin/bash

APP_NAME := GroqDictate
SCHEME := $(APP_NAME)
PROJECT := $(APP_NAME).xcodeproj
BUNDLE_ID := com.groqdictate

BUILD_ROOT := .build
DERIVED_DATA := $(BUILD_ROOT)/DerivedData
DIST_DIR := dist

HOST_ARCH := $(shell uname -m)
DEV_DESTINATION := platform=macOS,arch=$(HOST_ARCH)
RELEASE_DESTINATION := generic/platform=macOS
CI_DESTINATION := platform=macOS

DEBUG_APP := $(DERIVED_DATA)/Build/Products/Debug/$(APP_NAME).app
DEBUG_EXECUTABLE := $(DEBUG_APP)/Contents/MacOS/$(APP_NAME)
RELEASE_APP_UNSIGNED := $(DERIVED_DATA)/Build/Products/Release/$(APP_NAME).app
CI_RESULT_DIR := $(BUILD_ROOT)/TestResults
CI_RESULT_BUNDLE := $(CI_RESULT_DIR)/$(APP_NAME).xcresult

APP_PATH ?= /Applications/$(APP_NAME).app
INSTALLED_EXECUTABLE := $(APP_PATH)/Contents/MacOS/$(APP_NAME)

SIGNED_APP := $(DIST_DIR)/$(APP_NAME).app
ZIP_PATH := $(DIST_DIR)/$(APP_NAME).zip
ENTITLEMENTS_FILE := GroqDictate/GroqDictate.entitlements

DEVELOPER_ID_APP ?=
NOTARY_PROFILE ?=
DEVELOPMENT_TEAM ?= G729H95F8U
KEYCHAIN_SERVICE ?= $(BUNDLE_ID)
KEYCHAIN_ACCOUNT ?= groq-api-key
CI_SIGNING_FLAGS := CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY=

# Optional behavior flags
RESET ?= 0
INSTALL ?= 0
DEBUG_PERSIST ?= 0

.PHONY: help doctor clean reset generate verify-generated-project ci dev release

help:
	@echo "GroqDictate pipeline (simplified)"
	@echo ""
	@echo "Core commands:"
	@echo "  make generate               Regenerate $(PROJECT) from project.yml"
	@echo "  make verify-generated-project  Ensure committed $(PROJECT) matches project.yml"
	@echo "  make ci                     Regenerate, verify, test, and unsigned Release build"
	@echo "  make dev                     Build Debug, install to /Applications, run"
	@echo "  make release                Build Release, sign, notarize, verify"
	@echo "  make reset FORCE=1          Remove local app/system traces for clean testing"
	@echo "  make doctor                 Verify required local tooling"
	@echo "  make clean                  Remove build/dist artifacts"
	@echo ""
	@echo "Flags:"
	@echo "  RESET=1                     Run reset first (supported by make dev)"
	@echo "  INSTALL=1                   Install notarized release app to APP_PATH"
	@echo "  DEBUG_PERSIST=1             Enable persistent debug logs via app defaults"
	@echo ""
	@echo "Release variables:"
	@echo "  DEVELOPER_ID_APP='Developer ID Application: Name (TEAMID)'"
	@echo "  NOTARY_PROFILE='notarytool-keychain-profile'"
	@echo ""
	@echo "Examples:"
	@echo "  make dev RESET=1 FORCE=1 DEBUG_PERSIST=1"
	@echo "  make release DEVELOPER_ID_APP='Developer ID Application: Name (TEAMID)' NOTARY_PROFILE='profile' INSTALL=1 DEBUG_PERSIST=1"

doctor:
	@set -euo pipefail; \
	xcodebuild -version; \
	xcodegen --version; \
	xcrun --find notarytool >/dev/null; \
	xcrun --find stapler >/dev/null; \
	codesign --version; \
	spctl --version || true

generate:
	@xcodegen generate

verify-generated-project:
	@set -euo pipefail; \
	tmp_dir="$$(mktemp -d)"; \
	cp -R "$(PROJECT)" "$$tmp_dir/$(PROJECT)"; \
	trap 'rm -rf "$$tmp_dir"' EXIT; \
	$(MAKE) --no-print-directory generate; \
	diff -qr "$$tmp_dir/$(PROJECT)" "$(PROJECT)" >/dev/null || { \
		echo "❌ $(PROJECT) is out of date with project.yml"; \
		echo "Run 'xcodegen generate' and commit the generated project changes."; \
		git --no-pager diff --no-index -- "$$tmp_dir/$(PROJECT)" "$(PROJECT)" || true; \
		exit 1; \
	}; \
	echo "✅ Generated project matches project.yml"

ci:
	@set -euo pipefail; \
	$(MAKE) --no-print-directory verify-generated-project; \
	rm -rf "$(CI_RESULT_DIR)"; \
	mkdir -p "$(CI_RESULT_DIR)"; \
	xcodebuild \
		-project "$(PROJECT)" \
		-scheme "$(SCHEME)" \
		-configuration Debug \
		-destination "$(CI_DESTINATION)" \
		-derivedDataPath "$(DERIVED_DATA)" \
		-resultBundlePath "$(CI_RESULT_BUNDLE)" \
		$(CI_SIGNING_FLAGS) \
		test; \
	xcodebuild \
		-project "$(PROJECT)" \
		-scheme "$(SCHEME)" \
		-configuration Release \
		-destination "$(RELEASE_DESTINATION)" \
		-derivedDataPath "$(DERIVED_DATA)" \
		$(CI_SIGNING_FLAGS) \
		build; \
	test -d "$(CI_RESULT_BUNDLE)" || { echo "❌ Missing xcresult bundle at $(CI_RESULT_BUNDLE)"; exit 1; }; \
	echo "✅ CI validation complete"

clean:
	@rm -rf "$(BUILD_ROOT)" "$(DIST_DIR)"

reset:
	@set -euo pipefail; \
	test "$(FORCE)" = "1" || { echo "❌ Destructive action. Re-run with FORCE=1"; exit 1; }; \
	pkill -x "$(APP_NAME)" >/dev/null 2>&1 || true; \
	rm -rf "$(APP_PATH)"; \
	rm -rf "$(BUILD_ROOT)" "$(DIST_DIR)"; \
	defaults delete "$(BUNDLE_ID)" >/dev/null 2>&1 || true; \
	rm -f "$${HOME}/Library/Preferences/$(BUNDLE_ID).plist"; \
	rm -rf "$${HOME}/Library/Caches/$(BUNDLE_ID)"; \
	rm -rf "$${HOME}/Library/HTTPStorages/$(BUNDLE_ID)"; \
	rm -rf "$${HOME}/Library/Saved Application State/$(BUNDLE_ID).savedState"; \
	rm -rf "$${HOME}/Library/Logs/$(APP_NAME)"; \
	rm -rf "$${HOME}/Library/Application Support/$(APP_NAME)"; \
	rm -rf "$${HOME}/Library/Application Support/$(BUNDLE_ID)"; \
	security delete-generic-password -s "$(KEYCHAIN_SERVICE)" -a "$(KEYCHAIN_ACCOUNT)" >/dev/null 2>&1 || true; \
	rm -f "$${TMPDIR:-/tmp}/groqdictate"*.wav "$${TMPDIR:-/tmp}/groqdictate"*.flac; \
	tccutil reset Microphone "$(BUNDLE_ID)" >/dev/null 2>&1 || true; \
	tccutil reset Accessibility "$(BUNDLE_ID)" >/dev/null 2>&1 || true; \
	tccutil reset ListenEvent "$(BUNDLE_ID)" >/dev/null 2>&1 || true; \
	tccutil reset PostEvent "$(BUNDLE_ID)" >/dev/null 2>&1 || true; \
	echo "✅ Local app state reset complete for $(BUNDLE_ID)"; \
	echo "ℹ️  If login/background entries remain, remove them in System Settings → General → Login Items"

dev:
	@set -euo pipefail; \
	if [ "$(RESET)" = "1" ]; then \
		$(MAKE) --no-print-directory reset FORCE=$(FORCE); \
	fi; \
	xcodebuild \
		-project "$(PROJECT)" \
		-scheme "$(SCHEME)" \
		-configuration Debug \
		-destination "$(DEV_DESTINATION)" \
		-derivedDataPath "$(DERIVED_DATA)" \
		DEVELOPMENT_TEAM="$(DEVELOPMENT_TEAM)" \
		-quiet; \
	test -d "$(DEBUG_APP)" || { echo "❌ Debug build output missing"; exit 1; }; \
	mkdir -p "$$(dirname "$(APP_PATH)")"; \
	pkill -x "$(APP_NAME)" >/dev/null 2>&1 || true; \
	rm -rf "$(APP_PATH)"; \
	cp -R "$(DEBUG_APP)" "$(APP_PATH)"; \
	test -x "$(INSTALLED_EXECUTABLE)" || { echo "❌ Executable not found: $(INSTALLED_EXECUTABLE)"; exit 1; }; \
	if [ "$(DEBUG_PERSIST)" = "1" ]; then \
		defaults write "$(BUNDLE_ID)" debug-logging-enabled -bool true; \
		echo "✅ Persistent debug logging enabled"; \
	fi; \
	echo "✅ Debug app installed: $(APP_PATH)"; \
	"$(INSTALLED_EXECUTABLE)"

release:
	@set -euo pipefail; \
	test -n "$(DEVELOPER_ID_APP)" || { echo "❌ DEVELOPER_ID_APP is required"; exit 1; }; \
	test -n "$(NOTARY_PROFILE)" || { echo "❌ NOTARY_PROFILE is required"; exit 1; }; \
	xcodebuild \
		-project "$(PROJECT)" \
		-scheme "$(SCHEME)" \
		-configuration Release \
		-destination "$(RELEASE_DESTINATION)" \
		-derivedDataPath "$(DERIVED_DATA)" \
		CODE_SIGNING_ALLOWED=NO \
		CODE_SIGNING_REQUIRED=NO \
		CODE_SIGN_IDENTITY="" \
		-quiet; \
	test -d "$(RELEASE_APP_UNSIGNED)" || { echo "❌ Release build output missing"; exit 1; }; \
	rm -rf "$(DIST_DIR)"; \
	mkdir -p "$(DIST_DIR)"; \
	cp -R "$(RELEASE_APP_UNSIGNED)" "$(SIGNED_APP)"; \
	codesign \
		--force \
		--options runtime \
		--timestamp \
		--entitlements "$(ENTITLEMENTS_FILE)" \
		--sign "$(DEVELOPER_ID_APP)" \
		"$(SIGNED_APP)"; \
	codesign --verify --deep --strict --verbose=2 "$(SIGNED_APP)"; \
	rm -f "$(ZIP_PATH)"; \
	ditto -c -k --keepParent "$(SIGNED_APP)" "$(ZIP_PATH)"; \
	xcrun notarytool submit "$(ZIP_PATH)" --keychain-profile "$(NOTARY_PROFILE)" --wait; \
	xcrun stapler staple -v "$(SIGNED_APP)"; \
	xcrun stapler validate -v "$(SIGNED_APP)"; \
	spctl -a -vvv --type execute "$(SIGNED_APP)"; \
	rm -f "$(ZIP_PATH)"; \
	ditto -c -k --keepParent "$(SIGNED_APP)" "$(ZIP_PATH)"; \
	if [ "$(DEBUG_PERSIST)" = "1" ]; then \
		defaults write "$(BUNDLE_ID)" debug-logging-enabled -bool true; \
		echo "✅ Persistent debug logging enabled"; \
	fi; \
	echo "✅ Release artifacts ready: $(SIGNED_APP), $(ZIP_PATH)"; \
	if [ "$(INSTALL)" = "1" ]; then \
		mkdir -p "$$(dirname "$(APP_PATH)")"; \
		pkill -x "$(APP_NAME)" >/dev/null 2>&1 || true; \
		rm -rf "$(APP_PATH)"; \
		cp -R "$(SIGNED_APP)" "$(APP_PATH)"; \
		echo "✅ Installed release app: $(APP_PATH)"; \
	fi
