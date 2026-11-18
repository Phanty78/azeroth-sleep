#!/usr/bin/env bash
# shellcheck disable=SC2310,SC2311,SC2312,SC2294,SC2329
# Condition helpers are intentionally passed to wait_for and evaluated in
# if/&&/|| contexts; each one returns an explicit status and the suite exits
# on the first fail(), so the usual set -e caveats do not apply here.
#
# Self-contained integration tests for the azeroth-sleep Docker supervisor.
#
# The harness never touches a real AzerothCore stack: it builds disposable
# busy-CPU/TCP mocks (docker/test/mock.Dockerfile) and drives the supervisor
# through a dedicated Compose project (`sleep-selftest`) that publishes only
# 13724 and 18085. T00 is the sole exception: it statically merges the real
# project's Compose files with the overlay (no container, no daemon needed).
#
# Requirements: bash with /dev/tcp support, Docker Engine with Compose v2,
# jq for T00. Run from anywhere:
#
#   bash docker/test/run-tests.sh
#   AC_DIR=/path/to/azerothcore bash docker/test/run-tests.sh
#
# Every case prints PASS/FAIL with the values actually measured. The first
# failure exits non-zero. The EXIT trap removes both test projects (never
# `down -v`: mocks hold no data, but volumes are never touched).
#
# Test case map (see README.md for the 15 mission scenarios):
#   T00 overlay merge against the real AC project (offline)
#   T01 startup and listener status
#   T02 one persistent world connection -> 1 client, bridge established
#   T03 close -> status reports 0 client connections
#   T04 idle timeout waits
#   T05 both targets Paused=true + [FREEZE] logged
#   T06 CPU >5% while busy, <1% while paused (real values printed)
#   T07 connection on 13724 -> thaw in <=2s + auth bridge
#   T08 close -> refreeze
#   T12 6 world + 2 auth connections -> 8 clients, nothing paused; close -> refreeze
#   T13 mock-world restart -> refreeze; ac-sleep restart -> thaw; down/up -> healthy
#   T14 monitor crash -> auto-restart/thaw; pkill socat -> [SUPERVISOR] respawn
#   T15 protected mock-mysql is never paused (dedicated sleep-guard-test project)
#   T16 mixed paused/running state -> [RECONCILE], everything awake
set -euo pipefail

# Until the richer on_error trap below is installed, still turn any unexpected
# top-level failure into an explicit FAIL line rather than a silent exit.
trap 'status=$?; printf "FAIL: startup — command failed at line %s (exit status %s)\n" "$LINENO" "$status"; exit "$status"' ERR

TEST_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
DOCKER_DIR=$(cd -- "$TEST_DIR/.." && pwd)
REPO_ROOT=$(cd -- "$DOCKER_DIR/.." && pwd)
COMPOSE_FILE="$TEST_DIR/test-compose.yml"
SLEEPCTL="$DOCKER_DIR/sleepctl.sh"
SLEEP_OVERLAY="$DOCKER_DIR/docker-compose.sleep.yml"
AC_DIR="${AC_DIR:-$REPO_ROOT/../azerothcore-wotlk}"

PROJECT=sleep-selftest
SLEEP_CONTAINER=ac-sleep-test
GUARD_PROJECT=sleep-guard-test
GUARD_CONTAINER=ac-sleep-guard-test
AUTH_HOST_PORT=13724
WORLD_HOST_PORT=18085
IDLE_TIMEOUT=5
CHECK_INTERVAL=2
WAIT_ELAPSED_MS=0
LAST_CPU=
CASE=-
PASS_COUNT=0
TMP_DIR=
GUARD_FILE=

cleanup() {
    local rc=$?
    # Explicit -p/-f only: the real AzerothCore project is never touched.
    # Tear down before removing the temp dir that holds the guard compose file.
    docker compose -p "$PROJECT" -f "$COMPOSE_FILE" down --remove-orphans >/dev/null 2>&1 || true
    if [[ -n $GUARD_FILE && -f $GUARD_FILE ]]; then
        docker compose -p "$GUARD_PROJECT" -f "$GUARD_FILE" down --remove-orphans >/dev/null 2>&1 || true
    fi
    if [[ -n $TMP_DIR && -d $TMP_DIR ]]; then
        rm -rf -- "$TMP_DIR" || true
    fi
    exit "$rc"
}
trap cleanup EXIT

TMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/azeroth-sleep-test.XXXXXX")

# ---------------------------------------------------------------------------
# Reporting
# ---------------------------------------------------------------------------

