#!/usr/bin/env bash
# Idempotently unpause every configured target container.
set -u

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=sleep-common.sh
. "$SCRIPT_DIR/sleep-common.sh"

quiet=0
for arg in "$@"; do
    case "$arg" in
        --quiet | -q) quiet=1 ;;
        *)
            log ERROR "unknown argument '$arg'"
            exit 2
            ;;
    esac
done

unpaused=0
errors=0

while IFS= read -r name; do
    [ -n "$name" ] || continue
    # Attempt unpause unconditionally: idempotent, and immune to inspect races.
    if output=$(docker unpause "$name" 2>&1); then
        log INFO "[THAW] $name unpaused"
        unpaused=$((unpaused + 1))
        continue
    fi
    # Race with another thaw: the daemon answer is not a real error.
    if printf '%s' "$output" | grep -qi 'is not paused'; then
        continue
    fi
    log ERROR "failed to unpause '$name': $output"
    errors=$((errors + 1))
done < <(targets)

if [ "$quiet" -eq 0 ]; then
    log INFO "[THAW] summary: $unpaused container(s) unpaused, $errors error(s)"
fi

[ "$errors" -eq 0 ] || exit 1
exit 0
