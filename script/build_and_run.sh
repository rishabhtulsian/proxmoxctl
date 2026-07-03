#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-run}"
APP_NAME="proxmoxctl"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

cd "$ROOT_DIR"

if [ -z "${DEVELOPER_DIR:-}" ] && [ -d "/Applications/Xcode.app/Contents/Developer" ]; then
  export DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer"
fi

pkill -x "$APP_NAME" >/dev/null 2>&1 || true

swift build
APP_BINARY="$(swift build --show-bin-path)/$APP_NAME"

case "$MODE" in
  run)
    "$APP_BINARY" "${@:2}"
    ;;
  --debug|debug)
    lldb -- "$APP_BINARY" "${@:2}"
    ;;
  --logs|logs)
    "$APP_BINARY" "${@:2}" &
    /usr/bin/log stream --info --style compact --predicate "process == \"$APP_NAME\""
    ;;
  --telemetry|telemetry)
    "$APP_BINARY" "${@:2}" &
    /usr/bin/log stream --info --style compact --predicate "subsystem == \"com.tulsian.proxmoxctl\""
    ;;
  --verify|verify)
    "$APP_BINARY" --help >/dev/null
    echo "Verified $APP_NAME help"
    ;;
  *)
    echo "usage: $0 [run|--debug|--logs|--telemetry|--verify] [proxmoxctl args...]" >&2
    exit 2
    ;;
esac
