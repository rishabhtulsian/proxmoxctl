#!/usr/bin/env bash
set -euo pipefail

HELPER="${1:-./script/build_and_run.sh}"
BINARY="${2:-.build/debug/proxmoxctl}"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

case "$HELPER" in
  /*) ;;
  *) HELPER="$ROOT_DIR/${HELPER#./}" ;;
esac
case "$BINARY" in
  /*) ;;
  *) BINARY="$ROOT_DIR/${BINARY#./}" ;;
esac

TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/proxmoxctl-helper.XXXXXX")"
EXISTING_PID=""
HELPER_PID=""

cleanup() {
  if [ -n "$HELPER_PID" ] && kill -0 "$HELPER_PID" 2>/dev/null; then
    kill "$HELPER_PID" 2>/dev/null || true
    wait "$HELPER_PID" 2>/dev/null || true
  fi
  if [ -n "$EXISTING_PID" ] && kill -0 "$EXISTING_PID" 2>/dev/null; then
    kill "$EXISTING_PID" 2>/dev/null || true
    wait "$EXISTING_PID" 2>/dev/null || true
  fi
  rm -rf "$TEST_DIR"
}
trap cleanup EXIT HUP INT TERM

FIFO="$TEST_DIR/existing-input"
mkfifo "$FIFO"
"$BINARY" interactive <"$FIFO" >"$TEST_DIR/existing.out" 2>&1 &
EXISTING_PID=$!
exec 9>"$FIFO"

"$HELPER" run --help >/dev/null
if ! kill -0 "$EXISTING_PID" 2>/dev/null; then
  printf 'helper terminated an unrelated proxmoxctl process\n' >&2
  exit 1
fi

if [ -z "${PROXMOXCTL_OWNERSHIP_UNDER_VERIFY:-}" ]; then
  "$HELPER" --verify >/dev/null
  if ! kill -0 "$EXISTING_PID" 2>/dev/null; then
    printf 'helper verification terminated an unrelated proxmoxctl process\n' >&2
    exit 1
  fi
fi

EXIT_STUB="$TEST_DIR/exit-stub"
cat >"$EXIT_STUB" <<'EOF'
#!/bin/sh
exit 23
EOF
chmod +x "$EXIT_STUB"
set +e
PROXMOXCTL_TEST_APP_BINARY="$EXIT_STUB" "$HELPER" run >/dev/null 2>&1
RUN_STATUS=$?
set -e
if [ "$RUN_STATUS" -ne 23 ]; then
  printf 'foreground run returned %s instead of child status 23\n' "$RUN_STATUS" >&2
  exit 1
fi

CHILD_STUB="$TEST_DIR/child-stub"
cat >"$CHILD_STUB" <<EOF
#!/bin/sh
printf '%s\n' "\$\$" >"$TEST_DIR/child.pid"
trap 'printf cleaned >"$TEST_DIR/child.cleaned"; exit 0' HUP INT TERM
while :; do sleep 1; done
EOF
chmod +x "$CHILD_STUB"

LOG_STUB="$TEST_DIR/log-stub"
cat >"$LOG_STUB" <<'EOF'
#!/bin/sh
trap 'exit 0' HUP INT TERM
while :; do sleep 1; done
EOF
chmod +x "$LOG_STUB"

PROXMOXCTL_TEST_APP_BINARY="$CHILD_STUB" \
PROXMOXCTL_TEST_LOG_BINARY="$LOG_STUB" \
  "$HELPER" logs >"$TEST_DIR/helper.out" 2>&1 &
HELPER_PID=$!

for _ in $(seq 1 50); do
  [ -f "$TEST_DIR/child.pid" ] && break
  sleep 0.1
done
if [ ! -f "$TEST_DIR/child.pid" ]; then
  printf 'background helper child did not start\n' >&2
  exit 1
fi
CHILD_PID=$(<"$TEST_DIR/child.pid")

kill -TERM "$HELPER_PID"
wait "$HELPER_PID" 2>/dev/null || true
HELPER_PID=""

if kill -0 "$CHILD_PID" 2>/dev/null; then
  printf 'helper left its own background child running\n' >&2
  exit 1
fi
if [ ! -f "$TEST_DIR/child.cleaned" ]; then
  printf 'helper did not terminate its own child through the cleanup trap\n' >&2
  exit 1
fi

printf 'build helper process-ownership checks passed\n'
