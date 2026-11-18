# Audit — azeroth-sleep Docker adaptation

This document records the audit that motivated the Docker adaptation of
[andymarden/azeroth-sleep](https://github.com/andymarden/azeroth-sleep), the
design decisions that follow from it, and the risks that remain. It describes
the design; it is not a test report. Anything labelled *upstream* is a claim
made by the original project, not a measurement reproduced here.

Audited upstream revision: `bead762` (2025-02-19, branch `main`).

## 1. Upstream inventory (frozen facts)

The upstream repository contains 9 files. The three scripts and four unit
files are kept unchanged in the Docker fork; the README is rewritten for the
Docker installation and `LICENSE` gains a Docker-adaptation copyright line.
The adaptation adds a separate `docker/` tree.

| File | Role |
| --- | --- |
| `azeroth-monitor` | Bash loop (60 s). Counts TCP `ESTABLISHED` connections on the world ports (`8085` and the RA port `3443`) with an `ss ... sport = :<port>` filter for each, and after `IDLE_TIMEOUT` (300 s in the script) sends `kill -STOP` to `authserver` and `worldserver`, children first. Stores the last activity timestamp in `/tmp/azeroth_last_activity`. |
| `azeroth-proxy` | Bash + `socat TCP4-LISTEN:3724,fork`. For each connection it runs `azeroth-thaw`, then bridges to the authserver moved to port **3725** (it lives in the same network namespace as the proxy, hence the port shift). |
| `azeroth-thaw` | Bash. Resolves processes with `pgrep -f "<BIN_PATH>/authserver"` / `worldserver`, checks the process state with `ps -o state=`, and sends `kill -CONT` when the state contains `T`. Then sleeps 0.2 s. |
| `worldserver.service`, `authserver.service` | Example systemd units for the two AzerothCore daemons. |
| `azeroth-monitor.service`, `azeroth-proxy.service` | systemd units for the monitor and the proxy. |
| `README.md` | Installation and test notes for the systemd installation. |
| `LICENSE` | MIT, Copyright (c) 2025 andymarden. |

Upstream reports that on its LXC host (6 vCPU, 8 GB RAM) idle CPU was 37 %
(authserver ~1 vCPU, worldserver ~1.2 vCPU) and dropped to 0.09 % when frozen,
with a thaw under 200 ms. Those are **upstream figures**; they were not
re-measured during this audit.

### Open issues that shaped the design

- **Issue #1 — "Docker"**: an open request for Docker support, unanswered at
  audit time. This fork is the answer to that issue.
- **Issue #2 — "ac-dashboard-core cannot thaw"**: `azeroth-thaw` fails when the
  real binaries are started through wrapper scripts, because `pgrep -f` matches
  a command line that does not contain the expected binary path. The lesson is
  structural: **never identify processes by a command-line pattern**. A
  container name is a stable, declarative identifier, and it addresses every
  process in the container at once.
- Issue #3 asks for LXC documentation. It is out of scope for a Docker fork.

Two forks existed at audit time (FlannelNZ, Karmiven). Neither carries a Docker
adaptation: FlannelNZ adds two cosmetic commits (README, thaw), Karmiven is
identical to upstream. No public Docker implementation of this idea was
available to copy or compare against.

## 2. Environment the adaptation must fit

The reference deployment is an AzerothCore WotLK stack started with Docker
Compose:

- `docker-compose.yml` from AzerothCore, plus a local
  `docker-compose.override.yml`; both remain unmodified by this project.
- Fixed `container_name`s: `ac-database`, `ac-db-import`, `ac-worldserver`,
  `ac-authserver`, `ac-client-data-init`. These names are the targeting
  contract, not an implementation detail: Compose recreates services, but
  keeps the configured names.
- Network `ac-network`; internal ports `3724` (authserver `RealmServerPort`)
  and `8085` (worldserver `WorldServerPort`), published on the host through
  `DOCKER_AUTH_EXTERNAL_PORT` and `DOCKER_WORLD_EXTERNAL_PORT`.
- `restart: unless-stopped` on the long-running services.
- MySQL (`mysql:8.4`) is a separate service with a healthcheck. It must stay
  up permanently: the worldserver saves characters and the authserver reads
  the realmlist, and freezing the database would be both unnecessary and
  dangerous.
- No modification of AzerothCore sources, configuration semantics, or modules
  is acceptable.

## 3. Options considered

### 3.1 `docker pause` versus `SIGSTOP`

`SIGSTOP` freezes one process. `docker pause` uses the cgroup v2 freezer and
freezes **every task in the container atomically** — the main process, its
threads, and any child processes. Consequences:

| | `SIGSTOP` (upstream) | `docker pause` (this fork) |
| --- | --- | --- |
| Scope | One PID at a time; children must be enumerated and frozen first | Whole container in one kernel operation |
| Identification | `pgrep -f`, `ps` state `T` | Container name via Docker API |
| New children | Can be missed between scans | Frozen with the container |
| Race on freeze/thaw | Yes (parent/children ordering) | No |
| Portability | Needs host PID access | Works through the Docker socket |
| Failure mode | Half-frozen tree is possible | Container is running or paused |

A half-frozen process tree is the worst failure mode: the parent cannot be
thawed cleanly and the operator has to repair it by hand. The cgroup freezer
does not have that state. It also makes issue #2 structurally impossible: no
command line is inspected, only the container name declared in Compose.

`pause`/`unpause` is not `stop`/`start`. It keeps memory, open sockets, player
sessions, and module state intact. The wake path therefore does not boot the
server or reload maps: it resumes it. This is the property that makes the
approach compatible with any AzerothCore module without touching the core.

### 3.2 Container names instead of PID patterns

Docker Compose already guarantees stable names (or can be given
`container_name`). Targeting `ac-worldserver` and `ac-authserver`:

- avoids `pgrep` entirely (issue #2);
- works when the image starts the server through a shell, an entrypoint, or a
  wrapper script;
- covers all threads and child processes in one call;
- lets the supervisor refuse dangerous names (`database`, `mysql`, `db-import`,
  `ac-sleep` itself) before acting.

A PID-based approach would have to rediscover the layout after every Compose
recreate and every image change. That is precisely how the upstream thaw bug
happens.

### 3.3 Why the supervisor is not a C++ module

The requirement was an external supervisor unless a module is demonstrably
better. A module is not viable here:

- AzerothCore exposes no hook that both counts "real connected players" and
  suspends the whole server process.
- A module runs **inside** the worldserver thread. Freezing the process from
  inside freezes the thread that would have to perform the thaw; a separate
  watchdog inside the same process cannot run either. Self-freezing requires an
  external agent anyway.
- `kill -STOP`/`pause` of the whole container would still be an external
  operation; a module would add C++ to the core build (breaking the "no core
  changes" constraint) without removing the external component.
- Docker pause is also the operation an operator can audit and reverse with
  standard tools, independently of the game server's health.

The Docker supervisor therefore stays outside AzerothCore. It observes TCP
connections from its own network namespace and drives the Docker API. The
game stack is unmodified, upgradeable, and module-agnostic.

### 3.4 Both game ports behind the proxy

Upstream proxies only the auth port because the proxy and the server share a
host namespace and the authserver had to move to 3725. In this adaptation the
internal ports stay 3724/8085; `ac-sleep` publishes both host ports and bridges
to `ac-authserver:3724` / `ac-worldserver:8085` on `ac-network`.

Why both:

- **Fail-safe wake**: a client that connects directly to 8085 (custom
  `realmlist`, port forwarding, monitoring) still wakes the stack.
- **Authoritative player counting**: the supervisor counts `ESTABLISHED`
  sockets in its own namespace, including the client side of its own bridges.
  It never needs `docker exec` into a paused container (which would hang or
  fail).
- **Listener availability**: `socat` keeps listening while the backend is
  paused, so the TCP handshake always succeeds and the wake is transparent to
  the client.

Counting caveat: backend connections initiated by `ac-sleep` use ephemeral
source ports (32768–60999), so filtering on `sport = :3724 or sport = :8085`
does not count the proxy's own bridge sockets. Any established connection is
treated as activity. An unauthenticated connection keeps the stack awake; that
is the safe direction. Freezing happens only when there is **no** connection at
all.

### 3.5 Integration through a Compose overlay

The overlay pattern avoids forking or editing AzerothCore's Compose files:

- `docker-compose.sleep.yml` removes the published ports from
  `ac-authserver` and `ac-worldserver` (`ports: !override []`) and publishes
  them on `ac-sleep`.
- It must be loaded **last**, after `docker-compose.yml` and any user override.
  `ports: !override` is required because Compose merges port lists by
  concatenation otherwise.
- `COMPOSE_FILE` in the project `.env` makes a plain `docker compose up -d`
  keep working, with no wrapper command to remember.
- `SLEEP_BUILD_CONTEXT` (required, no default) supplies the **absolute** path
  to this fork's `docker/` directory as the image build context. Compose
  resolves a relative `build.context` against the base Compose file — the
  AzerothCore project directory — not against the overlay's location, so a
  relative context would build from the wrong directory. The required
  variable makes a missing configuration fail loudly instead of silently
  using the wrong context. It must be set for every Compose command that loads
  the overlay, even when the image is prebuilt.
- Host ports keep using `DOCKER_AUTH_EXTERNAL_PORT` /
  `DOCKER_WORLD_EXTERNAL_PORT`, so a host that remapped the ports keeps its
  mapping.

One caveat is documented in the README: if another override is loaded after
`docker-compose.sleep.yml` and re-declares the ports, the stack still freezes
correctly but the direct ports remain published, so a direct world connection
does not go through the wake proxy. Order in `COMPOSE_FILE` is part of the
contract.

### 3.6 Failure policy: stay awake

Every failure mode resolves toward availability:

- Docker CLI error, `ss` error, missing target, dead listener, inconsistent
  state → reset the idle timer, thaw anything frozen, log an error.
- Freeze only when: zero connections, all targets `running` and not paused,
  and idle ≥ `SLEEP_IDLE_TIMEOUT` (default 600 s; `0` disables freezing).
- Startup and shutdown of the supervisor attempt to thaw the targets, so a
  stack is not normally left frozen behind a dead proxy; failures are logged.
- Protected names (`ac-sleep`, `database`, `mysql`, `mariadb`, `db-import`)
  cannot be targeted, even by configuration mistake.
- Listeners are supervised: if `socat` dies, the monitor respawns it.

The cost of a wrong "awake" is CPU; the cost of a wrong "asleep" is an
unreachable server. The policy is deliberately asymmetric.

## 4. Clock and timer risk of cgroup freeze

The cgroup freezer stops CPU time, not the kernel's clocks. `CLOCK_MONOTONIC`
(`std::chrono::steady_clock` on Linux) keeps advancing while the container is
paused. When the container resumes, every thread observes a time jump equal to
the freeze duration.

AzerothCore's main loop is diff-driven:

- `WorldUpdateLoop()` computes `diff = getMSTimeDiff(realPrevTime,
  realCurrTime)` with `getMSTime()` derived from `steady_clock` since process
  start, then calls `World::Update(diff)`.
- `EventMap` stores deadlines relative to an internal `_time` advanced by that
  diff. On the first update after a thaw, all events whose deadline elapsed
  during the freeze are due at once and are executed in that update
  (`ExecuteEvent()` returns them one by one; each is **fired once**, not
  replayed for every missed interval).
- Game time (`GameTime`) jumps forward by the freeze duration as well. Daily
  quests, resets, respawn timers, and cooldowns therefore see elapsed time, as
  they would after a host suspend.

What this means in practice:

- Periodic events do not "catch up" by looping hundreds of times; they execute
  once and reschedule. The thaw cost is a burst of due events, not a replay of
  the frozen period.
- A freeze longer than the `uint32` millisecond range (~49.7 days) would make
  the diff wrap. This is far outside the intended use (idle hours) and is not
  supported.
- `MaxCoreStuckTime` (whose `FreezeDetector` aborts the worldserver when the
  update loop does not advance) defaults to **0 (disabled)** in AzerothCore.
  With it disabled, the freeze cannot trip the detector. Administrators who
  enable it should keep the value well above any expected freeze duration and
  validate thawing; a monitor that fires immediately after a long pause sees a
  large monotonic delta by construction.
- The supervisor never depends on the game containers' clocks: its idle
  accounting uses epoch seconds, and the actual freeze decision runs in a
  separate container that is never paused.

The upstream project reports successful field use with `SIGSTOP`, which also
produces a monotonic jump at `SIGCONT`. That is field evidence, not a
guarantee for every module. Long-freeze behavior is therefore part of the
production validation checklist (overnight soak), not an assumption.

## 5. MySQL `wait_timeout`

MySQL closes idle client connections after `wait_timeout`, 28800 s (8 hours)
by default in MySQL 8.4. `ac-sleep` never pauses `ac-database`, but the
worldserver's and authserver's own TCP connections to it are frozen along with
their containers: during the freeze they send nothing, so the server may reap
them.

AzerothCore handles this lazily:

- On `CR_SERVER_GONE_ERROR`, `CR_SERVER_LOST`, or `CR_SERVER_LOST_EXTENDED`,
  `MySQLConnection::_HandleMySQLErrno()` closes the handle, reopens the
  connection, re-prepares statements, and retries (up to 5 attempts, 3 s
  apart).
- If all attempts fail, the core aborts **by design** ("terminating the server
  to prevent data corruption") rather than continue with a broken database
  session.
- The reconnect happens on the first query after the thaw, not at thaw time,
  so a player login is the trigger.

Expected impact:

- Default `SLEEP_IDLE_TIMEOUT` (600 s) is far below `wait_timeout`; normal
  overnight idling does not reach it unless the server stays empty for more
  than 8 hours (for example a server that is only played on weekends).
- If an administrator lowered `wait_timeout`, or the empty period exceeds it,
  the first post-thaw queries should transparently reconnect. That path is
  plausible from the code but has **not** been measured here; the production
  overnight soak exists to confirm it. If reconnection failed, the failure is
  loud (fatal log and process exit), not silent corruption.

Nothing in the sleep design changes the database, executes SQL, or stops the
database container. No game save runs during the freeze because the
worldserver is not running; committed database state is unaffected. Pending
periodic saves are written by the worldserver after the thaw, as after any
process pause.

## 6. Security analysis: Docker socket

`ac-sleep` needs the Docker socket to inspect, pause, and unpause containers.
This is the most important security property of the project, and it must be
stated plainly:

> Access to `/var/run/docker.sock` is equivalent to root on the host. The
> Docker API can create a privileged container that mounts the host filesystem,
> so any process that can talk to the socket can take over the machine.

The supervisor mounts the socket read-write (pause/unpause/inspect are API
calls, not filesystem reads). It runs as root inside the container because the
socket's group ID varies per host and the container must be able to use it.
That does not make the exposure worse than it already is for any host user in
the `docker` group, but it means the trust boundary is the host, not the
container.

Mitigations applied to the container:

- `read_only: true` root filesystem, with `tmpfs` on `/tmp` only;
- `cap_drop: ALL` and `security_opt: no-new-privileges:true`;
- `init: true` for signal handling and zombie reaping;
- no published admin port: only the two game ports are exposed;
- a small Alpine image with `bash`, `socat`, `iproute2`, `docker-cli`; no
  database credentials, no `.env`, no game secrets;
- no host network, no host PID namespace, no mounted game volumes;
- `restart: unless-stopped`, so the proxy returns after a host reboot and
  thaws the stack on start.

Why a socket proxy was **not** used: the common `docker-socket-proxy` image
configured with `CONTAINERS=1` still permits container create/exec/start
operations, which are themselves enough to obtain host root (create a
privileged container, or exec into one that mounts the host). Filtering to
`inspect`/`pause`/`unpause` would genuinely reduce the API surface, but it
requires a proxy with a hand-written allowlist — another component in the
trust path, with its own attack surface and failure modes — and it was not
part of the validated design. It is listed as possible future hardening. The
real reduction is to not mount the socket at all: see the host systemd
alternative below.

Additional operational rules:

- Never expose the Docker socket over TCP; keep it a Unix socket with host
  permissions.
- Treat any account that can `docker exec` into `ac-sleep` as host root.
- Do not run `ac-sleep` on a host shared with untrusted users.
- The monitor refuses to pause database-like container names.

Host systemd alternative (no socket in a container): run the same monitor
directly on the host under a dedicated user and grant **only** the exact
commands it needs, for example a sudoers rule limited to
`/usr/bin/docker inspect`, `/usr/bin/docker pause`, and
`/usr/bin/docker unpause` on the two named containers. This avoids giving any
container the socket, at the cost of host-level installation. The upstream
systemd scripts remain available for bare-metal installations; they are not a
drop-in for Compose because they target processes, not containers.

## 7. Network and failure behavior

- **Proxy dies during a session**: established bridges are owned by `socat`
  inside `ac-sleep`; if the container dies, clients are disconnected and the
  host ports disappear until Docker restarts the container. On restart, the
  entrypoint attempts to thaw the stack before accepting connections, so the
  reconnect path is clean. `restart: unless-stopped` bounds the outage to a
  container restart, not a game-server reboot.
- **Listener dies while the supervisor lives**: the monitor checks that both
  ports are listening and respawns `socat`; the event is logged as
  `[SUPERVISOR]`.
- **Freeze fails halfway**: `docker pause` is per container, so a second
  container can fail after the first succeeded. The monitor then attempts to
  thaw everything, resets the idle timer, and logs an error. The intent is to
  keep the stack awake and consistent rather than half frozen; a failed thaw
  is logged and visible in the next status/iteration.
- **Supervisor restarts**: startup attempts to thaw all targets. Under normal
  operation a frozen stack does not sit behind a proxy that just restarted;
  a failed thaw is logged, and the next activity/error cycle retries it.
- **`docker stop`/`down` while frozen**: a paused process cannot handle
  `SIGTERM` while it is frozen. Depending on the Docker version, stopping a
  paused container may be refused with a "container is paused" error, may end
  in a forced kill after the stop timeout, or may internally resume the
  container to deliver the signal. None of these gives the worldserver a
  predictable chance to flush state. Always wake the stack first
  (`sleepctl wake`, or `docker unpause`) before stopping, recreating, or
  attaching. This is documented in the README and the runbook.
- **Host reboot**: Docker starts `ac-sleep` (`unless-stopped`) and the game
  containers; the entrypoint attempts to thaw anything it finds paused. There
  is no persistent "paused" flag across a host restart, so this converges to a
  live stack.

## 8. What the audit did not establish

- No CPU measurement, thaw latency, or soak result is reported in this
  document. The self-contained harness measures CPU on mock containers; the
  production runbook measures the real stack. See the README's test section
  for the exact status.
- Client-visible behavior (character list, entering the world, relogging after
  hours) must be validated with a real WoW client through the production
  network path; that is a runbook step, not an audit conclusion.
- MySQL reconnection after a freeze longer than `wait_timeout` is expected from
  the code path but unproven by measurement.
- The upstream playerbots observation (sometimes no active bots after a thaw)
  is inherited from upstream and is not diagnosed here.

## 9. Decision summary

| Decision | Rationale |
| --- | --- |
| `docker pause`/`unpause` on named containers | Atomic cgroup freeze, state preserved, no PID matching |
| Never target MySQL / database names | Data safety; the database must stay available |
| Proxy both game ports | Fail-safe wake, authoritative counting, listener always up |
| Compose overlay + `COMPOSE_FILE` | No upstream file modified; plain `up -d` keeps working |
| Required `SLEEP_BUILD_CONTEXT` | Correct build context despite Compose's base-file path resolution; fail loudly if unset |
| No C++ module | No core hook; external supervisor is the only self-consistent design |
| External supervisor container | Auditable, reversible with standard Docker commands |
| Fail toward awake | A false wake costs CPU; a false freeze costs availability |
| Socket mounted, container hardened | Required for the API; residual risk documented |
| systemd alternative documented | Only way to remove the socket from the container |
