#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_PATH="${APP_PATH:-/Applications/GroqDictate.app}"
APP_EXECUTABLE="$APP_PATH/Contents/MacOS/GroqDictate"
BUILD_EXECUTABLE="$ROOT_DIR/.build/release/GroqDictate"
BUNDLE_ID="${BUNDLE_ID:-com.groqdictate}"
KEYCHAIN_SERVICE="${KEYCHAIN_SERVICE:-com.groqdictate}"
KEYCHAIN_ACCOUNT="${KEYCHAIN_ACCOUNT:-groq-api-key}"
TMP_BASE="${TMPDIR:-/tmp}"

LAUNCH_AGENT_PATH="${LAUNCH_AGENT_PATH:-$HOME/Library/LaunchAgents/com.groqdictate.plist}"
LAUNCH_AGENT_LABEL="${LAUNCH_AGENT_LABEL:-com.groqdictate}"
DEBUG_LOG_DIR="${DEBUG_LOG_DIR:-$HOME/Library/Logs/GroqDictate}"
DEBUG_STDOUT_PATH="${DEBUG_STDOUT_PATH:-$DEBUG_LOG_DIR/stdout.log}"
DEBUG_STDERR_PATH="${DEBUG_STDERR_PATH:-$DEBUG_LOG_DIR/stderr.log}"

DEBUG=0
FORCE=0
WITH_KEYCHAIN=1
WITH_TCC=1
RUN_TARGET="app"
CODESIGN_IDENTITY="${CODESIGN_IDENTITY:-}"
BOOT_DEBUG_ACTION="status"
RELOAD_AGENT=1

log() { printf '%s\n' "$*"; }
fail() { printf '❌ %s\n' "$*" >&2; exit 1; }

require_command() {
  command -v "$1" >/dev/null 2>&1 || fail "Missing required command: $1"
}

usage() {
  cat <<EOF
Usage: ./dev.sh <command> [options]

Commands:
  build            Build release binary
  install          Build + copy binary into app bundle
  run              Run app binary (installed app by default)
  rebuild          Build + install + run
  clean-state      Reset local app state (keychain/defaults/cache/temp/tcc)
  reset-and-run    clean-state + rebuild
  boot-debug       Configure login LaunchAgent debug logging (GROQDICTATE_DEBUG)

Options:
  --debug                  Set GROQDICTATE_DEBUG=1 when running
  --app-path <path>        App bundle path (default: /Applications/GroqDictate.app)
  --codesign <identity>    Codesign identity for install/rebuild
  --target <app|build>     Run installed app binary or .build binary (default: app)
  --yes                    Required for clean-state/reset-and-run
  --no-keychain            Skip keychain deletion in clean-state
  --no-tcc                 Skip tcc resets in clean-state
  --enable                 boot-debug: enable persistent debug logging
  --disable                boot-debug: disable persistent debug logging
  --status                 boot-debug: print current boot-debug status (default)
  --no-reload              boot-debug: edit plist only, do not reload launchctl
  -h, --help               Show this help

Examples:
  ./dev.sh rebuild --debug
  ./dev.sh clean-state --yes
  ./dev.sh reset-and-run --yes --debug
  ./dev.sh boot-debug --enable
  ./dev.sh boot-debug --disable
EOF
}

parse_common_flags() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --debug) DEBUG=1; shift ;;
      --app-path) APP_PATH="$2"; APP_EXECUTABLE="$APP_PATH/Contents/MacOS/GroqDictate"; shift 2 ;;
      --codesign) CODESIGN_IDENTITY="$2"; shift 2 ;;
      --target) RUN_TARGET="$2"; shift 2 ;;
      --yes) FORCE=1; shift ;;
      --no-keychain) WITH_KEYCHAIN=0; shift ;;
      --no-tcc) WITH_TCC=0; shift ;;
      --enable) BOOT_DEBUG_ACTION="enable"; shift ;;
      --disable) BOOT_DEBUG_ACTION="disable"; shift ;;
      --status) BOOT_DEBUG_ACTION="status"; shift ;;
      --no-reload) RELOAD_AGENT=0; shift ;;
      -h|--help) usage; exit 0 ;;
      *) fail "Unknown option: $1" ;;
    esac
  done
}

