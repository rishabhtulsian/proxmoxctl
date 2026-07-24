#!/bin/sh
set -eu

binary=${1:-.build/debug/proxmoxctl}
case "$binary" in
    /*) ;;
    *) binary="$(pwd)/$binary" ;;
esac

test_dir=$(mktemp -d "${TMPDIR:-/tmp}/proxmoxctl-global-options.XXXXXX")
trap 'rm -rf "$test_dir"' EXIT HUP INT TERM
config="$test_dir/config.json"
printf '{"version":1,"hosts":[]}\n' >"$config"

expect_success() {
    label=$1
    shift
    if ! output=$("$@" 2>&1); then
        printf '%s failed:\n%s\n' "$label" "$output" >&2
        exit 1
    fi
}

expect_error_containing() {
    label=$1
    expected=$2
    shift 2
    if output=$("$@" 2>&1); then
        printf '%s unexpectedly succeeded\n' "$label" >&2
        exit 1
    fi
    case "$output" in
        *"$expected"*) ;;
        *)
            printf '%s returned the wrong error:\n%s\n' "$label" "$output" >&2
            exit 1
            ;;
    esac
}

expect_success "root --config" "$binary" --config "$config" host list
expect_success "leaf --config" "$binary" host list --config "$config"
expect_success "equivalent duplicate --config" \
    "$binary" --config "$config" host list --config "$test_dir/./config.json"
expect_error_containing "conflicting --config" "Conflicting config paths" \
    "$binary" --config "$config" host list --config "$test_dir/other.json"

expect_error_containing "root --verbose" "No default host" \
    "$binary" --config "$config" --verbose nodes
expect_error_containing "root -v" "No default host" \
    "$binary" --config "$config" -v nodes
expect_error_containing "leaf --verbose" "No default host" \
    "$binary" nodes --config "$config" --verbose
expect_error_containing "leaf -v" "No default host" \
    "$binary" nodes --config "$config" -v

interactive_output=$(
    printf '%s\n' \
        "--config \"$config\" host list" \
        "host list --config \"$config\"" \
        "--verbose --config \"$config\" nodes" \
        "exit" |
        "$binary" interactive --config "$config" 2>&1
)
case "$interactive_output" in
    *"Unknown option"*)
        printf 'interactive global-option parsing failed:\n%s\n' "$interactive_output" >&2
        exit 1
        ;;
esac

interactive_conflict=$(
    printf '%s\n' \
        "--config \"$config\" host list --config \"$test_dir/other.json\"" \
        "exit" |
        "$binary" interactive --config "$config" 2>&1
)
case "$interactive_conflict" in
    *"Conflicting config paths"*) ;;
    *)
        printf 'interactive conflict detection failed:\n%s\n' "$interactive_conflict" >&2
        exit 1
        ;;
esac

host_add_help=$("$binary" host add --help)
case "$host_add_help" in
    *"surrounding whitespace"*"HTTPS base URL"*"--replace"*) ;;
    *)
        printf 'host add help is missing validation or replacement guidance\n' >&2
        exit 1
        ;;
esac

guest_status_help=$("$binary" guest status --help)
case "$guest_status_help" in
    *"cluster"*"inventory is checked first"*"fallback"*) ;;
    *)
        printf 'guest status help is missing type-resolution guidance\n' >&2
        exit 1
        ;;
esac

printf 'global option integration checks passed\n'
