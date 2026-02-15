.POSIX:
SHELL := /bin/bash

# Paths
APP_PATH         ?= /Applications/GroqDictate.app
APP_EXECUTABLE    = $(APP_PATH)/Contents/MacOS/GroqDictate
BUILD_EXECUTABLE  = .build/release/GroqDictate
BUNDLE_ID        ?= com.groqdictate
KEYCHAIN_SERVICE ?= com.groqdictate
KEYCHAIN_ACCOUNT ?= groq-api-key
CODESIGN_IDENTITY ?=

# LaunchAgent / debug logging
LAUNCH_AGENT_LABEL ?= com.groqdictate
LAUNCH_AGENT_PATH  ?= $(HOME)/Library/LaunchAgents/com.groqdictate.plist
DEBUG_LOG_DIR      ?= $(HOME)/Library/Logs/GroqDictate
DEBUG_STDOUT_PATH  ?= $(DEBUG_LOG_DIR)/stdout.log
DEBUG_STDERR_PATH  ?= $(DEBUG_LOG_DIR)/stderr.log

# ── Build ─────────────────────────────────────────────
.PHONY: build install run rebuild clean-state reset-and-run \
        boot-debug-enable boot-debug-disable boot-debug-status help

build:
	swift build -c release
	@test -f "$(BUILD_EXECUTABLE)" || { echo "❌ Build output not found"; exit 1; }
	@echo "✅ Build complete"

# ── Install ───────────────────────────────────────────
install: build
	@test -d "$(APP_PATH)" || { echo "❌ App bundle not found: $(APP_PATH)"; exit 1; }
	-@pkill -x GroqDictate 2>/dev/null; sleep 0.3
	install -m 755 "$(BUILD_EXECUTABLE)" "$(APP_EXECUTABLE)"
	@if [ -n "$(CODESIGN_IDENTITY)" ]; then \
		echo "→ Signing with: $(CODESIGN_IDENTITY)"; \
		codesign -s "$(CODESIGN_IDENTITY)" -f --deep "$(APP_PATH)"; \
	fi
	@echo "✅ Install complete"

# ── Run ───────────────────────────────────────────────
run:
	@test -x "$(APP_EXECUTABLE)" || { echo "❌ Executable not found: $(APP_EXECUTABLE)"; exit 1; }
	-@pkill -x GroqDictate 2>/dev/null; sleep 0.3
	$(APP_EXECUTABLE)

run-debug:
	@test -x "$(APP_EXECUTABLE)" || { echo "❌ Executable not found: $(APP_EXECUTABLE)"; exit 1; }
	-@pkill -x GroqDictate 2>/dev/null; sleep 0.3
	GROQDICTATE_DEBUG=1 $(APP_EXECUTABLE)

run-build:
	@test -x "$(BUILD_EXECUTABLE)" || { echo "❌ Executable not found: $(BUILD_EXECUTABLE)"; exit 1; }
	-@pkill -x GroqDictate 2>/dev/null; sleep 0.3
	$(BUILD_EXECUTABLE)

run-build-debug:
	@test -x "$(BUILD_EXECUTABLE)" || { echo "❌ Executable not found: $(BUILD_EXECUTABLE)"; exit 1; }
	-@pkill -x GroqDictate 2>/dev/null; sleep 0.3
	GROQDICTATE_DEBUG=1 $(BUILD_EXECUTABLE)

# ── Compound targets ─────────────────────────────────
rebuild: install run

rebuild-debug: install run-debug

# ── Clean state (destructive — requires FORCE=1) ─────
clean-state:
	@test "$(FORCE)" = "1" || { echo "❌ Destructive. Run with FORCE=1"; exit 1; }
	-@pkill -x GroqDictate 2>/dev/null; sleep 0.3
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
	import plistlib, sys; \
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
	@echo "  build                Build release binary"
	@echo "  install              Build + copy into app bundle"
	@echo "  run                  Run installed app"
	@echo "  run-debug            Run installed app with GROQDICTATE_DEBUG=1"
	@echo "  run-build            Run .build binary directly"
	@echo "  run-build-debug      Run .build binary with GROQDICTATE_DEBUG=1"
	@echo "  rebuild              Build + install + run"
	@echo "  rebuild-debug        Build + install + run with debug"
	@echo "  clean-state          Reset keychain/defaults/cache/tcc (needs FORCE=1)"
	@echo "  reset-and-run        clean-state + rebuild (needs FORCE=1)"
	@echo "  boot-debug-status    Show LaunchAgent debug config"
	@echo "  boot-debug-enable    Enable persistent debug logging"
	@echo "  boot-debug-disable   Disable persistent debug logging"
	@echo ""
	@echo "Variables:"
	@echo "  APP_PATH             App bundle path (default: /Applications/GroqDictate.app)"
	@echo "  CODESIGN_IDENTITY    Codesign identity for install"
	@echo "  FORCE=1              Required for clean-state/reset-and-run"
