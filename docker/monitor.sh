#!/usr/bin/env bash
# Idle monitor: supervises wake listeners, freezes/thaws targets, reports status.
set -u

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=sleep-common.sh
. "$SCRIPT_DIR/sleep-common.sh"

LAST_ACTIVITY_FILE=/tmp/last_activity

# Listener PIDs are exported by entrypoint.sh so this process owns (and can kill)
# the already-running socat listeners.
listener_auth_pid="${LISTENER_AUTH_PID:-}"
listener_world_pid="${LISTENER_WORLD_PID:-}"
all_paused_logged=0

usage() {
    cat >&2 <<'EOF'
Usage: monitor.sh [loop|status|freeze|wake]
  loop    run the idle monitor (default)
  status  print current target/listener state
  freeze  pause all targets once
  wake    unpause all targets once
EOF
}

start_listener() {
    local port=$1 backend=$2 pid_var=$3
    socat -d -d "TCP4-LISTEN:${port},fork,reuseaddr,nodelay" \
        SYSTEM:"'$SCRIPT_DIR/bridge.sh $backend'" &
    printf -v "$pid_var" '%s' "$!"
}

port_listening() {
    local port=$1
    ss -Hltn "sport = :$port" 2>/dev/null | grep -q .
}

# supervise_listener PORT BACKEND PID_VAR -> 0 if listening, 1 if respawned/failed.
supervise_listener() {
    local port=$1 backend=$2 pid_var=$3
    local output
    if ! output=$(ss -Hltn "sport = :$port" 2>/dev/null); then
        log ERROR "[SUPERVISOR] cannot inspect listener :$port"
        return 1
    fi
    [ -n "$output" ] && return 0
    start_listener "$port" "$backend" "$pid_var"
    log INFO "[SUPERVISOR] listener :$port respawned"
    return 1
}

# count_connections -> number of established client sockets, nonzero on ss failure.
count_connections() {
    local output
    if ! output=$(ss -Htn state established \
        "( sport = :$SLEEP_LISTEN_WORLD or sport = :$SLEEP_LISTEN_AUTH )" 2>/dev/null); then
        return 1
    fi
    printf '%s\n' "$output" | awk 'NF { n++ } END { print n + 0 }'
}

read_last_activity() {
    local value
    value=$(cat "$LAST_ACTIVITY_FILE" 2>/dev/null) || value=""
    case "$value" in
        '' | *[!0-9]*) return 1 ;;
    esac
    printf '%s' "$value"
}

mark_activity() {
    date +%s >"$LAST_ACTIVITY_FILE"
}

thaw_quiet() {
    "$SCRIPT_DIR/thaw.sh" --quiet || true
}

cleanup() {
    trap - TERM INT
    thaw_quiet
    [ -n "$listener_auth_pid" ] && kill "$listener_auth_pid" 2>/dev/null
    [ -n "$listener_world_pid" ] && kill "$listener_world_pid" 2>/dev/null
    log INFO "[EXIT] leaving targets awake"
    exit 0
}

# ---------------------------------------------------------------- modes

mode_status() {
    local name state status paused conns idle now last listeners mode
    local rc=0

    if ! docker info >/dev/null 2>&1; then
        log ERROR "docker daemon unreachable"
        return 1
    fi

    while IFS= read -r name; do
        if ! state=$(container_state "$name"); then
            printf '%s: unknown\n' "$name"
            continue
        fi
        status=${state%% *}
        paused=${state##* }
        if [ "$status" = running ] && [ "$paused" = true ]; then
            # Defensive: never misreport a paused container as running.
            status=paused
        fi
        printf '%s: %s\n' "$name" "$status"
    done < <(targets)

    if conns=$(count_connections); then
        :
    else
        log ERROR "cannot count client connections"
        conns=0
    fi
    printf 'client connections: %s\n' "$conns"

    now=$(date +%s)
    if last=$(read_last_activity); then
        [ "$last" -le "$now" ] || last=$now
        idle=$((now - last))
    else
        idle=0
    fi
    printf 'idle: %ss / %ss\n' "$idle" "$SLEEP_IDLE_TIMEOUT"

    if port_listening "$SLEEP_LISTEN_AUTH"; then
        listeners=":$SLEEP_LISTEN_AUTH ok"
    else
        listeners=":$SLEEP_LISTEN_AUTH down"
    fi
    if port_listening "$SLEEP_LISTEN_WORLD"; then
        listeners="$listeners, :$SLEEP_LISTEN_WORLD ok"
    else
        listeners="$listeners, :$SLEEP_LISTEN_WORLD down"
    fi
    printf 'listeners: %s\n' "$listeners"

    if [ "$SLEEP_IDLE_TIMEOUT" -eq 0 ]; then
        mode="disabled"
    else
        mode="enabled"
    fi
    printf 'mode: freeze %s\n' "$mode"

    return "$rc"
}

mode_freeze() {
    local name state failed=0
    while IFS= read -r name; do
        if ! state=$(container_state "$name"); then
            log ERROR "cannot inspect container '$name'"
            failed=1
            continue
        fi
        case "$state" in
            *' true')
                log INFO "[FREEZE] $name already paused"
                continue
                ;;
        esac
        if docker pause "$name" >/dev/null 2>&1; then
            log INFO "[FREEZE] $name paused (manual)"
        else
            log ERROR "failed to pause '$name'"
            failed=1
        fi
    done < <(targets)
    return "$failed"
}

