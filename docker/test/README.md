# azeroth-sleep integration harness (`docker/test/`)

Self-contained integration tests for the `ac-sleep` supervisor. The harness does
**not** need AzerothCore containers, images, maps, or a database: it builds two
disposable mocks that listen on the real game ports, keep accepted sessions open,
and burn one CPU core so `docker pause` is measurable. The only exception is
**T00**, which reads the real AzerothCore Compose project to validate the overlay
merge with `docker compose config` (offline; no container and no daemon needed).

The mocks speak **TCP only**. They prove proxying, freeze/wake and supervision;
they cannot prove the WoW login/world protocol. Those scenarios are covered by
the `e2e/` protocol harness and by the real-client runbook below.

## Files

| File | Purpose |
| --- | --- |
| `mock.Dockerfile` | `alpine:3.20` + `socat`. `yes` busy-loop for CPU measurement, `socat TCP4-LISTEN:${PORT},fork,reuseaddr SYSTEM:'sleep 3600'` to hold client sessions. |
| `test-compose.yml` | Isolated project `sleep-selftest`: `mock-auth` (3724), `mock-world` (8085), `ac-sleep` (container `ac-sleep-test`, idle timeout 5 s, check interval 2 s). Publishes **only** host ports 13724 and 18085. |
| `run-tests.sh` | Host bash runner. One PASS/FAIL per case with measured values; exits non-zero on the first failure. |
| `README.md` | This document: usage, case map, 15-scenario matrix, e2e/manual coverage. |

## Quick start

Prerequisites:

- Docker Engine/Desktop with Compose v2 (`docker compose version`);
- `bash` with `/dev/tcp` support (standard on Linux and macOS);
- `jq` for T00;
- permission to use the Docker socket (the supervisor container mounts it).

From the repository root:

```bash
bash docker/test/run-tests.sh

# If the AzerothCore Compose project is elsewhere:
AC_DIR=/path/to/azerothcore-wotlk bash docker/test/run-tests.sh
```

The runner:

1. runs T00 offline against `$AC_DIR` (default: `../azerothcore-wotlk`); if that
   directory or its `docker-compose.yml` is missing, T00 prints `SKIP` and the
   mock suite still runs;
2. builds the mock and supervisor images and starts project `sleep-selftest`;
3. executes the cases in order, printing `PASS: Txx — <measured values>` or
   `FAIL: Txx — <expected vs measured>`; the first FAIL exits non-zero immediately;
4. on exit (success or failure) runs `docker compose -p sleep-selftest ... down`
   (plus the temporary `sleep-guard-test` project). It **never** passes `-v`,
   never touches the real AzerothCore project, and uses no named volumes.

Expected duration is a few minutes, dominated by the two image builds. The
published host ports are 13724 and 18085 only, so a real stack can keep 3724
and 8085.

### T00 and `SLEEP_BUILD_CONTEXT`

Compose resolves a relative `build.context` against the **first** Compose file,
so the overlay's build context must be absolute when merged with the
AzerothCore project. The runner sets:

```bash
SLEEP_BUILD_CONTEXT="$REPO_ROOT/docker"
```

For the `docker compose config` invocation. The T00 assertions are about the
merged service graph, not the build path: `ac-authserver` and `ac-worldserver`
must have zero published ports, `ac-sleep` must publish host ports 3724 and
8085 (targets 3724/8085), and `ac-sleep` must join `ac-network`. T00 asserts
the documented default host ports; if the AC project remaps
`DOCKER_AUTH_EXTERNAL_PORT`/`DOCKER_WORLD_EXTERNAL_PORT`, run T00 against an
unmodified environment or update the two expected values in
`run-tests.sh`.

## Isolation and safety

- Project `sleep-selftest`, containers `mock-auth`, `mock-world`,
  `ac-sleep-test`; network `sleep-net`.
- Host mappings: `13724:3724` (auth) and `18085:8085` (world). No admin port and
  no database port are published.
- The supervisor container uses the same hardening as the production
  `docker-compose.sleep.yml`: `read_only`, `tmpfs: /tmp`, `cap_drop: ALL`,
  `no-new-privileges:true`, `init: true`, `restart: unless-stopped`.
- T15 starts a second disposable project, `sleep-guard-test`, with a single
  `mock-mysql` container and no published ports; it is removed immediately
  after the case.
- The Docker socket mount gives the supervisor host-root-equivalent power. That
  is inherent to the design and documented in `../../docs/audit.md`; it is
  acceptable here because this container only ever controls the mock stack.
- The trap uses an explicit project name and Compose file. It can never run
  `down` against the production project.

## Test cases

