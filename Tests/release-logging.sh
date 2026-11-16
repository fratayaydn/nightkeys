#!/bin/sh
set -eu

for executable in "$@"; do
    symbols=$(nm -u "$executable")
    if [ "$(basename "$executable")" = "nightkeysd" ] &&
        printf '%s\n' "$symbols" | grep -E '(_fprintf|___stderrp)$'; then
        echo "Release agent imports stderr symbols: $executable" >&2
        exit 1
    fi
    if printf '%s\n' "$symbols" | grep -E '(_os_log[^[:space:]]*|_NSLog[^[:space:]]*)'; then
        echo "Release executable imports logging symbols: $executable" >&2
        exit 1
    fi
done

echo "Passed release logging checks: no os_log or NSLog symbols, and no agent stderr imports."
