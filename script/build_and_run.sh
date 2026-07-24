#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-run}"
APP_NAME="proxmoxctl"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CHILD_PID=""
DIAGNOSTIC_PID=""

cd "$ROOT_DIR"

if [ -z "${DEVELOPER_DIR:-}" ] && [ -d "/Applications/Xcode.app/Contents/Developer" ]; then
  export DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer"
fi

cleanup_children() {
  local pid
  for pid in "$DIAGNOSTIC_PID" "$CHILD_PID"; do
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
      kill "$pid" 2>/dev/null || true
      wait "$pid" 2>/dev/null || true
    fi
  done
}

run_with_diagnostics() {
  local predicate="$1"
  shift

  "$APP_BINARY" "$@" &
  CHILD_PID=$!
  "$LOG_BINARY" stream --info --style compact --predicate "$predicate" &
  DIAGNOSTIC_PID=$!

  trap cleanup_children EXIT
  trap 'exit 129' HUP
  trap 'exit 130' INT
  trap 'exit 143' TERM

  wait "$DIAGNOSTIC_PID"
}

if [ -n "${PROXMOXCTL_TEST_APP_BINARY:-}" ]; then
  APP_BINARY="$PROXMOXCTL_TEST_APP_BINARY"
else
  swift build
  APP_BINARY="$(swift build --show-bin-path)/$APP_NAME"
fi
LOG_BINARY="${PROXMOXCTL_TEST_LOG_BINARY:-/usr/bin/log}"

case "$MODE" in
  run)
    "$APP_BINARY" "${@:2}"
    ;;
  --debug|debug)
    lldb -- "$APP_BINARY" "${@:2}"
    ;;
  --logs|logs)
    run_with_diagnostics "process == \"$APP_NAME\"" "${@:2}"
    ;;
  --telemetry|telemetry)
    run_with_diagnostics "subsystem == \"com.tulsian.proxmoxctl\"" "${@:2}"
    ;;
  --verify|verify)
    "$APP_BINARY" --help >/dev/null
    echo "Verified $APP_NAME help"
    "$ROOT_DIR/script/test_config_timeout.sh" "$APP_BINARY"
    sh "$ROOT_DIR/script/test_global_options.sh" "$APP_BINARY"
    sh "$ROOT_DIR/script/test_lifecycle_confirmation.sh" "$APP_BINARY"
    PROXMOXCTL_OWNERSHIP_UNDER_VERIFY=1 \
      bash "$ROOT_DIR/script/test_build_helper_process_ownership.sh" "$0" "$APP_BINARY"
    ;;
  *)
    echo "usage: $0 [run|--debug|--logs|--telemetry|--verify] [proxmoxctl args...]" >&2
    exit 2
    ;;
esac
