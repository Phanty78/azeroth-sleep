#!/usr/bin/env bash
# Container entrypoint: config log, initial thaw, wake listeners, then monitor.
set -u

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=sleep-common.sh
. "$SCRIPT_DIR/sleep-common.sh"

log INFO "starting azeroth-sleep supervisor"
log INFO "targets: $(targets | tr '\n' ' ')"
log INFO "idle timeout: ${SLEEP_IDLE_TIMEOUT}s, check interval: ${SLEEP_CHECK_INTERVAL}s"
log INFO "listeners: :${SLEEP_LISTEN_AUTH} -> ${SLEEP_BACKEND_AUTH}, :${SLEEP_LISTEN_WORLD} -> ${SLEEP_BACKEND_WORLD}"

# Never leave a frozen stack behind a proxy that just (re)started.
"$SCRIPT_DIR/thaw.sh" --quiet

socat -d -d "TCP4-LISTEN:${SLEEP_LISTEN_AUTH},fork,reuseaddr,nodelay" \
    SYSTEM:"'$SCRIPT_DIR/bridge.sh $SLEEP_BACKEND_AUTH'" &
LISTENER_AUTH_PID=$!
socat -d -d "TCP4-LISTEN:${SLEEP_LISTEN_WORLD},fork,reuseaddr,nodelay" \
    SYSTEM:"'$SCRIPT_DIR/bridge.sh $SLEEP_BACKEND_WORLD'" &
LISTENER_WORLD_PID=$!
export LISTENER_AUTH_PID LISTENER_WORLD_PID

exec "$SCRIPT_DIR/monitor.sh"