| Case | What it does | Assertions and measured output |
| --- | --- | --- |
| **T00** | Offline merge: `docker compose -f $AC_DIR/docker-compose.yml [-f override] -f docker-compose.sleep.yml config --format json` with `SLEEP_BUILD_CONTEXT` set. SKIP if `$AC_DIR` or its base file is absent. | `jq` checks: `ac-authserver.ports` and `ac-worldserver.ports` length 0; `ac-sleep` publishes 3724 and 8085 and targets 3724/8085; `ac-sleep` network keys contain `ac-network`. Prints those values. Compose stderr is never printed (it may contain `.env` secrets). |
| **T01** | Builds/starts the mock project, waits for listeners and targets. | `sleepctl -n ac-sleep-test status` exits 0; both mocks `running` with `Paused=false`; `listeners: :3724 ok, :8085 ok`; `client connections: 0`. Prints startup ms and the status snapshot. |
| **T02** | Opens one persistent `/dev/tcp/127.0.0.1/18085` socket. | Status reaches `client connections: 1`; both targets `running`, `Paused=false`; in `ac-sleep-test`, established sockets exist in both directions (`sport = :8085` and `dport = :8085`). Prints both counts. |
| **T03** | Closes that socket. | Status reports `client connections: 0` after the measured ms. |
| **T04** | Waits for the idle timeout (5 s) plus monitor ticks. | Both mock containers report `Paused=true`; prints elapsed ms, idle timeout and check interval. |
| **T05** | Confirms the stasis state and its log. | `docker inspect` `Paused=true` for `mock-world` and `mock-auth`; at least one `[FREEZE]` line in `docker logs ac-sleep-test`; prints the count. |
| **T06** | Samples `docker stats --no-stream` for `mock-world` while a client holds the stack awake, closes it, waits for pause, samples again. | Measured CPU **> 5 %** while running and **< 1 %** while paused. Both real values are printed; nothing is hard-coded. |
| **T07** | From frozen, opens one socket on `13724`. | Both targets unpause in **≤ 2000 ms** (measured from connect); auth bridge established (`sport = :3724` and `dport = :3724` in `ac-sleep-test`). Prints the measured wake time and counts. |
| **T08** | Closes the auth socket. | Both targets return to `Paused=true`; prints elapsed ms. |
| **T12** | Opens 6 sockets on 18085 and 2 on 13724, keeps them open, then closes all. | Status reaches `client connections: 8`; neither target is paused; after closing, both are paused again. Prints elapsed ms. |
| **T13** | (a) Restarts `mock-world` while a client keeps the stack awake, then disconnects; (b) freezes, then `docker restart ac-sleep-test`; (c) `compose down` + `compose up -d`. | (a) `mock-world` `StartedAt` changed and both targets refreeze after the idle timeout. (b) Supervisor is running again with a new `StartedAt`, startup thaw leaves both targets `Paused=false`, and status is healthy. (c) down/up converges to the same healthy status. Prints all elapsed times. |
| **T14** | (a) Crashes the supervisor by SIGKILLing the monitor process: `docker exec ac-sleep-test pkill -9 -f '/usr/local/bin/monitor.sh'` while frozen; (b) `docker exec ac-sleep-test pkill -x socat`. | (a) The container restart policy brings the supervisor back with a new `StartedAt`, both targets thaw, and a new 18085 connection is counted and bridged. `docker kill` is deliberately not used: Docker records it as a manual stop, which suppresses `restart: unless-stopped`. (b) Both listeners are back within the two-tick budget, a `[SUPERVISOR]` line was added to the logs, and a new connection still works. Prints restart/respawn ms and `[SUPERVISOR]` line counts. |
| **T15** | Starts disposable project `sleep-guard-test` with container `mock-mysql`, `SLEEP_TARGET_CONTAINERS=mock-mysql`, idle 2 s, interval 1 s. | After several idle periods `mock-mysql` is still `running` with `Paused=false`, and the guard log contains `refusing to manage protected container 'mock-mysql'`. Prints the time to refusal and the final state. |
| **T16** | `sleepctl -n ac-sleep-test freeze`, unpauses `mock-auth` (Docker refuses to restart a paused container) to create a frozen/running mix, waits for reconciliation, then restarts `mock-auth`. | Within a few ticks the monitor logs `[RECONCILE]` and both targets are awake (`Paused=false`); the restarted auth target stays healthy. Prints the post-reconcile flags. |

There is deliberately no T09/T10/T11: those scenarios require the WoW protocol
(see the mapping below) and are covered by `e2e/` and the manual runbook.

### Notes on the measured thresholds

- `docker stats` CPU percentages are relative to **all** host cores. One busy
  `yes` loop is ~100 % of one core, so a host exposing more than 20 cores could
  report slightly less than the 5 % T06 threshold. On normal 4–12 core hosts
  (including the Mac mini 4c/8t target) the margin is comfortable. A failing
  T06 number should be read as a harness-host property, not as a freeze defect.