build_release() {
  require_command swift
  log "→ Building release binary"
  (
    cd "$ROOT_DIR"
    swift build -c release
  )
  [[ -f "$BUILD_EXECUTABLE" ]] || fail "Build output not found: $BUILD_EXECUTABLE"
  log "✅ Build complete"
}

stop_app() {
  pkill -x "GroqDictate" 2>/dev/null || true
  sleep 0.3
}

install_app() {
  require_command install
  [[ -d "$APP_PATH" ]] || fail "App bundle not found: $APP_PATH"
  [[ -f "$BUILD_EXECUTABLE" ]] || fail "Build output not found: $BUILD_EXECUTABLE"

  log "→ Stopping running GroqDictate"
  stop_app

  log "→ Installing binary into app bundle"
  install -m 755 "$BUILD_EXECUTABLE" "$APP_EXECUTABLE"

  if [[ -n "$CODESIGN_IDENTITY" ]]; then
    require_command codesign
    log "→ Signing app with identity: $CODESIGN_IDENTITY"
    codesign -s "$CODESIGN_IDENTITY" -f --deep "$APP_PATH"
  else
    log "→ Skipping codesign (pass --codesign to enable)"
  fi

  log "✅ Install complete"
}

run_binary() {
  local binary
  case "$RUN_TARGET" in
    app) binary="$APP_EXECUTABLE" ;;
    build) binary="$BUILD_EXECUTABLE" ;;
    *) fail "Invalid --target value: $RUN_TARGET (use app|build)" ;;
  esac

  [[ -x "$binary" ]] || fail "Executable not found: $binary"

  log "→ Stopping running GroqDictate"
  stop_app

  if [[ "$DEBUG" == "1" ]]; then
    log "→ Running with GROQDICTATE_DEBUG=1"
    GROQDICTATE_DEBUG=1 "$binary"
  else
    log "→ Running"
    "$binary"
  fi
}

clean_state() {
  [[ "$FORCE" == "1" ]] || fail "clean-state is destructive. Re-run with --yes"

  require_command defaults
  require_command rm

  log "→ Stopping GroqDictate"
  stop_app

  if [[ "$WITH_KEYCHAIN" == "1" ]]; then
    require_command security
    log "→ Removing API key from Keychain"
    security delete-generic-password -s "$KEYCHAIN_SERVICE" -a "$KEYCHAIN_ACCOUNT" 2>/dev/null || true
  else
    log "→ Skipping keychain deletion (--no-keychain)"
  fi

  log "→ Removing UserDefaults domain: $BUNDLE_ID"
  defaults delete "$BUNDLE_ID" 2>/dev/null || true

  log "→ Removing cache and HTTP storage"
  local paths=(
    "$HOME/Library/Caches/$BUNDLE_ID"
    "$HOME/Library/Caches/groq-dictate"
    "$HOME/Library/HTTPStorages/$BUNDLE_ID"
    "$HOME/Library/HTTPStorages/groq-dictate"
  )

  for path in "${paths[@]}"; do
    rm -rf "$path"
  done

  log "→ Removing temporary audio files"
  rm -f "$TMP_BASE/groqdictate.wav" "$TMP_BASE/groqdictate.flac"

  if [[ "$WITH_TCC" == "1" ]]; then
    require_command tccutil
    log "→ Resetting TCC permissions"
    tccutil reset Microphone "$BUNDLE_ID" 2>/dev/null || true
    tccutil reset Accessibility "$BUNDLE_ID" 2>/dev/null || true
    tccutil reset ListenEvent "$BUNDLE_ID" 2>/dev/null || true
  else
    log "→ Skipping TCC reset (--no-tcc)"
  fi

  log "✅ Clean slate complete"
}