begin() {
    CASE=$1
    printf '\n[%s]\n' "$CASE"
}

pass() {
    printf 'PASS: %s — %s\n' "$CASE" "$*"
    PASS_COUNT=$((PASS_COUNT + 1))
}

skip() {
    printf 'SKIP: %s — %s\n' "$CASE" "$*"
}

fail() {
    # stdout, same stream as PASS: a failed run must never look silent in a
    # captured test log.
    printf 'FAIL: %s — %s\n' "$CASE" "$*"
    if docker inspect "$SLEEP_CONTAINER" >/dev/null 2>&1; then
        printf '%s\n' '--- ac-sleep-test logs (tail 40) ---' >&2
        docker logs --tail 40 "$SLEEP_CONTAINER" >&2 || true
    fi
    exit 1
}

# Any unguarded nonzero command that errexit would turn into a silent exit is
# reported as an explicit FAIL first (including the failing line number).
on_error() {
    local status=$1 line=$2
    printf 'FAIL: %s — unexpected command failure at line %s (exit status %s)\n' \
        "${CASE:-startup}" "$line" "$status"
    if docker inspect "$SLEEP_CONTAINER" >/dev/null 2>&1; then
        printf '%s\n' '--- ac-sleep-test logs (tail 40) ---' >&2
        docker logs --tail 40 "$SLEEP_CONTAINER" >&2 || true
    fi
    exit "$status"
}
trap 'on_error "$?" "$LINENO"' ERR

assert_eq() {
    local want=$1 got=$2 label=$3
    [[ "$got" == "$want" ]] || fail "$label: expected '$want', measured '$got'"
}

run_or_fail() {
    if ! "$@"; then
        fail "command failed: $*"
    fi
}

# ---------------------------------------------------------------------------
# Portable timing and polling
# ---------------------------------------------------------------------------