- T06 samples while a connection is held; otherwise the monitor may refreeze
  immediately because the previous idle period already expired.
- All polling uses 200 ms intervals with explicit deadlines. The only fixed
  sleep is T15's four seconds, which is the observation window proving that the
  guard never pauses its protected target over multiple monitor ticks.

## The 15 mission scenarios: coverage map

The mission's mandatory test list, and where each item is validated:

| # | Mission scenario | This harness | Protocol `e2e/` | Manual WoW client runbook |
| --- | --- | --- | --- | --- |
| 1 | Normal AzerothCore startup | **T01**, **T13c** (down/up = reboot equivalent) | optional warm-up run | step 3 |
| 2 | Successful player connection | **T02** (TCP session + world bridge; not WoW auth) | `make e2e-smoke` login | step 5 |
| 3 | Last player disconnects | **T03** | — | step 6 |
| 4 | Idle delay elapses | **T04** | — | step 6 |
| 5 | Automatic stasis | **T05** (`Paused=true` + `[FREEZE]`) | — | step 6 |
| 6 | CPU before/after | **T06** (real `docker stats` values) | — | step 6, real stack values |
| 7 | Connection attempt while frozen | **T07** (accept + thaw) | e2e connection to a frozen stack | step 7 |
| 8 | Automatic wake | **T07** (≤ 2 s), **T13b**, **T14a** | e2e after thaw | step 7 |
| 9 | Realm list access | **T07** only proves the auth port bridge | e2e realm-list request | step 5 |
| 10 | Effective entry into the world | **T02** only proves the world port bridge | e2e world entry | step 5 (visible in client) |
| 11 | Reconnect after several hours | not automated (short idle only); **T13** covers restart survival | optional second e2e run | step 8 (multi-hour soak) |
| 12 | Simultaneous players | **T12** (8 concurrent sessions) | e2e multi-client if available | step 5 (several accounts) |
| 13 | Host and container restarts | **T13** (mock restart, supervisor restart, down/up) | — | step 9 (real host reboot) |
| 14 | Proxy/supervisor failure | **T14** (monitor SIGKILL crash, `pkill socat`, `[SUPERVISOR]`) | — | step 10 (inject on real stack) |
| 15 | Compatibility with existing modules | **T13b/T16** prove pause does not restart processes; no C++ module runs in mocks | e2e after thaw | step 11 (exercise module commands) |

Supplementary safety cases: **T00** (production overlay merge), **T08** (auth
connection refreeze), **T15** (`mock-mysql`, a database-like target that is
never managed). They are guard rails beyond the 15 mission scenarios. MySQL
stays active by design: `ac-database` is never in the target list, and T15
proves that a protected database-like name is refused rather than paused.

### What is *not* proven here

- The mocks do not implement SRP6/WorldPacket, so T02/T07 cannot show that a
  client logs in or renders the world. The `e2e` suite and the manual runbook
  are the authority for scenarios 2, 7, 8, 9, 10 and 15.
- The harness uses a 5 s idle timeout; it does not prove multi-hour behaviour.
  Only the soak run from the production runbook does that.
- The mock CPU numbers prove `docker pause` semantics, not the real
  worldserver's CPU baseline.

## Protocol `e2e/` runs (AzerothCore repository)

These commands are **not** executed by this harness. They require a real,
running AzerothCore stack with the overlay active:

1. Ensure Warden is disabled for the harness
   (`Warden.Enabled = 0`, or a disposable Compose override that sets
   `AC_WARDEN_ENABLED: "0"`; never edit the tracked core files).
2. Expose MySQL to the e2e process (the local project publishes
   `127.0.0.1:3306`). Export the root password from `.env` in the shell only;
   never write it to a file or command line committed anywhere.
3. From `e2e/`:

   ```bash
   E2E_AUTH_ADDR=127.0.0.1:3724 make e2e-smoke
   ```

This performs login, realm list, teleport and relog **through the `ac-sleep`
proxy**, covering mission scenarios 2, 7, 8, 9 and 10. Run it once with the
stack awake and once while frozen (after `SLEEP_IDLE_TIMEOUT`) to measure the
wake path. See `../../docs/deploy-production.md` for the exact production
sequence.

## Manual WoW client runbook

This harness cannot validate what the player sees. The following steps are the
manual counterpart; perform them on the dev MacBook or during the production
window, announce each step, and wait for validation before declaring success.

1. **Deploy under maintenance window.** Follow
   `../../docs/deploy-production.md`; place the overlay **last** in
   `COMPOSE_FILE`, run `docker compose up -d`, and confirm
   `docker compose ps` shows ports only on `ac-sleep`.
2. **Baseline status.** `sleepctl status` (targets running, listeners ok) and
   record `docker stats --no-stream ac-worldserver ac-authserver`.
