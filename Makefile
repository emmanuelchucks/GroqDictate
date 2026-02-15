.POSIX:
SHELL := /bin/bash

APP_NAME        = GroqDictate
SCHEME          = $(APP_NAME)
PROJECT         = $(APP_NAME).xcodeproj
BUNDLE_ID       = com.groqdictate
INSTALL_PATH   ?= /Applications/$(APP_NAME).app

KEYCHAIN_SERVICE = com.groqdictate
KEYCHAIN_ACCOUNT = groq-api-key

LAUNCH_AGENT_LABEL = com.groqdictate
LAUNCH_AGENT_PATH  = $(HOME)/Library/LaunchAgents/com.groqdictate.plist
DEBUG_LOG_DIR      = $(HOME)/Library/Logs/GroqDictate
DEBUG_STDOUT_PATH  = $(DEBUG_LOG_DIR)/stdout.log
DEBUG_STDERR_PATH  = $(DEBUG_LOG_DIR)/stderr.log

# Resolve built .app from DerivedData
BUILD_DIR = $(shell xcodebuild -project $(PROJECT) -scheme $(SCHEME) -configuration Release -showBuildSettings 2>/dev/null | awk '/^ *BUILT_PRODUCTS_DIR/ { print $$NF }')
BUILD_APP = $(BUILD_DIR)/$(APP_NAME).app

.PHONY: generate build install run run-debug clean \
        clean-state reset-and-run \
        boot-debug-enable boot-debug-disable boot-debug-status help

# ── Generate xcodeproj from project.yml ───────────────
generate:
	xcodegen generate

# ── Build ─────────────────────────────────────────────
build:
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) -configuration Release build

# ── Install into /Applications ────────────────────────
install: build
	-@pkill -x $(APP_NAME) 2>/dev/null; sleep 0.3
	rm -rf "$(INSTALL_PATH)"
	cp -R "$(BUILD_APP)" "$(INSTALL_PATH)"
	@echo "✅ Installed to $(INSTALL_PATH)"

# ── Run ───────────────────────────────────────────────
run:
	@test -x "$(INSTALL_PATH)/Contents/MacOS/$(APP_NAME)" || { echo "❌ Not installed. Run: make install"; exit 1; }
	-@pkill -x $(APP_NAME) 2>/dev/null; sleep 0.3
	open "$(INSTALL_PATH)"

run-debug:
	@test -x "$(INSTALL_PATH)/Contents/MacOS/$(APP_NAME)" || { echo "❌ Not installed. Run: make install"; exit 1; }
	-@pkill -x $(APP_NAME) 2>/dev/null; sleep 0.3
	GROQDICTATE_DEBUG=1 "$(INSTALL_PATH)/Contents/MacOS/$(APP_NAME)"

rebuild: install run

rebuild-debug: install run-debug

# ── Clean ─────────────────────────────────────────────
clean:
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) clean
	rm -rf DerivedData

# ── Clean state (destructive — requires FORCE=1) ─────
clean-state:
	@test "$(FORCE)" = "1" || { echo "❌ Destructive. Run with FORCE=1"; exit 1; }
	-@pkill -x $(APP_NAME) 2>/dev/null; sleep 0.3
	-security delete-generic-password -s "$(KEYCHAIN_SERVICE)" -a "$(KEYCHAIN_ACCOUNT)" 2>/dev/null
	-defaults delete "$(BUNDLE_ID)" 2>/dev/null
	rm -rf "$(HOME)/Library/Caches/$(BUNDLE_ID)" \
	       "$(HOME)/Library/Caches/groq-dictate" \
	       "$(HOME)/Library/HTTPStorages/$(BUNDLE_ID)" \
	       "$(HOME)/Library/HTTPStorages/groq-dictate"
	rm -f "$${TMPDIR:-/tmp}/groqdictate.wav" "$${TMPDIR:-/tmp}/groqdictate.flac"
	-tccutil reset Microphone "$(BUNDLE_ID)" 2>/dev/null
	-tccutil reset Accessibility "$(BUNDLE_ID)" 2>/dev/null
	-tccutil reset ListenEvent "$(BUNDLE_ID)" 2>/dev/null
	@echo "✅ Clean slate"

reset-and-run: clean-state rebuild