now_ms() {
    if [[ -n ${EPOCHREALTIME:-} ]]; then
        local stamp=${EPOCHREALTIME/,/.}
        local sec=${stamp%%.*}
        local frac=${stamp#*.}
        printf '%s\n' "$(( sec * 1000 + 10#${frac:0:3} ))"
    elif command -v perl >/dev/null 2>&1; then
        perl -MTime::HiRes=time -e 'printf "%d\n", time()*1000'
    else
        printf '%s\n' "$(( $(date +%s) * 1000 ))"
    fi
}

# wait_for <seconds> <condition> [args...] -> 0 when condition succeeds.
# Sets WAIT_ELAPSED_MS to the elapsed time either way.
wait_for() {
    local timeout_s=$1
    shift
    local start elapsed
    start=$(now_ms)
    while :; do
        if "$@"; then
            elapsed=$(( $(now_ms) - start ))
            WAIT_ELAPSED_MS=$elapsed
            return 0
        fi
        elapsed=$(( $(now_ms) - start ))
        if (( elapsed >= timeout_s * 1000 )); then
            WAIT_ELAPSED_MS=$elapsed
            return 1
        fi
        sleep 0.2
    done
}

# ---------------------------------------------------------------------------
# Compose, supervisor and container helpers
# ---------------------------------------------------------------------------

compose() {
    docker compose -p "$PROJECT" -f "$COMPOSE_FILE" "$@"
}

guard_compose() {
    docker compose -p "$GUARD_PROJECT" -f "$GUARD_FILE" "$@"
}

sleep_status() {
    bash "$SLEEPCTL" -n "$SLEEP_CONTAINER" status 2>/dev/null
}

sleep_ctl() {
    bash "$SLEEPCTL" -n "$SLEEP_CONTAINER" "$@"
}

container_state() {
    docker inspect -f '{{.State.Status}}' "$1" 2>/dev/null || true
}

container_paused() {
    docker inspect -f '{{.State.Paused}}' "$1" 2>/dev/null || true
}

container_started_at() {
    docker inspect -f '{{.State.StartedAt}}' "$1" 2>/dev/null || true
}

is_paused() {
    [[ "$(container_paused "$1")" == true ]]
}

is_awake() {
    [[ "$(container_state "$1")" == running && "$(container_paused "$1")" == false ]]
}

both_awake() {
    is_awake mock-world && is_awake mock-auth
}

both_paused() {
    is_paused mock-world && is_paused mock-auth
}

# supervisor_new_start <started-at-before> -> true once the supervisor is
# running with a different StartedAt (i.e. the restart actually happened).
supervisor_new_start() {
    local before=$1 started
    [[ "$(container_state "$SLEEP_CONTAINER")" == running ]] || return 1
    started=$(container_started_at "$SLEEP_CONTAINER") || return 1
    [[ -n $started && $started != "$before" ]]
}

client_connections() {
    local count
    count=$(sleep_status 2>/dev/null |
        sed -n 's/.*client connections:[[:space:]]*\([0-9][0-9]*\).*/\1/p') || true
    printf '%s' "${count:-}"
}

connections_eq() {
    [[ "$(client_connections)" == "$1" ]]
}

connections_zero() {
    connections_eq 0
}

idle_seconds() {
    sleep_status 2>/dev/null |
        sed -n 's/.*idle: \([0-9][0-9]*\)s .*/\1/p'
}

# idle_at_most <seconds> -> true when the monitor has recently marked
# activity (its tick counts client connections and refreshes last_activity).
idle_at_most() {
    local idle
    idle=$(idle_seconds) || return 1
    [[ -n $idle ]] && (( idle <= $1 ))
}

listeners_ok() {
    local out
    out=$(sleep_status) || return 1
    printf '%s\n' "$out" | grep -q ':3724 ok' || return 1
    printf '%s\n' "$out" | grep -q ':8085 ok' || return 1
}

listeners_missing() {
    ! listeners_ok
}

status_ready() {
    listeners_ok && both_awake
}

accepted_on() {
    local port=$1 count
    count=$(docker exec "$SLEEP_CONTAINER" ss -Htn state established \
        "( sport = :$port )" 2>/dev/null | grep -c .) || true
    printf '%s' "${count:-0}"
}

outgoing_to() {
    local port=$1 count
    count=$(docker exec "$SLEEP_CONTAINER" ss -Htn state established \
        "( dport = :$port )" 2>/dev/null | grep -c .) || true
    printf '%s' "${count:-0}"
}

bridged_on() {
    local port=$1 accepted outgoing
    accepted=$(accepted_on "$port")
    outgoing=$(outgoing_to "$port")
    accepted=${accepted:-0}
    outgoing=${outgoing:-0}
    (( accepted >= 1 && outgoing >= 1 ))
}

log_has() {
    grep -qF -- "$1" < <(docker logs "$SLEEP_CONTAINER" 2>&1)
}

log_since_has() {
    grep -qF -- "$2" < <(docker logs --since "$1" "$SLEEP_CONTAINER" 2>&1)
}

guard_log_has() {
    grep -qF -- "$1" < <(docker logs "$GUARD_CONTAINER" 2>&1)
}

guard_mock_running() {
    [[ "$(container_state mock-mysql)" == running && "$(container_paused mock-mysql)" == false ]]
}

cpu_percent() {
    local raw
    raw=$(docker stats --no-stream --format '{{.CPUPerc}}' "$1" 2>/dev/null) || return 1
    raw=${raw%%%}
    raw=${raw// /}
    [[ $raw =~ ^[0-9]+([.][0-9]+)?$ ]] || return 1
    printf '%s' "$raw"
}

cpu_above() {
    local value
    value=$(cpu_percent "$1") || return 1
    LAST_CPU=$value
    awk -v v="$value" -v threshold="$2" 'BEGIN { exit !(v > threshold) }'
}

cpu_below() {
    local value
    value=$(cpu_percent "$1") || return 1
    LAST_CPU=$value
    awk -v v="$value" -v threshold="$2" 'BEGIN { exit !(v < threshold) }'
}

# Persistent client connections use bash's /dev/tcp builtin.
connect_fd() {
    local fd=$1 port=$2
    eval "exec ${fd}<>/dev/tcp/127.0.0.1/${port}"
}

close_fd() {
    local fd=$1
    eval "exec ${fd}>&-" 2>/dev/null || true
    eval "exec ${fd}<&-" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# T00 — static overlay merge against the real AzerothCore project (offline)
# ---------------------------------------------------------------------------

begin T00
if [[ ! -d $AC_DIR || ! -f $AC_DIR/docker-compose.yml ]]; then
    skip "AzerothCore project not found at $AC_DIR (set AC_DIR to enable T00)"
else
    if [[ ! -f $SLEEP_OVERLAY ]]; then
        fail "missing overlay $SLEEP_OVERLAY"
    fi
    if ! command -v jq >/dev/null 2>&1; then
        fail 'jq is required to parse docker compose config --format json'
    fi

    t00_files=(-f "$AC_DIR/docker-compose.yml")
    if [[ -f $AC_DIR/docker-compose.override.yml ]]; then
        t00_files+=(-f "$AC_DIR/docker-compose.override.yml")
    fi
    t00_files+=(-f "$SLEEP_OVERLAY")
    t00_json="$TMP_DIR/t00-config.json"
    t00_err="$TMP_DIR/t00-config.err"

    # `config` is offline: no daemon needed. Output can contain the real
    # project's environment values, so it is captured, never printed.
    # SLEEP_BUILD_CONTEXT is absolute because Compose resolves the overlay's
    # build context against the *first* compose file (the AC project dir).
    if ! (cd "$AC_DIR" &&
        SLEEP_BUILD_CONTEXT="$DOCKER_DIR" \
            docker compose "${t00_files[@]}" config --format json) \
        >"$t00_json" 2>"$t00_err"; then
        # Never print compose stderr: it can echo interpolated .env values.
        fail "docker compose config failed (offline merge of base + override + overlay); rerun the command manually to inspect the error"
    fi

    auth_ports=$(jq -r '(.services["ac-authserver"].ports // []) | length' "$t00_json") ||
        fail 'cannot parse ac-authserver ports from compose config'
    world_ports=$(jq -r '(.services["ac-worldserver"].ports // []) | length' "$t00_json") ||
        fail 'cannot parse ac-worldserver ports from compose config'
    sleep_published=$(jq -r '[.services["ac-sleep"].ports[]?.published | tostring] | sort | join(",")' "$t00_json") ||
        fail 'cannot parse ac-sleep published ports from compose config'
    sleep_targets=$(jq -r '[.services["ac-sleep"].ports[]?.target | tostring] | sort | join(",")' "$t00_json") ||
        fail 'cannot parse ac-sleep target ports from compose config'
    sleep_networks=$(jq -r '(.services["ac-sleep"].networks // {}) | (if type == "array" then . else keys end) | sort | join(",")' "$t00_json") ||
        fail 'cannot parse ac-sleep networks from compose config'

    assert_eq 0 "$auth_ports" 'ac-authserver published port count'
    assert_eq 0 "$world_ports" 'ac-worldserver published port count'
    assert_eq '3724,8085' "$sleep_published" 'ac-sleep published host ports'
    assert_eq '3724,8085' "$sleep_targets" 'ac-sleep container target ports'
    printf '%s\n' "$sleep_networks" | tr ',' '\n' | grep -qx 'ac-network' ||
        fail "ac-sleep is not attached to ac-network (networks: ${sleep_networks:-none})"

    pass "authserver ports=0, worldserver ports=0, ac-sleep published=${sleep_published} targets=${sleep_targets} networks=${sleep_networks}"
fi

# ---------------------------------------------------------------------------
# T01 — startup and status
# ---------------------------------------------------------------------------

begin T01
if [[ ! -f $SLEEPCTL ]]; then
    fail "missing supervisor CLI $SLEEPCTL"
fi
run_or_fail compose up -d --build
if ! wait_for 90 status_ready; then
    fail "startup not healthy after ${WAIT_ELAPSED_MS}ms (world=$(container_state mock-world)/paused=$(container_paused mock-world), auth=$(container_state mock-auth)/paused=$(container_paused mock-auth), status='$(sleep_status | tr '\n' '|')')"
fi
startup_ms=$WAIT_ELAPSED_MS
if ! connections_eq 0; then
    fail "expected 0 client connections at startup, measured $(client_connections)"
fi
status_snapshot=$(sleep_status | tr '\n' '|')
pass "ready in ${startup_ms}ms; mock-world/mock-auth running and unpaused; listeners :3724+:8085 ok; client connections=0; status=${status_snapshot}"

# ---------------------------------------------------------------------------
# T02 — one persistent connection is counted and bridged
# ---------------------------------------------------------------------------

begin T02
connect_fd 3 "$WORLD_HOST_PORT" || fail "TCP connect to 127.0.0.1:${WORLD_HOST_PORT} failed"
if ! wait_for 10 connections_eq 1; then
    fail "status did not reach 'client connections: 1' (measured '$(client_connections)')"
fi
if ! wait_for 10 both_awake; then
    fail "targets not running/unpaused (world=$(container_state mock-world)/$(container_paused mock-world), auth=$(container_state mock-auth)/$(container_paused mock-auth))"
fi
if ! wait_for 10 bridged_on 8085; then
    fail "proxy bridge incomplete (accepted:8085=$(accepted_on 8085), outgoing:8085=$(outgoing_to 8085))"
fi
pass "client connections=$(client_connections); mock-world/mock-auth running, Paused=false; established in ac-sleep: accepted:8085=$(accepted_on 8085), backend:8085=$(outgoing_to 8085)"

# ---------------------------------------------------------------------------
# T03 — closing the last connection drops the count to zero
# ---------------------------------------------------------------------------

begin T03
close_fd 3
if ! wait_for 10 connections_zero; then
    fail "status still reports $(client_connections) client connection(s) after closing the socket"
fi
pass "connection closed; client connections=$(client_connections) after ${WAIT_ELAPSED_MS}ms"

# ---------------------------------------------------------------------------
# T04 — idle timeout elapses
# ---------------------------------------------------------------------------

begin T04
freeze_timeout=$(( IDLE_TIMEOUT + 3 * CHECK_INTERVAL + 5 ))
if ! wait_for "$freeze_timeout" both_paused; then
    fail "targets not paused after ${WAIT_ELAPSED_MS}ms (idle=${IDLE_TIMEOUT}s, interval=${CHECK_INTERVAL}s; world=$(container_state mock-world)/$(container_paused mock-world), auth=$(container_state mock-auth)/$(container_paused mock-auth))"
fi
pass "both targets paused after ${WAIT_ELAPSED_MS}ms (idle=${IDLE_TIMEOUT}s, check interval=${CHECK_INTERVAL}s)"

# ---------------------------------------------------------------------------
# T05 — stasis is real and logged
# ---------------------------------------------------------------------------

begin T05
if ! both_paused; then
    fail "Paused flags are not both true (mock-world=$(container_paused mock-world), mock-auth=$(container_paused mock-auth))"
fi
if ! log_has '[FREEZE]'; then
    fail 'no [FREEZE] entry in ac-sleep-test logs'
fi
freeze_logs=$(docker logs "$SLEEP_CONTAINER" 2>&1 | grep -c '\[FREEZE\]') || true
pass "mock-world Paused=$(container_paused mock-world), mock-auth Paused=$(container_paused mock-auth); [FREEZE] log lines=${freeze_logs}"

# ---------------------------------------------------------------------------
# T06 — CPU before/after pause (real docker stats values)
# ---------------------------------------------------------------------------

begin T06
# Hold a connection while sampling: otherwise the monitor may refreeze
# immediately because the idle timer already expired.
connect_fd 3 "$WORLD_HOST_PORT" || fail "TCP connect to 127.0.0.1:${WORLD_HOST_PORT} failed"
if ! wait_for 10 both_awake; then
    fail "targets did not wake for the CPU measurement"
fi
if ! wait_for 10 idle_at_most "$((CHECK_INTERVAL + 1))"; then
    fail "monitor did not register the CPU probe connection (idle=$(idle_seconds)s)"
fi
if ! wait_for 20 cpu_above mock-world 5; then
    fail "mock-world CPU never exceeded 5% while running (last sample='${LAST_CPU:-unavailable}')"
fi
cpu_before=$LAST_CPU
close_fd 3
if ! wait_for "$freeze_timeout" both_paused; then
    fail "targets did not pause after closing the CPU probe connection"
fi
if ! wait_for 10 cpu_below mock-world 1; then
    fail "mock-world CPU did not drop below 1% while paused (last sample='${LAST_CPU:-unavailable}')"
fi
cpu_after=$LAST_CPU
pass "docker stats mock-world CPU: before=${cpu_before}% (>5%), after pause=${cpu_after}% (<1%)"

# ---------------------------------------------------------------------------
# T07 — a connection on the auth port wakes the stack within 2 s
# ---------------------------------------------------------------------------

begin T07
if ! both_paused; then
    fail "precondition failed: targets are not frozen (world=$(container_paused mock-world), auth=$(container_paused mock-auth))"
fi
wake_start=$(now_ms)
connect_fd 3 "$AUTH_HOST_PORT" || fail "TCP connect to 127.0.0.1:${AUTH_HOST_PORT} failed"
if ! wait_for 2 both_awake; then
    fail "targets not unpaused within 2s (world=$(container_paused mock-world), auth=$(container_paused mock-auth))"
fi
wake_ms=$(( $(now_ms) - wake_start ))
if (( wake_ms > 2000 )); then
    fail "thaw took ${wake_ms}ms (>2000ms)"
fi
if ! wait_for 5 bridged_on 3724; then
    fail "auth bridge incomplete (accepted:3724=$(accepted_on 3724), outgoing:3724=$(outgoing_to 3724))"
fi
pass "connection on ${AUTH_HOST_PORT} -> both targets unpaused in ${wake_ms}ms (<=2000ms); accepted:3724=$(accepted_on 3724), backend:3724=$(outgoing_to 3724)"

# ---------------------------------------------------------------------------
# T08 — closing the auth connection refreezes the stack
# ---------------------------------------------------------------------------

begin T08
close_fd 3
if ! wait_for "$freeze_timeout" both_paused; then
    fail "no refreeze after closing the auth connection (world=$(container_paused mock-world), auth=$(container_paused mock-auth), clients=$(client_connections))"
fi
pass "auth connection closed; both targets paused again after ${WAIT_ELAPSED_MS}ms"

# ---------------------------------------------------------------------------
# T12 — 8 concurrent connections keep everything awake, then refreeze
# ---------------------------------------------------------------------------

begin T12
fd=3
for port in 18085 18085 18085 18085 18085 18085 13724 13724; do
    connect_fd "$fd" "$port" || fail "#$((fd - 2)) connection to 127.0.0.1:${port} failed"
    fd=$((fd + 1))
done
if ! wait_for 15 connections_eq 8; then
    fail "status did not report 8 client connections (measured '$(client_connections)')"
fi
if ! wait_for 10 both_awake; then
    fail "targets paused with active connections (world=$(container_paused mock-world), auth=$(container_paused mock-auth))"
fi
for fd in 3 4 5 6 7 8 9 10; do
    close_fd "$fd"
done
if ! wait_for "$freeze_timeout" both_paused; then
    fail "no refreeze after closing all 8 connections (paused: world=$(container_paused mock-world), auth=$(container_paused mock-auth))"
fi
pass "6x18085 + 2x13724 -> client connections=8 with Paused=false on both targets; all closed -> Paused=true after ${WAIT_ELAPSED_MS}ms"

# ---------------------------------------------------------------------------
# T13 — container restarts and full down/up convergence
# ---------------------------------------------------------------------------

begin T13
# (a) Restart mock-world while a client holds the stack awake, then refreeze.
connect_fd 3 "$WORLD_HOST_PORT" || fail "TCP connect to 127.0.0.1:${WORLD_HOST_PORT} failed"
if ! wait_for 10 connections_eq 1; then
    fail "probe connection not counted before restarting mock-world (measured '$(client_connections)')"
fi
if ! wait_for 10 idle_at_most "$((CHECK_INTERVAL + 1))"; then
    fail "monitor did not register the probe connection before the restart (idle=$(idle_seconds)s)"
fi
if ! wait_for 10 both_awake; then
    fail "targets did not wake before restarting mock-world"
fi
world_started_before=$(container_started_at mock-world)
run_or_fail compose restart mock-world
if ! wait_for 15 both_awake; then
    fail "stack not awake after restarting mock-world (world=$(container_state mock-world)/$(container_paused mock-world), auth=$(container_state mock-auth)/$(container_paused mock-auth))"
fi
world_started_after=$(container_started_at mock-world)
if [[ -z $world_started_after || $world_started_after == "$world_started_before" ]]; then
    fail "mock-world StartedAt did not change (before='${world_started_before}', after='${world_started_after}')"
fi
close_fd 3
if ! wait_for "$freeze_timeout" both_paused; then
    fail "no refreeze after mock-world restart + disconnect"
fi
restart_refreeze_ms=$WAIT_ELAPSED_MS

# (b) Freeze, then restart the supervisor itself: startup must thaw everything.
if ! both_paused; then
    fail "precondition failed: targets not frozen before restarting ac-sleep-test"
fi
supervisor_start=$(now_ms)
supervisor_started_before=$(container_started_at "$SLEEP_CONTAINER")
run_or_fail docker restart "$SLEEP_CONTAINER"
if ! wait_for 30 supervisor_new_start "$supervisor_started_before"; then
    fail "ac-sleep-test did not return to running with a new StartedAt after docker restart"
fi
if ! wait_for 20 both_awake; then
    fail "targets not thawed at supervisor startup (world=$(container_paused mock-world), auth=$(container_paused mock-auth))"
fi
if ! wait_for 15 status_ready; then
    fail "status not healthy after supervisor restart ('$(sleep_status | tr '\n' '|')')"
fi
supervisor_restart_ms=$(( $(now_ms) - supervisor_start ))

# (c) Full project down/up: host reboot equivalent, containers start awake.
run_or_fail compose down --remove-orphans
run_or_fail compose up -d
if ! wait_for 90 status_ready; then
    fail "down/up did not converge to a healthy status (world=$(container_paused mock-world), auth=$(container_paused mock-auth), status='$(sleep_status | tr '\n' '|')')"
fi
down_up_ms=$WAIT_ELAPSED_MS
pass "mock-world restart -> refreeze ${restart_refreeze_ms}ms; ac-sleep restart -> thaw+healthy ${supervisor_restart_ms}ms; compose down/up -> healthy ${down_up_ms}ms; Paused=false on both"

# ---------------------------------------------------------------------------
# T14 — supervisor and listener failures
# ---------------------------------------------------------------------------

begin T14
# (a) Crash the supervisor by SIGKILLing the monitor process (PID 1).
# `docker kill` must NOT be used here: Docker records it as a manual stop,
# so `restart: unless-stopped` correctly leaves the container exited. A real
# crash (SIGKILL) is restarted by the policy. monitor.sh runs as `bash`, so
# match the script path with pkill -f (pkill -x monitor.sh would not match).
if ! wait_for "$freeze_timeout" both_paused; then
    fail "precondition failed: targets not frozen before the supervisor crash"
fi
crash_start=$(now_ms)
supervisor_started_before=$(container_started_at "$SLEEP_CONTAINER")
# The exec stream can die with PID 1, hence the tolerated nonzero status; the
# StartedAt check below is the authoritative proof that the crash happened.
docker exec "$SLEEP_CONTAINER" pkill -9 -f '/usr/local/bin/monitor.sh' >/dev/null 2>&1 || true
if ! wait_for 30 supervisor_new_start "$supervisor_started_before"; then
    fail "ac-sleep-test did not restart after SIGKILL of monitor.sh (state=$(container_state "$SLEEP_CONTAINER"), started=$(container_started_at "$SLEEP_CONTAINER"), idle=$(idle_seconds)s)"
fi
if ! wait_for 20 both_awake; then
    fail "targets not thawed after supervisor auto-restart (world=$(container_paused mock-world), auth=$(container_paused mock-auth))"
fi
restart_ms=$(( $(now_ms) - crash_start ))
connect_fd 3 "$WORLD_HOST_PORT" || fail "new connection failed after supervisor restart"
if ! wait_for 10 connections_eq 1; then
    fail "new connection not counted after supervisor restart (measured '$(client_connections)')"
fi
if ! wait_for 10 bridged_on 8085; then
    fail "new bridge incomplete after supervisor restart (accepted:8085=$(accepted_on 8085), outgoing:8085=$(outgoing_to 8085))"
fi
close_fd 3
if ! wait_for "$freeze_timeout" both_paused; then
    fail "no refreeze before the listener-respawn test"
fi

# (b) Kill every socat process: the monitor loop must respawn both listeners
#     within two ticks and log [SUPERVISOR].
supervisor_log_before=$(docker logs "$SLEEP_CONTAINER" 2>&1 | grep -c '\[SUPERVISOR\]') || true
pkill_start=$(now_ms)
run_or_fail docker exec "$SLEEP_CONTAINER" pkill -x socat
# Let the killed sockets disappear (normally well under one check interval).
if ! wait_for 2 listeners_missing; then
    : # A fast monitor tick may already have respawned them; the log proves it.
fi
respawn_timeout=$(( 2 * CHECK_INTERVAL + 2 ))
if ! wait_for "$respawn_timeout" listeners_ok; then
    fail "listeners not respawned within ${respawn_timeout}s (status='$(sleep_status | tr '\n' '|')')"
fi
respawn_ms=$(( $(now_ms) - pkill_start ))
if (( respawn_ms > (2 * CHECK_INTERVAL + 1) * 1000 )); then
    fail "listener respawn took ${respawn_ms}ms (> $(( 2 * CHECK_INTERVAL + 1 ))s / two ticks)"
fi
if ! log_has '[SUPERVISOR]'; then
    fail 'no [SUPERVISOR] log after pkill -x socat'
fi
supervisor_log_after=$(docker logs "$SLEEP_CONTAINER" 2>&1 | grep -c '\[SUPERVISOR\]') || true

# A connection after respawn must still wake the (frozen) stack.
connect_fd 3 "$WORLD_HOST_PORT" || fail "connection failed after listener respawn"
if ! wait_for 10 connections_eq 1; then
    fail "connection after listener respawn not counted (measured '$(client_connections)')"
fi
close_fd 3
if ! wait_for "$freeze_timeout" both_paused; then
    fail "no refreeze after the post-respawn connection"
fi
pass "monitor SIGKILL -> auto-restart+thaw ${restart_ms}ms, connections OK; pkill socat -> both listeners back in ${respawn_ms}ms (2-tick budget $((2 * CHECK_INTERVAL))s + 1s polling margin), [SUPERVISOR] lines ${supervisor_log_before}->${supervisor_log_after}"

# ---------------------------------------------------------------------------
# T15 — protected containers are refused, never paused
# ---------------------------------------------------------------------------

begin T15
GUARD_FILE="$TMP_DIR/sleep-guard-test.yml"
# Dedicated disposable project. The only target is `mock-mysql`, which must
# be rejected by the supervisor's protected-name rule (frozen pattern matches
# "mysql"); the image built by T01 is reused (build only runs if tag missing).
cat >"$GUARD_FILE" <<GUARD_YAML
name: $GUARD_PROJECT

services:
  mock-mysql:
    build:
      context: "$TEST_DIR"
      dockerfile: mock.Dockerfile
    image: azeroth-sleep-mock:local
    container_name: mock-mysql
    environment:
      PORT: "3306"
    networks:
      - guard-net

  ac-sleep:
    build:
      context: "$DOCKER_DIR"
      dockerfile: Dockerfile
    image: azeroth-sleep-selftest:local
    container_name: $GUARD_CONTAINER
    init: true
    restart: "no"
    read_only: true
    tmpfs:
      - /tmp
    cap_drop:
      - ALL
    security_opt:
      - no-new-privileges:true
    networks:
      - guard-net
    environment:
      SLEEP_TARGET_CONTAINERS: "mock-mysql"
      SLEEP_IDLE_TIMEOUT: "2"
      SLEEP_CHECK_INTERVAL: "1"
      SLEEP_LISTEN_AUTH: "3724"
      SLEEP_LISTEN_WORLD: "8085"
      SLEEP_BACKEND_AUTH: "mock-mysql:3306"
      SLEEP_BACKEND_WORLD: "mock-mysql:3306"
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock

networks:
  guard-net:
GUARD_YAML

run_or_fail guard_compose up -d
if ! wait_for 60 guard_mock_running; then
    fail "mock-mysql not running in $GUARD_PROJECT (state=$(container_state mock-mysql))"
fi
guard_refusal="refusing to manage protected container 'mock-mysql'"
if ! wait_for 20 guard_log_has "$guard_refusal"; then
    fail "supervisor did not log '${guard_refusal}' (guard logs: $(docker logs "$GUARD_CONTAINER" 2>&1 | tail -n 3 | tr '\n' '|'))"
fi
refusal_ms=$WAIT_ELAPSED_MS
# Give the guard monitor several idle periods: mock-mysql must remain untouched.
sleep $(( 2 * 1 + 2 ))
if ! guard_mock_running; then
    fail "mock-mysql was paused/stopped by the guard supervisor (state=$(container_state mock-mysql), paused=$(container_paused mock-mysql))"
fi
mock_state=$(container_state mock-mysql)
mock_paused=$(container_paused mock-mysql)
guard_compose down --remove-orphans >/dev/null 2>&1 || true
GUARD_FILE=
pass "guard project refusal logged in ${refusal_ms}ms; after >2 idle periods mock-mysql state=${mock_state}, Paused=${mock_paused}"

# ---------------------------------------------------------------------------
# T16 — mixed paused/running state is reconciled
# ---------------------------------------------------------------------------

begin T16
run_or_fail sleep_ctl freeze
if ! wait_for 10 both_paused; then
    fail "sleepctl freeze did not pause both targets (world=$(container_paused mock-world), auth=$(container_paused mock-auth))"
fi
reconcile_since=$(date -u '+%Y-%m-%dT%H:%M:%SZ') || fail 'cannot read current UTC time'
# Docker refuses to restart a paused container ("unpause before stopping"),
# so create the frozen/running mix by unpausing one target first. Wait for the
# monitor's [RECONCILE] before restarting mock-auth, otherwise a tick landing
# inside the restart window would log a target-transition error instead.
run_or_fail docker unpause mock-auth
if ! wait_for 10 log_since_has "$reconcile_since" '[RECONCILE]'; then
    fail "no [RECONCILE] log after sleepctl freeze + mixed paused/running state"
fi
run_or_fail compose restart mock-auth
if ! wait_for 15 both_awake; then
    fail "inconsistent state not reconciled to all-awake (world=$(container_paused mock-world), auth=$(container_paused mock-auth))"
fi
world_paused_after=$(container_paused mock-world)
auth_paused_after=$(container_paused mock-auth)
pass "sleepctl freeze -> mock-auth unpaused/restarted -> [RECONCILE] logged; world Paused=${world_paused_after}, auth Paused=${auth_paused_after}"

printf '\n%d test case(s) passed; 0 failed.\n' "$PASS_COUNT"