3. **Scenario 1 — startup.** Wait for `World Initialized` / ready in
   `env/dist/logs/Server.log`; confirm the supervisor did not leave anything
   paused and its logs show a clean start.
4. **Short idle timeout for testing.** Temporarily set
   `SLEEP_IDLE_TIMEOUT=60` (or 30) in the local `.env`, `docker compose up -d`,
   and note the value; restore 600 at the end.
5. **Scenarios 2, 9, 10, 12 — visible client checks.** With the real WoW client
   over Tailscale: log in, verify the **realm list** appears, select the realm,
   verify the **character list**, enter the world, and confirm the character is
   **visible in-game**. Repeat with several accounts for concurrency.
6. **Scenarios 3–6 — idle and stasis on the real stack.** Log out all clients.
   After the timeout, check `docker inspect -f '{{.State.Paused}}'
   ac-worldserver ac-authserver` = `true`, and compare `docker stats
   --no-stream` with step 2. Confirm `[FREEZE]` in `docker logs ac-sleep`.
   MySQL must stay running and unpaused throughout.
7. **Scenarios 7, 8 — connection during stasis.** With both targets paused,
   open the client. Watch `docker logs -f ac-sleep` for `[CONN]` / `[THAW]`,
   measure the time to the realm list, and verify login and world entry still
   work. No manual `sleepctl wake` should be needed.
8. **Scenario 11 — multi-hour soak.** Leave the stack idle for several hours
   (or overnight with the reduced timeout), then reconnect. Check for module
   errors, clock/timer anomalies, and confirm characters and state survived.
   This is the only test that validates long freezes against MySQL
   `wait_timeout` and module timers.
9. **Scenario 13 — host restart.** Restart the Compose project, then reboot
   the host. After boot, the supervisor must start, thaw any frozen targets,
   and accept a client without manual intervention.
10. **Scenario 14 — failure injection.** On the real stack, crash the
    supervisor with
    `docker exec ac-sleep pkill -9 -f '/usr/local/bin/monitor.sh'`, then
    `docker exec ac-sleep pkill -x socat`; verify automatic restart,
    `[SUPERVISOR]` listener respawn, thaw, and a successful reconnect. Do
    **not** use `docker kill` for this test: Docker treats it as a manual
    stop, so `restart: unless-stopped` will not restart the container (that is
    correct Docker behaviour, not a supervisor bug).
11. **Scenario 15 — module compatibility.** After a thaw, exercise the custom
    module commands and gameplay paths (hunts, challenge modes, content
    manager, etc.), check module logs for errors, and rerun `make e2e-smoke`.
    Pausing must not restart the process or reset module state.
12. **Restore and rollback.** Set `SLEEP_IDLE_TIMEOUT=600` back (or remove the
    override), `docker compose up -d`, then follow the rollback section of
    `docs/deploy-production.md` (remove the overlay from `COMPOSE_FILE`, run
    `docker compose up -d --remove-orphans`, verify direct ports 3724/8085 and
    a login).

## Troubleshooting

- **T00 SKIP**: `$AC_DIR` or its `docker-compose.yml` is absent. Set
  `AC_DIR=/absolute/path/to/azerothcore-wotlk`.
- **T00 fails on ports**: another Compose file is loaded after the sleep
  overlay, or the real project remaps the external ports. Ensure the overlay is
  last; T00 expects the default 3724/8085 mappings and does not infer remaps.
- **T00 fails on `ac-network`**: the real project uses another network name.
  T00 asserts the documented default; update the expected network in
  `run-tests.sh` (the overlay itself supports `SLEEP_NETWORK`).
- **Ports 13724/18085 already in use**: stop the conflicting stack, or change
  `AUTH_HOST_PORT`/`WORLD_HOST_PORT` in `run-tests.sh` (and the compose
  mappings together).
- **T06 CPU threshold**: see the note above; a busy loop on a very high-core
  host can be under 5 % of total CPU. Check the printed value before assuming a
  supervisor bug.
- **T15**: the guard target is intentionally `mock-mysql`, because the frozen
  protected-name pattern includes `mysql`. `mock-mysql` must remain
  `running`/`Paused=false` and the refusal line must appear.
- **Leftover projects after a hard interrupt**:

  ```bash
  docker compose -p sleep-selftest -f docker/test/test-compose.yml down --remove-orphans
  ```

  The temporary `sleep-guard-test` project is normally removed by the EXIT
  trap and by T15 itself. If the runner was killed with SIGKILL during T15,
  remove its containers manually (`docker rm -f mock-mysql
  ac-sleep-guard-test`) before rerunning.
- **Docker daemon not running**: T00 still works offline; T01 onward fails
  fast. Start Docker and rerun.
