# azeroth-sleep — Docker adaptation

`azeroth-sleep` puts an AzerothCore WotLK server into a near-zero-CPU state when
nobody is playing, and wakes it automatically on the next connection. When no
client has been connected for a configurable delay, the worldserver and
authserver containers are frozen with `docker pause`; an always-on TCP proxy
inside a small supervisor container accepts the next connection, unpauses the
stack, and bridges the client through. MySQL keeps running the whole time.

This is the Docker Compose adaptation of
[andymarden/azeroth-sleep](https://github.com/andymarden/azeroth-sleep) (MIT).
It answers the upstream "Docker" feature request (#1) while keeping the
original scripts and systemd units untouched — see
[Classic install (systemd)](#classic-install-systemd) at the end.

Nothing in AzerothCore is patched. No module is added or modified. No
character, account, or world data is touched. Pausing preserves the server's
memory, open sockets, player sessions, and module state; waking resumes it
rather than restarting it.

- Audit and design rationale: [`docs/audit.md`](docs/audit.md)
- Production runbook (including Ubuntu on a Mac mini): [`docs/deploy-production.md`](docs/deploy-production.md)
- License: MIT, original work by andymarden, Docker adaptation by Phanty78.

## Contents

1. [How it works](#how-it-works)
2. [What is frozen, what never is](#what-is-frozen-what-never-is)
3. [Prerequisites](#prerequisites)
4. [Installation with Docker Compose](#installation-with-docker-compose)
5. [Adding it to an existing AzerothCore install](#adding-it-to-an-existing-azerothcore-install)
6. [Configuration variables](#configuration-variables)
7. [Port management](#port-management)
8. [`docker pause` versus `SIGSTOP`](#docker-pause-versus-sigstop)
9. [Automatic wake](#automatic-wake)
10. [Administration](#administration)
11. [Logs and diagnosis](#logs-and-diagnosis)
12. [Module compatibility](#module-compatibility)
13. [Tests](#tests)
14. [Known limits](#known-limits)
15. [Rollback](#rollback)
16. [Uninstall and upgrades](#uninstall-and-upgrades)
17. [Security](#security)
18. [Attribution](#attribution)
19. [Classic install (systemd)](#classic-install-systemd)

## How it works

```
                        WoW client(s)
               auth :3724        world :8085
                    |                 |
                    v                 v
      +-------------------------------------------+
      |                 ac-sleep                  |
      |  (separate container, never paused)       |
      |                                           |
      |  socat :3724        socat :8085           |
      |       \                /                  |
      |        \__ bridge.sh _/                   |
      |               |                           |
      |        monitor loop                       |
      |   ss established + docker pause/unpause   |
      +----------+------------------+-------------+
                 |                  |
      ac-network |                  | /var/run/docker.sock
                 v                  v
      +--------------------+   +--------------------+
      |   ac-authserver    |   |   ac-worldserver   |
      |   :3724            |   |   :8085            |
      |   pause / unpause  |   |   pause / unpause  |
      +---------+----------+   +---------+----------+
                 \                    /
                  \                  /
                   v                v
                +----------------------+
                |     ac-database      |
                |  MySQL :3306         |
                |  never paused        |
                +----------------------+
```

A more precise view of the control path:

```
clients --TCP--> ac-sleep socat --TCP--> ac-authserver:3724 / ac-worldserver:8085
                    |                                 |
                    | docker unpause                  | (frozen together)
                    v                                 v
              Docker Engine <---- monitor: inspect/pause/unpause
```

Lifecycle:

1. A client connects to the host's auth (`3724`) or world (`8085`) port. The
   connection is accepted by `socat` inside `ac-sleep`; this works even while
   the game containers are paused, because the listeners are never paused.
2. The per-connection handler logs `[CONN]`, unpauses every target, and then
   bridges the connection to the real service over `ac-network`.
3. Every `SLEEP_CHECK_INTERVAL` seconds the monitor counts `ESTABLISHED` TCP
   connections on both game ports from inside its own network namespace. Any
   connection counts as activity.
4. When there has been no connection for `SLEEP_IDLE_TIMEOUT` seconds, and
   every target is running and not already paused, the monitor issues
   `docker pause` on each target. The database is never a target.
5. Any error or inconsistency (Docker API, `ss`, missing container, dead
   listener, half-frozen stack) resolves toward staying awake: the idle timer
   is reset, frozen targets are thawed, and the event is logged.

The supervisor container is the only component that knows about Docker. The
game containers keep their normal images, configuration, volumes, and
restart policies.

## What is frozen, what never is

Frozen by default:

- `ac-worldserver`
- `ac-authserver`

Never frozen:

- `ac-database` (MySQL): the authserver and worldserver need it, and freezing
  a database is both unnecessary and unsafe.
- `ac-db-import`, `ac-client-data-init`: short-lived setup containers.
- `ac-sleep` itself: it must stay alive to receive the wake connection.

The default target list is `SLEEP_TARGET_CONTAINERS="ac-worldserver
ac-authserver"`. A container whose name matches
`(ac-sleep|database|mysql|mariadb|db-import)` is refused with
`[ERROR] refusing to manage protected container '...'`, even if it is
configured by mistake.

`docker pause` freezes the whole container (all processes and threads) via the
kernel cgroup freezer. It is not `docker stop`: the container remains in
memory, sockets stay open, player sessions stay in the process, and no image
or volume is touched. `docker unpause` resumes exactly where the process
stopped.

## Prerequisites

- A Linux host with Docker Engine and the Compose plugin. The production
  target of this fork is Ubuntu 24.04; Docker Desktop is fine for local
  testing.
- Docker Compose **2.24.4 or newer** (a current release is recommended). The
  overlay uses the `!override` YAML tag to replace (not concatenate) port
  lists, so the Compose release must support that tag. `docker compose
  version` should report a recent v2 or v5 release.
- An existing AzerothCore WotLK deployment started with Docker Compose, with:
  - fixed container names `ac-worldserver` and `ac-authserver`
    (AzerothCore's standard `docker-compose.yml` already sets them);
  - a Compose network named `ac-network` (the default);
  - internal game ports `3724` and `8085`, or values supplied through the
    variables described below.
- Host ports `3724` and `8085` will be handed from the game containers to
  `ac-sleep`. They must not be used by any other service; the existing
  AzerothCore stack currently owns them.
- Permission to use the Docker socket (`/var/run/docker.sock`) on the host.
- No `socat`, `ss`, or `iproute2` installation on the host: everything needed
  is inside the supervisor image.

For the upstream bare-metal installation, see
[Classic install (systemd)](#classic-install-systemd).

## Installation with Docker Compose

The examples assume:

- AzerothCore project: `<AC_DIR>` (for example `/opt/azerothcore`);
- this fork: `/opt/azeroth-sleep`.

### 1. Clone the fork

```bash
sudo git clone https://github.com/Phanty78/azeroth-sleep.git /opt/azeroth-sleep
```

Putting it under `/opt` is only a convention; any path works as long as you
use it consistently.

### 2. Add the overlay and its build context to the AzerothCore `.env`

Open the AzerothCore project's `.env` file (it already contains your database
password; keep it private and never commit it). Add `SLEEP_BUILD_CONTEXT` and
set `COMPOSE_FILE` (append the overlay last if the variable already exists):

```dotenv
SLEEP_BUILD_CONTEXT=/opt/azeroth-sleep/docker
COMPOSE_FILE=docker-compose.yml:docker-compose.override.yml:/opt/azeroth-sleep/docker/docker-compose.sleep.yml
```

`SLEEP_BUILD_CONTEXT` is **required** and has no default. It must be the
absolute path to the `docker/` directory of this fork. It exists because
Compose resolves a relative `build.context` against the **base** Compose file
(the AzerothCore project directory), not against the overlay's directory. With
this variable, Compose builds the supervisor image from the correct directory
and tags it as `azerothsleep/ac-sleep:latest` (or `SLEEP_IMAGE`). If the
variable is unset, the overlay fails with a required-variable error instead of
building from the wrong directory.

If you want to prebuild during pre-flight, do it from the fork (or let
Compose build it on the first `up -d`):

```bash
sudo docker build -t azerothsleep/ac-sleep:latest /opt/azeroth-sleep/docker
```

If your user is in the `docker` group, omit `sudo`. If you override
`SLEEP_IMAGE`, build that same tag.

Rules for `COMPOSE_FILE`:

- **The overlay must be last.** It removes the published ports from
  `ac-authserver` and `ac-worldserver` and publishes them on `ac-sleep`.
- Only list `docker-compose.override.yml` if that file exists. If you do not
  have one, use:

  ```dotenv
  COMPOSE_FILE=docker-compose.yml:/opt/azeroth-sleep/docker/docker-compose.sleep.yml
  ```

- If `COMPOSE_FILE` is already defined in your `.env`, do not add a second
  definition. Append `:/opt/azeroth-sleep/docker/docker-compose.sleep.yml` to
  the existing value instead, keeping the overlay last.
- Use an absolute path for the overlay. Paths inside a merged Compose project
  are evaluated relative to the base file, so a relative overlay path is
  confusing and error-prone.
- The `:` separator is for Linux and macOS. This fork targets Linux.

Validate the merged configuration before starting anything:

```bash
cd <AC_DIR>
docker compose config >/dev/null
```

This does not need a running daemon. It catches a missing overlay file, an
unset `SLEEP_BUILD_CONTEXT`, a wrong network name, and YAML errors.

### 3. Start the stack

```bash
cd <AC_DIR>
docker compose up -d
```

Compose builds the supervisor image if it is not present, recreates
`ac-authserver` and `ac-worldserver` (their published ports are removed), and
creates `ac-sleep`. Players connected at that moment are disconnected;
schedule a short maintenance window, or run the production runbook in
`docs/deploy-production.md`.

If you prebuilt the image, Compose reuses it. If you changed the Dockerfile
and want to force a rebuild, use:

```bash
docker compose up -d --build ac-sleep
```

### 4. Verify

```bash
cd <AC_DIR>
docker compose ps
```

Expected:

- `ac-sleep` is running and publishes `3724` and `8085`;
- `ac-authserver` and `ac-worldserver` are running and publish no host ports;
- `ac-database` is running and unchanged.

Then check the supervisor's own view:

```bash
docker exec ac-sleep monitor.sh status
```

or, from the fork:

```bash
/opt/azeroth-sleep/docker/sleepctl.sh status
```

`status` reports each target's state, the number of client connections, the
idle time against the timeout, the listener state, and whether freezing is
enabled. It exits non-zero if the Docker API is unreachable.

The stack is now in "stay awake" mode until the idle timeout expires. Do not
expect an immediate freeze on a server that has just started: the idle timer
starts when the supervisor starts.

### Optional: install the `sleepctl` convenience command

```bash
sudo ln -s /opt/azeroth-sleep/docker/sleepctl.sh /usr/local/bin/sleepctl
```

Examples in this README use `sleepctl`; if you skip the symlink, call
`/opt/azeroth-sleep/docker/sleepctl.sh` instead.

## Adding it to an existing AzerothCore install

The overlay is additive. No AzerothCore file is edited, and no AzerothCore
image is rebuilt:

- Keep `docker-compose.yml` and `docker-compose.override.yml` as they are.
- Add the overlay to `COMPOSE_FILE` as shown above, last in the list, and set
  `SLEEP_BUILD_CONTEXT` to the absolute path of this fork's `docker/`
  directory. Compose builds only the small `ac-sleep` image; the game images
  are reused.
- Keep the fixed `container_name` values. They are the supervisor's targeting
  contract. If your installation renamed them, set
  `SLEEP_TARGET_CONTAINERS`, `SLEEP_BACKEND_AUTH`, and
  `SLEEP_BACKEND_WORLD` accordingly (see the variable table).
- If your Compose network is not the default `ac-network`, set
  `SLEEP_NETWORK` to the network **key** used by the AzerothCore Compose
  project. Compose adds any project prefix to the real Docker network name;
  the key is what the overlay references.
- If you remapped the host ports with `DOCKER_AUTH_EXTERNAL_PORT` /
  `DOCKER_WORLD_EXTERNAL_PORT`, keep those values. The overlay reuses them,
  so clients do not change anything.
- If you already have a `COMPOSE_FILE` list, preserve its order and append the
  overlay at the end. A later file that re-declares the game ports can break
  the port handover (see [Port management](#port-management)).
- MySQL does not need to be reachable from the internet. The overlay does not
  change the database service or its ports.

The only disruption is the recreation of the auth and world containers, which
happens once when the overlay is first applied. Worldserver restarts after an
authserver restart are normal AzerothCore behavior; if your installation uses
the realmlist `flag` workaround, apply it as usual.

## Configuration variables

Variables are read by Compose from the AzerothCore project's `.env`. Most are
passed to `ac-sleep`; `SLEEP_BUILD_CONTEXT` is used only to build the image
and is not passed into the container. Changes require recreating the
supervisor container:

```bash
cd <AC_DIR>
docker compose up -d --force-recreate ac-sleep
```

| Variable | Default | Used by | Meaning |
| --- | --- | --- | --- |
| `SLEEP_BUILD_CONTEXT` | **required, no default** | overlay (Compose interpolation) | Absolute path to this fork's `docker/` directory, used as the image build context. The overlay fails with a required-variable error if it is unset. Not passed into the container. |
| `SLEEP_TARGET_CONTAINERS` | `ac-worldserver ac-authserver` | overlay | Space- or comma-separated container names to pause. Protected names are refused. |
| `SLEEP_IDLE_TIMEOUT` | `600` | overlay | Seconds without any client connection before freezing. `0` disables freezing entirely (kill switch). |
| `SLEEP_CHECK_INTERVAL` | `30` | overlay | Seconds between monitor iterations. Also the granularity of listener supervision. |
| `SLEEP_LISTEN_AUTH` | `3724` | overlay | Port the auth listener binds **inside** `ac-sleep`. |
| `SLEEP_LISTEN_WORLD` | `8085` | overlay | Port the world listener binds inside `ac-sleep`. |
| `SLEEP_BACKEND_AUTH` | `ac-authserver:3724` | overlay | Real auth backend on `ac-network` (`host:port`). |
| `SLEEP_BACKEND_WORLD` | `ac-worldserver:8085` | overlay | Real world backend on `ac-network` (`host:port`). |
| `SLEEP_NETWORK` | `ac-network` | overlay | Compose network **key** joined by `ac-sleep`. |
| `SLEEP_CONTAINER_NAME` | `ac-sleep` | overlay, `sleepctl` | Name of the supervisor container. |
| `SLEEP_IMAGE` | `azerothsleep/ac-sleep:latest` | overlay | Image tag for the supervisor. Compose builds and tags it from `SLEEP_BUILD_CONTEXT`; if you prebuild, use this tag. |
| `SLEEP_DOCKER_SOCKET` | `/var/run/docker.sock` | overlay | Host path of the Docker socket mounted into `ac-sleep`. Adjust for rootless Docker. |
| `DOCKER_AUTH_EXTERNAL_PORT` | `3724` | overlay, base file | Host port (optionally `ip:port`) published by `ac-sleep` for auth. |
| `DOCKER_WORLD_EXTERNAL_PORT` | `8085` | overlay, base file | Host port published by `ac-sleep` for world. |
| `DOCKER_SOAP_EXTERNAL_PORT` | `7878` | base file only | SOAP port of the worldserver. Not published while the overlay is active (see [Port management](#port-management)). |

Notes:

- `SLEEP_LISTEN_*` is the container-side port; clients use
  `DOCKER_*_EXTERNAL_PORT` on the host. With the defaults, host and container
  ports are both 3724/8085.
- `SLEEP_BACKEND_*` follows the **internal** AzerothCore ports (`RealmServerPort`
  and `WorldServerPort`), not the published ones.
- `SLEEP_BUILD_CONTEXT` is required for every Compose command that loads the
  overlay, including `docker compose config` and `docker compose build`, even
  if you already prebuilt the image with `docker build`. Use an absolute path
  (`/opt/azeroth-sleep/docker`, or your checkout's `docker/` directory). It is
  not a secret and is not passed to the container.
- `SLEEP_CONTAINER_NAME` is used by Compose to name the container and by
  `sleepctl` on the host. The host-side script reads it from its own
  environment, not from the AzerothCore `.env`; export it in your shell or use
  `sleepctl -n NAME` if you changed it.
- Quote values containing spaces in `.env`, for example
  `SLEEP_TARGET_CONTAINERS="ac-worldserver ac-authserver"`.
- `SLEEP_*` values must not contain secrets. The overlay passes no database
  credentials to `ac-sleep`.

## Port management

Before the overlay, the host ports are published by the game containers:

```
host :3724 -> ac-authserver :3724
host :8085 -> ac-worldserver :8085
host :7878 -> ac-worldserver :7878   (SOAP, upstream default)
```

After the overlay:

```
host :3724 -> ac-sleep :3724 -> ac-authserver :3724   (inside ac-network)
host :8085 -> ac-sleep :8085 -> ac-worldserver :8085
```

`ac-authserver` and `ac-worldserver` no longer publish any host port, because
the overlay clears their port lists with `ports: !override []`. Any custom
port publication those services had is removed as well; only 3724 and 8085
are proxied by `ac-sleep`.

Operational consequences:

- **Port ownership moves to `ac-sleep`.** Only one process can bind a host
  port. If another service still publishes 3724/8085, `docker compose up -d`
  fails with a port-allocation error. Remove the conflicting publication or
  change the external port variables.
- **Keep the overlay last.** If a Compose file loaded after it re-declares
  `3724:3724` or `8085:8085`, the stack either fails to start (bind conflict
  with `ac-sleep`) or publishes the ports directly if remapped. A direct 8085
  connection bypasses the wake proxy and will not wake a paused worldserver.
- **SOAP (7878) is not published while the overlay is active.** The blanket
  port reset removes it along with the game ports. SOAP is not proxied by
  `ac-sleep`; a SOAP call to a paused worldserver would hang until something
  else wakes the stack. If you need remote SOAP, keep it on a trusted
  management network and expect to wake the stack first; do not re-publish
  3724/8085 directly. Local-only SOAP access through `docker exec`/the
  container network is unaffected.
- **Do not run the `dev` Compose profile with the overlay.** `ac-dev-server`
  publishes the same 3724/8085 ports and would conflict with `ac-sleep`.
- **Firewall/Tailscale:** allow TCP 3724 and 8085 to the host (or to the
  `ac-sleep` container via the host). Do not expose MySQL. No admin port is
  published by `ac-sleep`; administration goes through `docker exec` on the
  host.
- **Changing external ports:** set `DOCKER_AUTH_EXTERNAL_PORT` /
  `DOCKER_WORLD_EXTERNAL_PORT` in `.env`, then recreate `ac-sleep` and, if
  needed, the game services. Clients update their `realmlist` only if the
  world/auth ports they use change. For example:

  ```dotenv
  DOCKER_AUTH_EXTERNAL_PORT=13724
  DOCKER_WORLD_EXTERNAL_PORT=18085
  ```

  The internal backend ports (`SLEEP_BACKEND_*`) stay at 3724/8085 unless your
  AzerothCore configuration changed them. The client's `realmlist` only names
  the auth host (port 3724 by default); the world address and port come from
  `acore_auth.realmlist`, so keep that row's `address` and `port` consistent
  with what clients can reach. A stock 3.3.5 client always connects to the
  auth port 3724, so remapping `DOCKER_AUTH_EXTERNAL_PORT` requires a
  client-side port forward or a custom client; remapping the world port only
  requires updating the realmlist row.
- **`SLEEP_LISTEN_*` changes** are internal to `ac-sleep`. If you change them,
  the overlay's port mapping `${DOCKER_*_EXTERNAL_PORT}:${SLEEP_LISTEN_*}`
  follows automatically, so the host side can stay the same.

Check the published ports with Compose (authoritative), and the listeners from
inside the supervisor:

```bash
docker compose ps
docker port ac-sleep
docker exec ac-sleep ss -Hltn
```

A host-side `ss -ltn` may not show ports published through Docker's NAT rules;
do not use it as the only check. The important facts are that `ac-sleep`
publishes 3724/8085 and the game containers publish nothing.

## `docker pause` versus `SIGSTOP`

The upstream project uses `kill -STOP` / `kill -CONT` on PIDs found with
`pgrep -f`. This fork uses `docker pause` / `docker unpause` on container
names.

| | `SIGSTOP` / `SIGCONT` | `docker pause` / `unpause` |
| --- | --- | --- |
| Scope | One process per signal | Every process and thread in the container, atomically |
| Discovery | `pgrep -f` on command lines | Container name (Compose contract) |
| Wrapper scripts | Breaks: the command line may not contain the binary path (upstream issue #2) | Unaffected: containers are named, not matched by command line |
| Child processes | Must be enumerated and frozen first | Frozen with the container |
| Partial state | A half-frozen process tree is possible | Container is either running or paused |
| State on resume | Preserved | Preserved (memory, sockets, sessions, module state) |
| Restart | None | None; it is not `stop`/`start` |

Freezing is atomic from the kernel's point of view, so the monitor cannot
freeze a parent while a child keeps running (or the reverse). Identification by
container name also survives image changes, entrypoint wrappers, and Compose
recreations. Full background, including the clock and database implications,
is in [`docs/audit.md`](docs/audit.md).

The supervisor follows a strict decision table:

- **Any error or doubt** → stay awake, thaw what is frozen, log `[ERROR]`.
- **At least one connection** → activity; reset the idle timer; thaw if
  anything is frozen (`[THAW] reason=activity`).
- **Zero connections, idle below timeout** → do nothing.
- **Zero connections, all targets running, idle ≥ timeout** → pause each
  target (`[FREEZE] ...`).
- **Zero connections, mixed paused/running targets** → thaw everything and
  log `[RECONCILE]` (inconsistent state).
- **Zero connections, all targets paused** → nothing to do.
- **`SLEEP_IDLE_TIMEOUT=0`** → never freeze.

`docker pause` is not a supported way to stop a server for maintenance. See
[Known limits](#known-limits) for the shutdown warning.

## Automatic wake

Wake is driven by the connection itself, not by a poll of the game server:

1. `socat` accepts the TCP connection on the published port and forks a
   handler.
2. The handler logs `[CONN] new connection, waking stack` and runs the thaw
   routine, which unpauses every paused target.
3. The handler then bridges the client socket to
   `ac-authserver:3724` or `ac-worldserver:8085` over `ac-network`.

Both the auth and the world port are proxied, so a client that connects
directly to 8085 also wakes the stack. Because the listener is alive during
the freeze, the TCP handshake succeeds immediately; the client waits while
the containers resume and the backend accepts the bridged connection.

Additional wake paths:

- **Monitor self-heal:** if a connection is observed while a target is
  paused (for example a race with a freeze), the monitor thaws it on its next
  iteration and logs `[THAW] reason=activity`.
- **Supervisor startup:** the entrypoint attempts to thaw all targets before
  starting the listeners. Under normal operation a restarted proxy does not
  leave a frozen stack behind it; a failed thaw is logged.
- **Manual:** `sleepctl wake` (or `docker unpause <container>`).

Upstream reports a thaw under 200 ms. This repository does not claim a
measured latency; measure it on your host with the timestamps of the
`[CONN]` and `[THAW]` log lines, and with a real client as described in the
production runbook.

## Administration

### `sleepctl`

`sleepctl` is a host-side convenience wrapper around `docker exec`; it has no
dependencies beyond Docker and bash.

```bash
sleepctl status           # target states, connections, idle, listeners, mode
sleepctl wake             # unpause all targets now
sleepctl freeze           # pause all targets now (one-shot)
sleepctl logs             # docker logs --tail 100
sleepctl -n ac-sleep status
```

The container name can be set with `-n NAME` or `SLEEP_CONTAINER_NAME`
(default `ac-sleep`). Unknown subcommands print usage. `freeze` is intended
for testing or maintenance on an empty server; if players are connected, the
monitor's next activity check will thaw the stack again.

The same operations without the wrapper:

```bash
docker exec ac-sleep monitor.sh status
docker exec ac-sleep monitor.sh wake
docker exec ac-sleep monitor.sh freeze
docker logs --tail 100 ac-sleep
```

### Reading the log tags

The supervisor writes one line per event to stderr, with a UTC timestamp and a
level, for example:

```
2026-01-01T12:00:00Z [INFO] [FREEZE] ac-worldserver paused (idle 612s)
2026-01-01T12:00:00Z [INFO] [FREEZE] ac-authserver paused (idle 612s)
```

| Tag | Meaning |
| --- | --- |
| `[FREEZE]` | A target was paused after the idle timeout. |
| `[THAW]` | A target was unpaused, or activity triggered a wake (`reason=activity`). |
| `[RECONCILE]` | Mixed paused/running state was detected; everything was thawed. |
| `[SUPERVISOR]` | A `socat` listener was missing and has been respawned. |
| `[CONN]` | A client connection was accepted and is waking the stack. |
| `[ERROR]` | Docker/`ss`/state error; the stack is kept awake. |
| `[EXIT]` | The supervisor is stopping; targets are left awake. |

The exact surrounding text can evolve; the bracketed tags are the stable part.

## Logs and diagnosis

Follow the supervisor:

```bash
docker logs -f ac-sleep
docker logs --since 1h ac-sleep
docker logs ac-sleep 2>&1 | grep -E '\[(FREEZE|THAW|RECONCILE|SUPERVISOR|ERROR)\]'
```

Inspect the state directly:

```bash
docker exec ac-sleep monitor.sh status
docker exec ac-sleep ss -Htn state established
docker inspect -f '{{.State.Status}} paused={{.State.Paused}}' ac-worldserver ac-authserver
docker stats --no-stream ac-sleep ac-worldserver ac-authserver
```

Typical diagnoses:

| Symptom | What to check | Action |
| --- | --- | --- |
| Never freezes | `status` shows connections > 0; `SLEEP_IDLE_TIMEOUT=0`; Docker API errors | Close idle clients, raise/lower the timeout, fix the Docker socket; the monitor stays awake on purpose when unsure. |
| Frozen but no wake on connect | `status` listeners; `[SUPERVISOR]` lines; listener ports; `ac-sleep` restart policy | Restart `ac-sleep`; its startup attempts to thaw the stack. Check host firewall/Tailscale ACLs. |
| Repeated `[SUPERVISOR] listener respawned` | `docker logs ac-sleep` around the respawn; port conflict; image entrypoint | Recreate `ac-sleep`; verify no other process binds the container port. |
| Repeated `[RECONCILE]` | Someone paused/unpaused one target manually; another tool changed a container's state | Let the monitor converge; avoid mixing manual pause/unpause with the supervisor. |
| `[ERROR]` from Docker | Socket mounted? container names correct? daemon reachable? | `docker exec ac-sleep docker version`; fix `SLEEP_DOCKER_SOCKET` / names / permissions. |
| Stack looks hung during maintenance | It may be paused | `sleepctl wake` before `docker stop`, `compose down`, or `docker attach`. |

Game logs remain in the AzerothCore log volume/directory configured by your
Compose project (by default `env/dist/logs` on the host), mounted into the
game containers exactly as before. The supervisor does not collect or rotate
them.

## Module compatibility

- **No core changes, no module changes.** The supervisor is external; the
  AzerothCore image and configuration are untouched.
- **Pause preserves in-memory state.** Instances, battlegrounds, auctions,
  AI state, scripts, and module state live in the process memory and survive
  the freeze. There is no restart, so there is no reload or reinitialization.
- **Timers see elapsed time.** On thaw, the world update receives a diff
  covering the frozen period. AzerothCore's event maps fire each due event
  once and reschedule; they do not replay every missed tick. In-game time
  jumps forward by the freeze duration. Cooldowns, respawns, and daily resets
  therefore behave as after a long server pause. The detailed analysis is in
  [`docs/audit.md`](docs/audit.md).
- **Database connections** can be reaped by MySQL during a very long freeze
  (`wait_timeout`, 8 hours by default). AzerothCore reconnects on the first
  query after the thaw; see [Known limits](#known-limits).
- **Modules with their own network listeners** are not covered by the wake
  proxy. Only 3724 and 8085 are proxied and counted. If a module exposes a
  separate port, a connection to that port will not wake a paused stack.
- **Playerbots:** upstream notes that after a thaw playerbots are sometimes
  not active. This fork does not diagnose or change playerbot behavior; treat
  it as an upstream caveat and verify on your server. A connected real client
  is unaffected.
- **External services** (a separate database, a dashboard, a Discord bot,
  etc.) are not paused. Only the configured game containers are.
- **Protected containers** cannot be frozen: the monitor refuses database-like
  names even if they appear in `SLEEP_TARGET_CONTAINERS`.

## Tests

There are three levels. They are complementary; none of them is a claim that
your production server has been validated.

### 1. Static Compose validation

```bash
cd <AC_DIR>
docker compose config
```

Check that `ac-sleep` publishes 3724/8085, that the game services publish
nothing, and that `ac-sleep` joins the expected network. This works without a
running daemon, but `SLEEP_BUILD_CONTEXT` must be set (otherwise the overlay
fails with a required-variable error).

### 2. Self-contained harness (`docker/test/`)

The harness needs Docker, bash with `/dev/tcp` support, and `jq` for T00. It
creates its own Compose project (`sleep-selftest`) with two mock services
instead of AzerothCore, so it does not touch the real stack, database, or
volumes:

```bash
cd /opt/azeroth-sleep
bash docker/test/run-tests.sh
```

What it exercises (see `docker/test/README.md` for the exact case list):

- T00: an offline merge of the real AzerothCore Compose project with the
  overlay (skipped if the project is not at `../azerothcore-wotlk`; set
  `AC_DIR=/path/to/azerothcore` to enable it);
- startup and status;
- a persistent client connection is counted, and the stack stays awake;
- disconnect, idle timeout, and freeze (`docker inspect` paused state);
- CPU of a busy mock before and after freeze, measured with `docker stats`;
- wake by a connection on the auth port and on the world port, including the
  bridge;
- several concurrent connections;
- a target container restart while the stack is awake (refreeze afterwards);
  supervisor restart while frozen (startup thaw); full project down/up;
- supervisor kill during a freeze (restart policy + automatic thaw);
- `socat` listener kill (supervisor respawn);
- protection against database-like target names;
- recovery from a manually created mixed paused/running state.

The harness uses host ports `13724` and `18085` to avoid colliding with a real
stack, and cleans up its project on exit. It prints `PASS`/`FAIL` per case and
exits non-zero on failure. It measures real values on your machine; this
README does not publish invented results.

Development notes:

- The harness is self-contained: `docker/test/test-compose.yml` builds the
  supervisor with `context: ..` (the `docker/` directory). T00 sets
  `SLEEP_BUILD_CONTEXT` only for its offline merge against the real
  AzerothCore project; the mock stack does not need it.
- To apply the overlay to a local AzerothCore checkout during development, set
  `SLEEP_BUILD_CONTEXT` to the **absolute** path of this repository's
  `docker/` directory in the AzerothCore `.env` (for example
  `/Users/<you>/git/wow/azeroth-sleep/docker`), alongside `COMPOSE_FILE`.
  Every Compose command that loads the overlay then works from the AzerothCore
  project directory, and the image is built from the correct context.
- CI builds both images directly with `docker build`, without the overlay.

### 3. Protocol end-to-end and real-client validation

- If your AzerothCore deployment includes the `e2e/` protocol harness, it can
  perform a protocol login, realm list, and world entry (`make e2e-smoke`).
  Run it against the proxy's auth port to prove the network path without a WoW
  client. It requires its own prerequisites (Go, database access, and
  `Warden.Enabled=0` in the test configuration).
- The real acceptance test is a WoW client: login, realm list, enter world,
  play, log out, wait for a freeze, reconnect, and later relog after hours.
  This is a checklist item in
  [`docs/deploy-production.md`](docs/deploy-production.md), with CPU
  measurements and an optional overnight soak.

CI (`.github/workflows/ci.yml`) runs ShellCheck, gitleaks, Hadolint, and builds
the supervisor and mock images. It does not run the harness or a live server.

## Known limits

- **Long freezes versus MySQL `wait_timeout`.** MySQL's default is 28800 s
  (8 h). The database is never paused, but the game containers' idle client
  connections can be closed during a long freeze. AzerothCore reconnects on
  the first query after thaw (up to five attempts) and aborts loudly if it
  cannot; this path is expected from the code but must be confirmed by the
  overnight soak on the real stack. A server that stays empty for more than
  8 hours is the case to watch.
- **Clock jump on thaw.** In-game time and monotonic time advance during the
  freeze. Due timers fire once on the first update after thaw. If
  `MaxCoreStuckTime` is enabled in `worldserver.conf`, its freeze detector is
  an additional risk to validate; AzerothCore's default is `0` (disabled).
  Freezes longer than about 49 days would overflow the millisecond diff and
  are not supported.
- **`docker stop` / `docker compose down` during a freeze.** A paused process
  cannot handle `SIGTERM` while it is frozen. Stopping a paused container may
  be refused by Docker ("container is paused"), may end in a forced kill
  after the stop timeout, or may internally resume it to deliver the signal,
  depending on the Docker version. None of these gives the worldserver a
  predictable chance to flush pending saves. Always wake first
  (`sleepctl wake`), including before any Compose command that recreates the
  game containers. The same applies to `docker attach` on a paused container:
  it can appear hung until the stack is woken.
- **Proxy failure during a session.** The bridge sockets live in `ac-sleep`.
  If that container dies, connected clients are disconnected and the host
  ports disappear until Docker restarts it (`restart: unless-stopped`). On
  restart the entrypoint attempts to thaw the stack before accepting
  connections. Players reconnect; the outage is bounded by the restart policy,
  not by the game server.
- **Unauthenticated connections keep the server awake.** Any established TCP
  connection on 3724/8085 counts as activity. This is deliberate: it is safer
  to waste CPU than to freeze a server someone is trying to reach. A port
  scanner with long-lived connections could prevent freezing.
- **Only the two game ports are proxied and counted.** SOAP is unpublished
  and not proxied. Module-specific ports are not wake paths. A direct
  connection to a paused backend port cannot succeed; the published ports
  must belong to `ac-sleep`.
- **Overlay ordering matters.** The sleep overlay must be last. A later
  override that republishes 3724/8085 can reintroduce direct ports and break
  the wake guarantee or fail to start.
- **Freeze is all-or-nothing per the target set.** If one target is missing,
  stopped, or crashing, the monitor stays awake (and logs an error) rather
  than freezing the others. Compose restart policies recover a crashed
  target; a manually stopped one stays down until you start it.
- **RAM is not freed.** Paused containers keep their memory. The saving is
  CPU, not memory; the database and the supervisor also stay resident.
- **No high availability.** This is a single-host solution. If the host is
  down, the server is down; `docker pause` does not survive a host reboot as
  a persistent state, and the supervisor attempts to thaw everything on
  startup.
- **Rootless Docker and Docker Desktop** need extra care with the socket path
  and permissions. The image runs as root inside its container to access the
  host socket; rootless mode may require `SLEEP_DOCKER_SOCKET` and matching
  permissions. Validate with `sleepctl status` before relying on it.
- **Upstream playerbots caveat.** After a thaw, playerbots may not be active;
  this is inherited from upstream and not modified here.

## Rollback

Rollback returns port ownership to the game containers and removes the
supervisor. It does not touch game data.

```bash
cd <AC_DIR>

# 1. Never stop or remove a paused stack directly.
/opt/azeroth-sleep/docker/sleepctl.sh wake

# 2. Remove the sleep overlay from COMPOSE_FILE in .env.
#    If COMPOSE_FILE was added only for this overlay, delete the line.
#    If it existed before, restore its previous value.
#    Remove SLEEP_BUILD_CONTEXT as well if it was added for this fork.

# 3. Recreate the stack without the overlay and remove ac-sleep.
docker compose up -d --remove-orphans
```

Verify:

```bash
docker compose ps
docker port ac-authserver
docker port ac-worldserver
```

Expected after rollback:

- `ac-authserver` publishes 3724 and `ac-worldserver` publishes 8085 (and SOAP
  7878 if your configuration publishes it);
- `ac-sleep` is gone (if it remains, `docker rm -f ac-sleep` after waking it);
- a real client can log in, see the realm list, and enter the world.

`--remove-orphans` removes containers that are not part of the current
Compose configuration. Review `docker compose ps --all` first if you run other
services in the same project. Do **not** use `docker compose down -v` as part
of a rollback: `-v` deletes named volumes, including the database.

If the rollback is urgent and `sleepctl` is unavailable:

```bash
docker unpause ac-worldserver ac-authserver
# then remove the overlay from COMPOSE_FILE and run the compose command above
```

## Uninstall and upgrades

### Upgrade the supervisor

```bash
sudo git -C /opt/azeroth-sleep pull
cd <AC_DIR>
docker compose build ac-sleep
docker compose up -d --force-recreate ac-sleep
```

`SLEEP_BUILD_CONTEXT` must still be set in `.env` for these Compose commands,
as for every command that loads the overlay. If you use a custom `SLEEP_IMAGE`,
rebuild and recreate with that tag. The game containers are not recreated by
this command, so players stay connected.

### Apply configuration changes

Edit `.env`, then:

```bash
cd <AC_DIR>
docker compose up -d --force-recreate ac-sleep
```

### Uninstall

1. Perform the [rollback](#rollback).
2. Remove the convenience symlink if you created it:
   `sudo rm -f /usr/local/bin/sleepctl`.
3. Optionally remove the image and the clone:

   ```bash
   sudo docker rmi azerothsleep/ac-sleep:latest   # or your SLEEP_IMAGE
   sudo rm -rf /opt/azeroth-sleep
   ```

4. Keep the edited `.env`; it contains your database password and your
   restored `COMPOSE_FILE`. Restore it from your backup if you want the exact
   pre-install content. If you added `SLEEP_BUILD_CONTEXT` for this fork,
   remove it as part of the rollback; it is unused once the overlay is gone.

## Security

Mounting the Docker socket into a container is a significant privilege. Read
this section before deploying on a shared host.

- **`/var/run/docker.sock` is equivalent to host root.** The Docker API can
  create a privileged container that mounts the host filesystem. Anything that
  can talk to the socket can take over the machine. `ac-sleep` needs the
  socket for `docker inspect`, `docker pause`, and `docker unpause`; it
  therefore runs as root in its container (the socket's group ID varies by
  host).
- **The trust boundary is the host.** Do not run `ac-sleep` on a host shared
  with untrusted users. Every account that can `docker exec` into the
  supervisor is effectively root on the host. Do not expose the Docker socket
  over TCP.
- **Hardening applied to the container:** read-only root filesystem with a
  `tmpfs` on `/tmp`, `cap_drop: ALL`, `no-new-privileges:true`, `init: true`,
  no published administrative port, no game volumes, no database credentials,
  and only the two game ports exposed. The image is small
  (`alpine:3.20` + `bash`, `socat`, `iproute2`, `docker-cli`).
- **No secrets in this repository or in the supervisor.** The AzerothCore
  `.env` stays in the AzerothCore project. Do not pass database passwords to
  `ac-sleep`; it does not need them. Keep `.env` readable only by the
  deployment user (`chmod 600`).
- **Image supply chain:** build from the Alpine 3.20 base tag, keep the host
  patched, and rebuild after Dockerfile changes. Review any fork before using
  its image.
- **A socket proxy is not a free win.** The common `docker-socket-proxy` with
  `CONTAINERS=1` still permits container create/exec/start, which is enough to
  obtain host root, so it does not reduce the effective privilege. A proxy
  restricted to `inspect`/`pause`/`unpause` would reduce the API surface but
  adds another component in the trust path; it is not part of this design.
- **Host systemd alternative:** if you do not want the socket in a container,
  run the monitor on the host and grant only `docker inspect`, `docker pause`,
  and `docker unpause` on the two named containers (for example through a
  narrow sudoers rule). This keeps the socket out of any container at the cost
  of a host-level installation. The upstream scripts are the starting point;
  they use `SIGSTOP` and are not Docker-aware as shipped.
- **Network exposure:** publish only 3724/8085. MySQL should stay on
  localhost or a private network. Use your firewall or Tailscale ACLs to limit
  who can reach the game ports.

The full security analysis, including why a containerized socket proxy does
not by itself reduce the root-equivalent privilege, is in
[`docs/audit.md`](docs/audit.md).

## Attribution

- Original project: [andymarden/azeroth-sleep](https://github.com/andymarden/azeroth-sleep),
  MIT, Copyright (c) 2025 andymarden. The design, the systemd scripts, the
  units, and the original documentation are his work. Upstream figures (37 %
  idle CPU, 0.09 % frozen, thaw under 200 ms on his LXC) are his measurements,
  not measurements made for this fork.
- Docker adaptation: Copyright (c) 2026 Phanty78, MIT. This fork adds the
  supervisor container, the Compose overlay, the self-contained test harness,
  the audit, and this documentation. The three upstream scripts
  (`azeroth-monitor`, `azeroth-proxy`, `azeroth-thaw`) and the four unit
  files are kept unchanged for the classic installation.
- Upstream issue #1 ("Docker") is the request this fork answers. Issue #2
  (`pgrep` failing with wrapper scripts) is the reason the Docker path targets
  container names rather than process command lines.

The full MIT license text is in [`LICENSE`](LICENSE).

## Classic install (systemd)

This section is the original, bare-metal/systemd documentation, kept for
compatibility. The Docker installation above is the recommended path for a
Compose deployment. The three upstream scripts and four unit files are shipped
unchanged in the repository root.

### Background

> I installed azerothcore on an LXC in Proxmox - 6 vcores, 8GB ram. Was
> surprised to find that, when no-one is connected, CPU is at 37% (ie over 2
> core for doing nothing). The authserver consumes 1 vcore and the worldserver
> 1.2 vcores (esp the authserver - what is it doing?). Seems rather
> unnecessary and don't really want the server to have to be manually started
> and stopped when anyone wants to play. All it really has to do is have a
> lightweight proxy listening for a connection and then start things up.
>
> So I built a solution - everything runs as systemctl with worldserver on port
> 8085 and authserver on port 372**5**.
>
> Then also under systemctl we have
>
> - A script **azeroth-monitor** to `kill -STOP` the auth and worldservers
>   when there has been no connection to the worldserver for 10 mins
> - A script **azeroth-proxy** that uses socat to listen on port 3724 and, when
>   it receives an auth request, calls **azeroth-thaw** which checks if the
>   servers are stopped, does `kill -CONT` if required to wake them up, and
>   then bridges the request to the real authserver on port 3725 using socat.
>
> Thawing of the frozen processes is near-instantaneous (under 200ms)
>
> Result is that, when no players are connected, it reduces from the previous
> idle of 37% to 0.09% which is better for my energy bills.
>
> If you do deploy this, let me know how you get on.
>
> I have one issue to resolve - I have the playerbots mod installed and it
> seems that, sometimes, when the server thaws, there are no playerbots
> active. That's probably just a config setting but need to chase that down.

These figures and observations are upstream's, made on an LXC host, and are
not reproduced by the Docker adaptation.

### Prerequisites

All installation is on the azerothcore server itself.

Upstream tested it with worldserver and authserver running under systemd,
although it should work regardless - although this solution is under systemd,
it assumes nothing about the two core services. If you do want to get them
under systemd, `worldserver.service` and `authserver.service` are included
(you would just need to adjust the paths).

```bash
sudo apt install net-tools socat
```

### Installation and configuration

To get started, clone the repo - upstream put the scripts under
`/home/azeroth/azeroth-local`.

You will need to modify some variables and paths in the scripts, since upstream
had not spent too much time parameterising them or using env files (yet).
They should be self-explanatory:

- **azeroth-monitor**: the first 7 variables - how to identify everything in
  your installation, how often you want to check and how long you want to
  leave the servers idle before freezing.
- **azeroth-proxy**: the first 4 variables - ports, IP address and script
  path.
- **azeroth-thaw**: just 1 - the path of the azerothcore binaries.
- **azeroth-monitor.service**: `ExecStart` is the full path to the
  `azeroth-monitor` script.
- **azeroth-proxy.service**: `ExecStart` is the full path to the
  `azeroth-proxy` script.

Now copy the two service files to the systemd unit directory and enable them:

```bash
# The upstream README says /etc/systemd/services; modern systemd uses:
sudo cp azeroth-monitor.service azeroth-proxy.service /etc/systemd/system/
sudo systemctl enable azeroth-monitor
sudo systemctl enable azeroth-proxy
sudo systemctl start azeroth-monitor
sudo systemctl start azeroth-proxy
```

The classic installation puts the real authserver on port **3725** and the
proxy on **3724**, because the proxy and the authserver share the host network
namespace. Do not mix these scripts with the Docker installation: the Docker
supervisor keeps the internal ports at 3724/8085 and bridges by container
name.

### Testing

To test:

1. Check that you can login as a player.
2. Logout.
3. Check CPU usage.
4. Wait 5 mins (or whatever you have set the idle time to in the
   `azeroth-monitor` script).
5. Check that the CPU usage is massively reduced (you can also check the
   authserver and worldserver processes, which should be in a frozen state).
6. Check that you can log back in again and the server processes are instantly
   thawed.

Enjoy! Let upstream know how you get on.
