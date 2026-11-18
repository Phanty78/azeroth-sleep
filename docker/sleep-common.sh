#!/usr/bin/env bash
# Shared defaults and helpers for the azeroth-sleep Docker supervisor.

# Target containers, separated by spaces and/or commas.
SLEEP_TARGET_CONTAINERS="${SLEEP_TARGET_CONTAINERS:-ac-worldserver ac-authserver}"
# Seconds without client connections before freezing; 0 disables freezing.
SLEEP_IDLE_TIMEOUT="${SLEEP_IDLE_TIMEOUT:-600}"
# Seconds between monitor iterations.
SLEEP_CHECK_INTERVAL="${SLEEP_CHECK_INTERVAL:-30}"
# Ports listened on inside the ac-sleep container.
SLEEP_LISTEN_AUTH="${SLEEP_LISTEN_AUTH:-3724}"
SLEEP_LISTEN_WORLD="${SLEEP_LISTEN_WORLD:-8085}"
# Backends bridged to when a client connects.
SLEEP_BACKEND_AUTH="${SLEEP_BACKEND_AUTH:-ac-authserver:3724}"
SLEEP_BACKEND_WORLD="${SLEEP_BACKEND_WORLD:-ac-worldserver:8085}"
# Never pause/unpause a container whose name matches this pattern.
SLEEP_PROTECTED_PATTERN='(ac-sleep|database|mysql|mariadb|db-import)'

# log LEVEL message... -> one timestamped line on stderr (captured by docker logs).
log() {
    local level="${1:-INFO}"
    shift || true
    printf '%s [%s] %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$level" "$*" >&2
}

# targets -> one container name per line, protected names refused.
targets() {
    local name
    # Word splitting on spaces is intentional here (comma split above).
    # shellcheck disable=SC2086
    for name in ${SLEEP_TARGET_CONTAINERS//,/ }; do
        [ -n "$name" ] || continue
        if printf '%s' "$name" | grep -Eq "$SLEEP_PROTECTED_PATTERN"; then
            log ERROR "refusing to manage protected container '$name'"
            continue
        fi
        printf '%s\n' "$name"
    done
}

# container_state NAME -> "running false" / "paused true" (docker inspect format).
container_state() {
    docker inspect -f '{{.State.Status}} {{.State.Paused}}' "$1" 2>/dev/null
}