# tick: one supervision + decision cycle.
tick() {
    local degraded=0 reason="" conns=0 now idle last
    local name state status paused
    local -a names=()
    local clean=0 paused_count=0 live_unpaused=0
    local any_paused=0 all_running_clean=0 all_paused=0

    # (1) Listener supervision.
    if ! supervise_listener "$SLEEP_LISTEN_AUTH" "$SLEEP_BACKEND_AUTH" listener_auth_pid; then
        degraded=1
        reason="${reason:+$reason; }listener :$SLEEP_LISTEN_AUTH not listening"
    fi
    if ! supervise_listener "$SLEEP_LISTEN_WORLD" "$SLEEP_BACKEND_WORLD" listener_world_pid; then
        degraded=1
        reason="${reason:+$reason; }listener :$SLEEP_LISTEN_WORLD not listening"
    fi

    # (2) Established client connections.
    if ! conns=$(count_connections); then
        degraded=1
        conns=0
        reason="${reason:+$reason; }cannot count connections (ss failed)"
    fi

    # (3) Target states.
    while IFS= read -r name; do
        names+=("$name")
        if ! state=$(container_state "$name"); then
            clean=0
            degraded=1
            reason="${reason:+$reason; }cannot inspect '$name'"
            continue
        fi
        status=${state%% *}
        paused=${state##* }
        if [ "$status" = running ] && [ "$paused" = false ]; then
            clean=$((clean + 1))
            live_unpaused=$((live_unpaused + 1))
        elif [ "$status" = paused ] && [ "$paused" = true ]; then
            paused_count=$((paused_count + 1))
        else
            degraded=1
            reason="${reason:+$reason; }target '$name' is $status (paused=$paused)"
        fi
    done < <(targets)

    if [ "${#names[@]}" -eq 0 ]; then
        degraded=1
        reason="${reason:+$reason; }no manageable target containers"
    fi
    [ "$clean" -eq "${#names[@]}" ] && [ "${#names[@]}" -gt 0 ] && all_running_clean=1
    [ "$paused_count" -eq "${#names[@]}" ] && [ "${#names[@]}" -gt 0 ] && all_paused=1
    [ "$paused_count" -gt 0 ] && any_paused=1

    now=$(date +%s)
    if last=$(read_last_activity); then
        if [ "$last" -gt "$now" ]; then
            last=$now
            printf '%s\n' "$now" >"$LAST_ACTIVITY_FILE"
        fi
    else
        last=$now
        printf '%s\n' "$now" >"$LAST_ACTIVITY_FILE"
    fi
    idle=$((now - last))

    # (4) Decision table.
    if [ "$degraded" -eq 1 ]; then
        mark_activity
        if [ "$any_paused" -eq 1 ]; then
            thaw_quiet
        fi
        log ERROR "degraded: $reason"
        return
    fi

    if [ "$conns" -gt 0 ]; then
        mark_activity
        if [ "$any_paused" -eq 1 ]; then
            log INFO "[THAW] reason=activity"
            thaw_quiet
        fi
        all_paused_logged=0
        return
    fi

    # No client connections from here on.
    if [ "${SLEEP_IDLE_TIMEOUT}" -eq 0 ]; then
        return
    fi

    if [ "$all_running_clean" -eq 1 ]; then
        if [ "$idle" -ge "$SLEEP_IDLE_TIMEOUT" ]; then
            local freeze_failed=0
            for name in "${names[@]}"; do
                if docker pause "$name" >/dev/null 2>&1; then
                    log INFO "[FREEZE] $name paused (idle ${idle}s)"
                else
                    log ERROR "failed to pause '$name'"
                    freeze_failed=1
                    break
                fi
            done
            if [ "$freeze_failed" -eq 1 ]; then
                thaw_quiet
                mark_activity
                log ERROR "freeze aborted, all targets thawed"
            fi
        fi
        all_paused_logged=0
        return
    fi

    if [ "$any_paused" -eq 1 ] && [ "$live_unpaused" -gt 0 ]; then
        log INFO "[RECONCILE] mixed paused/running targets, waking all targets"
        thaw_quiet
        # Inconsistent state counts as doubt: stay awake, do not re-freeze immediately.
        mark_activity
        all_paused_logged=0
        return
    fi

    if [ "$all_paused" -eq 1 ]; then
        # Expected steady state while idle: stay silent except once per transition.
        if [ "$all_paused_logged" -eq 0 ]; then
            log INFO "[FREEZE] all targets already paused (idle ${idle}s)"
            all_paused_logged=1
        fi
        return
    fi

    # Running targets and idle below the timeout: nothing to do.
    all_paused_logged=0
}

mode_loop() {
    local wait
    trap cleanup TERM INT

    thaw_quiet
    mark_activity
    log INFO "monitor started (interval ${SLEEP_CHECK_INTERVAL}s, idle timeout ${SLEEP_IDLE_TIMEOUT}s)"

    # Give entrypoint-spawned listeners a moment to bind before supervision.
    wait=0
    while [ "$wait" -lt 20 ]; do
        if port_listening "$SLEEP_LISTEN_AUTH" && port_listening "$SLEEP_LISTEN_WORLD"; then
            break
        fi
        wait=$((wait + 1))
        sleep 0.25
    done

    while :; do
        tick
        sleep "$SLEEP_CHECK_INTERVAL"
    done
}

case "${1:-loop}" in
    loop) mode_loop ;;
    status) mode_status ;;
    freeze) mode_freeze ;;
    wake) exec "$SCRIPT_DIR/thaw.sh" ;;
    -h | --help | help) usage ;;
    *)
        usage
        exit 2
        ;;
esac
