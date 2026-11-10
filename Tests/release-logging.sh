#!/bin/sh
set -eu

for executable in "$@"; do
    symbols=$(nm -u "$executable")
    if printf '%s\n' "$symbols" | grep -E '(_os_log[^[:space:]]*|_NSLog[^[:space:]]*)'; then
        echo "Release executable imports logging symbols: $executable" >&2
        exit 1
    fi
done

echo "Passed release logging checks: no os_log or NSLog symbols."
