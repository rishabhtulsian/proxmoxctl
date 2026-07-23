#!/usr/bin/env bash
set -euo pipefail

APP_BINARY="${1:?usage: $0 /path/to/proxmoxctl}"
TEST_ROOT="${TMPDIR:-/tmp}"
TEST_ROOT="${TEST_ROOT%/}"
TEST_DIR="$(mktemp -d "$TEST_ROOT/proxmoxctl-timeout-test.XXXXXX")"

cleanup() {
  case "$TEST_DIR" in
    "$TEST_ROOT"/proxmoxctl-timeout-test.*)
      /bin/rm -rf -- "$TEST_DIR"
      ;;
    *)
      echo "Refusing to remove unexpected test directory: $TEST_DIR" >&2
      ;;
  esac
}
trap cleanup EXIT

CONFIG_PATH="$TEST_DIR/config.json"
OUTPUT="$("$APP_BINARY" config set-timeout 7.5 --config "$CONFIG_PATH")"
test "$OUTPUT" = "API timeout is now 7.5 seconds"
test "$(/usr/bin/plutil -extract apiTimeoutSeconds raw -o - "$CONFIG_PATH")" = "7.500000"

BEFORE_HASH="$(/usr/bin/shasum -a 256 "$CONFIG_PATH")"
if "$APP_BINARY" config set-timeout 0 --config "$CONFIG_PATH" >/dev/null 2>&1; then
  echo "Expected zero timeout to fail" >&2
  exit 1
fi
AFTER_HASH="$(/usr/bin/shasum -a 256 "$CONFIG_PATH")"
test "$BEFORE_HASH" = "$AFTER_HASH"

printf 'config set-timeout 9\nexit\n' |
  "$APP_BINARY" interactive --config "$CONFIG_PATH" >/dev/null
test "$(/usr/bin/plutil -extract apiTimeoutSeconds raw -o - "$CONFIG_PATH")" = "9"

echo "Verified config set-timeout"