# ── Boot debug (LaunchAgent) ─────────────────────────
boot-debug-status:
	@test -f "$(LAUNCH_AGENT_PATH)" || { echo "❌ LaunchAgent not found: $(LAUNCH_AGENT_PATH)"; exit 1; }
	@python3 -c "\
	import plistlib; \
	plist = plistlib.load(open('$(LAUNCH_AGENT_PATH)', 'rb')); \
	env = plist.get('EnvironmentVariables', {}) or {}; \
	print(f'LaunchAgent: $(LAUNCH_AGENT_PATH)'); \
	print(f'GROQDICTATE_DEBUG={env.get(\"GROQDICTATE_DEBUG\", \"(unset)\")}'); \
	print(f'StandardOutPath={plist.get(\"StandardOutPath\", \"(unset)\")}'); \
	print(f'StandardErrorPath={plist.get(\"StandardErrorPath\", \"(unset)\")}')"
	@if launchctl print "gui/$$(id -u)/$(LAUNCH_AGENT_LABEL)" >/dev/null 2>&1; then \
		echo "launchctl: loaded"; \
	else \
		echo "launchctl: not loaded"; \
	fi

boot-debug-enable:
	@test -f "$(LAUNCH_AGENT_PATH)" || { echo "❌ LaunchAgent not found: $(LAUNCH_AGENT_PATH)"; exit 1; }
	@mkdir -p "$(DEBUG_LOG_DIR)"
	@python3 -c "\
	import plistlib; \
	path = '$(LAUNCH_AGENT_PATH)'; \
	plist = plistlib.load(open(path, 'rb')); \
	env = dict(plist.get('EnvironmentVariables', {}) or {}); \
	env['GROQDICTATE_DEBUG'] = '1'; \
	plist['EnvironmentVariables'] = env; \
	plist['StandardOutPath'] = '$(DEBUG_STDOUT_PATH)'; \
	plist['StandardErrorPath'] = '$(DEBUG_STDERR_PATH)'; \
	plistlib.dump(plist, open(path, 'wb'), sort_keys=False)"
	@gui="gui/$$(id -u)"; \
	launchctl bootout "$$gui/$(LAUNCH_AGENT_LABEL)" 2>/dev/null || true; \
	launchctl bootstrap "$$gui" "$(LAUNCH_AGENT_PATH)" 2>/dev/null || true; \
	launchctl kickstart -k "$$gui/$(LAUNCH_AGENT_LABEL)" 2>/dev/null || true
	@echo "✅ Boot debug enabled"
	@$(MAKE) --no-print-directory boot-debug-status

boot-debug-disable:
	@test -f "$(LAUNCH_AGENT_PATH)" || { echo "❌ LaunchAgent not found: $(LAUNCH_AGENT_PATH)"; exit 1; }
	@python3 -c "\
	import plistlib; \
	path = '$(LAUNCH_AGENT_PATH)'; \
	plist = plistlib.load(open(path, 'rb')); \
	env = dict(plist.get('EnvironmentVariables', {}) or {}); \
	env.pop('GROQDICTATE_DEBUG', None); \
	plist['EnvironmentVariables'] = env if env else plist.pop('EnvironmentVariables', None); \
	plist.pop('StandardOutPath', None); \
	plist.pop('StandardErrorPath', None); \
	plistlib.dump(plist, open(path, 'wb'), sort_keys=False)"
	@gui="gui/$$(id -u)"; \
	launchctl bootout "$$gui/$(LAUNCH_AGENT_LABEL)" 2>/dev/null || true; \
	launchctl bootstrap "$$gui" "$(LAUNCH_AGENT_PATH)" 2>/dev/null || true; \
	launchctl kickstart -k "$$gui/$(LAUNCH_AGENT_LABEL)" 2>/dev/null || true
	@echo "✅ Boot debug disabled"
	@$(MAKE) --no-print-directory boot-debug-status

# ── Help ──────────────────────────────────────────────
help:
	@echo "Usage: make <target> [VAR=value ...]"
	@echo ""
	@echo "Targets:"
	@echo "  generate             Regenerate xcodeproj from project.yml"
	@echo "  build                Build release via xcodebuild"
	@echo "  install              Build + copy .app to /Applications"
	@echo "  run                  Launch installed app"
	@echo "  run-debug            Run with GROQDICTATE_DEBUG=1"
	@echo "  rebuild              Build + install + run"
	@echo "  rebuild-debug        Build + install + run with debug"
	@echo "  clean                Clean build artifacts"
	@echo "  clean-state          Reset keychain/defaults/cache/tcc (needs FORCE=1)"
	@echo "  reset-and-run        clean-state + rebuild (needs FORCE=1)"
	@echo "  boot-debug-status    Show LaunchAgent debug config"
	@echo "  boot-debug-enable    Enable persistent debug logging"
	@echo "  boot-debug-disable   Disable persistent debug logging"
	@echo ""
	@echo "Variables:"
	@echo "  INSTALL_PATH         Install location (default: /Applications/GroqDictate.app)"
	@echo "  FORCE=1              Required for clean-state/reset-and-run"
