#!/usr/bin/env bash
# socat SYSTEM handler: wake the stack, then bridge the client to the backend.
set -u

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=sleep-common.sh
. "$SCRIPT_DIR/sleep-common.sh"

if [ "$#" -lt 1 ] || [ -z "$1" ]; then
    log ERROR "usage: bridge.sh <host:port>"
    exit 2
fi

log INFO "[CONN] new connection, waking stack"
"$SCRIPT_DIR/thaw.sh" --quiet
exec socat - "TCP4:$1,nodelay"
