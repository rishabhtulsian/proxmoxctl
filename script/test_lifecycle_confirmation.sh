#!/bin/sh
set -eu

binary=${1:-.build/debug/proxmoxctl}
case "$binary" in
    /*) ;;
    *) binary="$(pwd)/$binary" ;;
esac

test_dir=$(mktemp -d "${TMPDIR:-/tmp}/proxmoxctl-lifecycle.XXXXXX")
trap 'rm -rf "$test_dir"' EXIT HUP INT TERM
config="$test_dir/config.json"
printf '{"version":1,"hosts":[]}\n' >"$config"

for operation in start shutdown stop reboot reset suspend resume; do
    if output=$(
        printf '' |
            "$binary" --config "$config" guest "$operation" 100 --node unreachable.invalid 2>&1
    ); then
        printf 'guest %s unexpectedly succeeded without --yes\n' "$operation" >&2
        exit 1
    fi
    case "$output" in
        *"No default host is configured"*) ;;
        *)
            printf 'guest %s reached an unexpected path:\n%s\n' "$operation" "$output" >&2
            exit 1
            ;;
    esac
done

printf 'lifecycle non-mutation smoke checks passed\n'