boot_debug_status() {
  require_command python3
  [[ -f "$LAUNCH_AGENT_PATH" ]] || fail "LaunchAgent not found: $LAUNCH_AGENT_PATH"

  python3 - "$LAUNCH_AGENT_PATH" <<'PY'
import plistlib, sys
path = sys.argv[1]
with open(path, 'rb') as f:
    plist = plistlib.load(f)
env = plist.get('EnvironmentVariables', {}) or {}
print(f"LaunchAgent: {path}")
print(f"GROQDICTATE_DEBUG={env.get('GROQDICTATE_DEBUG', '(unset)')}")
print(f"StandardOutPath={plist.get('StandardOutPath', '(unset)')}")
print(f"StandardErrorPath={plist.get('StandardErrorPath', '(unset)')}")
PY

  local gui="gui/$(id -u)"
  if launchctl print "$gui/$LAUNCH_AGENT_LABEL" >/dev/null 2>&1; then
    log "launchctl: loaded ($gui/$LAUNCH_AGENT_LABEL)"
  else
    log "launchctl: not loaded ($gui/$LAUNCH_AGENT_LABEL)"
  fi
}

boot_debug() {
  require_command python3
  [[ -f "$LAUNCH_AGENT_PATH" ]] || fail "LaunchAgent not found: $LAUNCH_AGENT_PATH"

  mkdir -p "$DEBUG_LOG_DIR"

  case "$BOOT_DEBUG_ACTION" in
    enable)
      log "→ Enabling persistent debug logging in LaunchAgent"
      python3 - "$LAUNCH_AGENT_PATH" "$DEBUG_STDOUT_PATH" "$DEBUG_STDERR_PATH" <<'PY'
import plistlib, sys
path, stdout_path, stderr_path = sys.argv[1:4]
with open(path, 'rb') as f:
    plist = plistlib.load(f)
env = dict(plist.get('EnvironmentVariables', {}) or {})
env['GROQDICTATE_DEBUG'] = '1'
plist['EnvironmentVariables'] = env
plist['StandardOutPath'] = stdout_path
plist['StandardErrorPath'] = stderr_path
with open(path, 'wb') as f:
    plistlib.dump(plist, f, sort_keys=False)
PY
      ;;
    disable)
      log "→ Disabling persistent debug logging in LaunchAgent"
      python3 - "$LAUNCH_AGENT_PATH" <<'PY'
import plistlib, sys
path = sys.argv[1]
with open(path, 'rb') as f:
    plist = plistlib.load(f)
env = dict(plist.get('EnvironmentVariables', {}) or {})
env.pop('GROQDICTATE_DEBUG', None)
if env:
    plist['EnvironmentVariables'] = env
else:
    plist.pop('EnvironmentVariables', None)
plist.pop('StandardOutPath', None)
plist.pop('StandardErrorPath', None)
with open(path, 'wb') as f:
    plistlib.dump(plist, f, sort_keys=False)
PY
      ;;
    status)
      ;;
    *)
      fail "Invalid boot-debug action: $BOOT_DEBUG_ACTION"
      ;;
  esac

  if [[ "$BOOT_DEBUG_ACTION" != "status" && "$RELOAD_AGENT" == "1" ]]; then
    local gui="gui/$(id -u)"
    log "→ Reloading LaunchAgent: $LAUNCH_AGENT_LABEL"
    launchctl bootout "$gui/$LAUNCH_AGENT_LABEL" 2>/dev/null || true

    if launchctl bootstrap "$gui" "$LAUNCH_AGENT_PATH" 2>/dev/null; then
      launchctl kickstart -k "$gui/$LAUNCH_AGENT_LABEL" 2>/dev/null || true
      log "✅ LaunchAgent reloaded"
    else
      log "→ bootstrap skipped/failed, attempting kickstart on existing service"
      launchctl kickstart -k "$gui/$LAUNCH_AGENT_LABEL" 2>/dev/null || true
      log "✅ LaunchAgent refresh attempted"
    fi
  fi

  boot_debug_status
}

main() {
  [[ $# -ge 1 ]] || { usage; exit 1; }

  local cmd="$1"
  shift

  parse_common_flags "$@"

  case "$cmd" in
    build)
      build_release
      ;;
    install)
      build_release
      install_app
      ;;
    run)
      run_binary
      ;;
    rebuild)
      build_release
      install_app
      run_binary
      ;;
    clean-state)
      clean_state
      ;;
    reset-and-run)
      clean_state
      build_release
      install_app
      run_binary
      ;;
    boot-debug)
      boot_debug
      ;;
    -h|--help|help)
      usage
      ;;
    *)
      fail "Unknown command: $cmd"
      ;;
  esac
}

main "$@"
