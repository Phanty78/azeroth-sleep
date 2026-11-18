# Production deployment runbook

This runbook installs the Docker adaptation of `azeroth-sleep` on an existing
AzerothCore WotLK Docker Compose server and validates it with a real WoW
client. It is written for a small private server, with the reference target
being an Ubuntu 24.04 host on a Mac mini Late 2012 reached over SSH and
Tailscale. The procedure is generic: adapt paths, addresses, and the Compose
project name to your installation.

This document contains **no measured results**. Every CPU figure, wake
latency, and client observation is to be recorded by the operator during the
procedure. Upstream figures (37 % idle CPU, 0.09 % frozen, thaw under 200 ms)
belong to the original project and are not reproduced here.

What this runbook does not do:

- it does not install AzerothCore, Docker, or a WoW client;
- it does not migrate or edit game data;
- it does not validate playerbots, custom modules, or third-party services;
- it does not replace reading [`audit.md`](audit.md) and the
  [README](../README.md).

## 0. Safety rules

Read these before touching the production host.

1. **Always wake a frozen stack before stopping, restarting, recreating, or
   attaching to it.**

   ```bash
   /opt/azeroth-sleep/docker/sleepctl.sh wake
   ```

   A paused process cannot handle `SIGTERM` while it is frozen. Depending on
   the Docker version, `docker stop`, `docker compose down`, `docker compose
   restart`, or a Compose recreate may be refused with "container is paused",
   may force-kill after the stop timeout, or may internally resume the
   container to deliver the signal. None of these gives the worldserver a
   predictable chance to flush pending saves. `docker attach` to a paused
   container can also appear hung. Wake first, verify with `sleepctl status`,
   then proceed.

2. **Never use `docker compose down -v`.** `-v` deletes named volumes,
   including the database. Rollback uses `up -d --remove-orphans`, not `down`.

3. **Never write database passwords into shell history, tickets, or logs.**
   The AzerothCore `.env` stays on the host and remains readable only by the
   deployment user. Commands below read secrets from the container
   environment or from files, never from a literal on the command line.

4. **Keep a second access path.** SSH over Tailscale is convenient; keep LAN
   SSH or physical console access in case Tailscale or the network fails
   during the change.

5. **Do the change in a maintenance window with no players connected.** The
   first `docker compose up -d` recreates `ac-authserver` and `ac-worldserver`
   to hand their published ports to `ac-sleep`.

## 1. Pre-flight (before the window)

### 1.1 Inventory

Record the following on the production host:

```bash
uname -a
cat /etc/os-release
docker version
docker compose version
docker info --format '{{.CgroupVersion}} {{.Driver}}'
df -h /var/lib/docker
free -h
```

Requirements:

- Docker Compose with support for the `!override` YAML tag (v2.24.4 or newer;
  the reference host runs a recent Compose v5 release).
- The AzerothCore stack is healthy: `ac-database`, `ac-worldserver`, and
  `ac-authserver` running, worldserver ready, players can log in before the
  change.
- Fixed container names `ac-worldserver` and `ac-authserver`, and the
  `ac-network` Compose network (AzerothCore defaults).
- Free disk space for one more small image (the supervisor is Alpine-based).
- The host does not suspend, hibernate, or power off on idle (see section 9).

### 1.2 Stage the fork and image

Clone the fork on the production host (or copy a reviewed checkout):

```bash
sudo git clone https://github.com/Phanty78/azeroth-sleep.git /opt/azeroth-sleep
sudo docker build -t azerothsleep/ac-sleep:latest /opt/azeroth-sleep/docker
```

If you use a custom `SLEEP_IMAGE`, build that tag instead. Record the image
ID:

```bash
docker image inspect azerothsleep/ac-sleep:latest --format '{{.Id}} {{.Created}}'
```

Optional but recommended: run the self-contained harness on a development
host (or on the production host before the window). It uses its own Compose
project and host ports 13724/18085, and does not touch the real stack:

```bash
cd /opt/azeroth-sleep
# Optional: point T00 at the production Compose project.
AC_DIR=<AC_DIR> bash docker/test/run-tests.sh
```

Do not publish or invent its results; keep the console output with the change
record.

### 1.3 Backups

Back up the Compose `.env` (contains the database password) and the database:

```bash
cd <AC_DIR>
install -m 600 .env ".env.backup-$(date +%Y%m%d-%H%M%S)"

ts=$(date +%Y%m%d-%H%M%S)
docker compose exec -T ac-database sh -c \
  'MYSQL_PWD="$MYSQL_ROOT_PASSWORD" exec mysqldump --single-transaction --all-databases -uroot' \
  > "backup-${ts}.sql"
tail -2 "backup-${ts}.sql"
ls -lh "backup-${ts}.sql"
```

The dump must end with `-- Dump completed` (or the equivalent success line).
If it does not, stop: fix the backup before changing the deployment.

Also record the current Compose configuration:

```bash
docker compose config > "compose-before-${ts}.yml"
chmod 600 "compose-before-${ts}.yml"
```

Review it for secrets; keep it on the host, not in a ticket.

### 1.4 Announce the window

Tell players the server will disconnect briefly. Empty the server before
proceeding. If the stack is already behind an `ac-sleep` installation, use its
own network namespace (the authoritative view) and wake it first if needed:

```bash
docker exec ac-sleep monitor.sh status
docker exec ac-sleep ss -Htn state established '( sport = :8085 or sport = :3724 )' | wc -l
```

Before the first installation there is no `ac-sleep`; use your usual player
check (worldserver console, dashboard, or SOAP if enabled). A count of `0` is
the expected result. Do not use a host-side `ss` filter as the only proof:
with Docker's NAT rules, the host may not see the game connection with the
expected source port. Investigate anything unexpected before proceeding.

## 2. Baseline measurements

Do this with the stack running normally, no players connected, before adding
the overlay. Wait a few minutes after the last disconnect so periodic work
settles.

```bash
docker stats --no-stream ac-worldserver ac-authserver
pidstat -u 5 3
```

`pidstat` comes from `sysstat` (`sudo apt install sysstat`). If it is not
available, use `top -b -n 1` and record the per-process CPU column.

Record the values in section 6. Also record:

```bash
date -u +%Y-%m-%dT%H:%M:%SZ
uptime
docker compose ps
```

## 3. Maintenance window procedure

### 3.1 Apply the overlay

Edit `<AC_DIR>/.env` and add both settings:

```dotenv
SLEEP_BUILD_CONTEXT=/opt/azeroth-sleep/docker
COMPOSE_FILE=docker-compose.yml:docker-compose.override.yml:/opt/azeroth-sleep/docker/docker-compose.sleep.yml
```

`SLEEP_BUILD_CONTEXT` is required and has no default. It must be the
**absolute** path to the fork's `docker/` directory. Compose resolves a
relative build context against the base Compose file (the AzerothCore project
directory), so without this variable the supervisor would be built from the
wrong directory. The overlay fails loudly if it is unset; the variable is
required for every Compose command that loads the overlay, including
`docker compose config` and a prebuilt-image flow.

For `COMPOSE_FILE`, append the overlay last instead of defining the variable
twice if it already exists. Omit `docker-compose.override.yml` if it does not
exist. Use an absolute path for the overlay.

Validate the merge **before** recreating anything:

```bash
cd <AC_DIR>
docker compose config >/dev/null
```

Check in the rendered configuration:

```bash
docker compose config | sed -n '/ac-authserver:/,/ac-sleep:/p' | grep -A3 'ports'
```

Expected: `ac-authserver` and `ac-worldserver` have no published ports;
`ac-sleep` maps 3724 and 8085 on the host.

### 3.2 Start

```bash
cd <AC_DIR>
docker compose up -d
```

Compose builds the supervisor image if it is not present (from the absolute
`SLEEP_BUILD_CONTEXT`), recreates `ac-authserver` and `ac-worldserver` without
published ports, and starts `ac-sleep`. If you prebuilt the image during
pre-flight, it is reused. To force a rebuild after changing the Dockerfile:

```bash
docker compose up -d --build ac-sleep
```

Expected: a short disconnect, the game containers recreated without published
ports, and `ac-sleep` running. This is the only planned outage of the change.

### 3.3 Verify the supervisor

```bash
docker compose ps
docker exec ac-sleep monitor.sh status
```

Expected status:

- both targets `running` (not paused);
- `client connections: 0` (unless your check opened one);
- `listeners: :3724 ok, :8085 ok`;
- `mode: freeze enabled`;
- exit code 0.

If the status reports `docker daemon unreachable`, check the socket mount,
the container name, and permissions before continuing.

### 3.4 Verify the network path from the host

```bash
nc -vz 127.0.0.1 3724
nc -vz 127.0.0.1 8085
```

These open short TCP connections through `ac-sleep`; they also wake the stack
and count as activity. That is expected. The real client test in section 4 is
authoritative.

If the worldserver was recreated after the authserver and the realm appears
offline to clients, restart the worldserver once (make sure the stack is not
frozen first):

```bash
docker exec ac-sleep monitor.sh status
sleepctl wake
docker compose restart ac-worldserver
```

## 4. Validation with a real WoW client

Perform this from a client machine on the tailnet (or the same LAN), with the
real WoW client installed. The sleep layer does not change the client
configuration.

### 4.1 Network prerequisites

On the client:

```bash
tailscale status
tailscale ping <production-host>
nc -vz <production-host> 3724
nc -vz <production-host> 8085
```

On Windows, use `Test-NetConnection <production-host> -Port 3724` (and 8085).

The AzerothCore realmlist must point clients at an address they can reach.
The sleep overlay does not rewrite `acore_auth.realmlist`:

```sql
SELECT id, name, address, localAddress, port, flag FROM acore_auth.realmlist;
```

`address` must be the Tailscale IP or DNS name (or the public/LAN address)
that clients use, not `127.0.0.1`. The `port` column is the world port clients
are told to use (8085 by default). Set the client's `realmlist.wtf` to the
same address; it carries the auth host, while the world address/port come from
this database row. A stock 3.3.5 client connects to the auth port 3724, so
keep `DOCKER_AUTH_EXTERNAL_PORT=3724` (or provide a client-side forward).

### 4.2 Log in and enter the world

Record each observation:

- [ ] Client login reaches the realm list.
- [ ] The realm is shown as up (not "offline").
- [ ] Selecting the realm reaches the character list.
- [ ] Entering the world completes; the character is visible and controllable.
- [ ] No disconnect occurs while playing for a few minutes.
- [ ] Logout is clean.

If login or world entry fails, stop and diagnose before testing the freeze.
Check `docker compose logs --tail 100 ac-authserver ac-worldserver`, the
AzerothCore logs in your configured log directory (by default
`env/dist/logs`), and `docker exec ac-sleep monitor.sh status`. Do not
attribute a pre-existing AzerothCore problem to the sleep layer.

### 4.3 First freeze

With no clients connected, wait for `SLEEP_IDLE_TIMEOUT` (default 600 s) plus
one or two monitor intervals. If you want a faster first test, temporarily
lower `SLEEP_IDLE_TIMEOUT` to 120, recreate the supervisor, and restore it
after validation:

```dotenv
SLEEP_IDLE_TIMEOUT=120
```

```bash
cd <AC_DIR>
docker compose up -d --force-recreate ac-sleep
```

For the default configuration, just wait.

Verify:

```bash
docker inspect -f '{{.Name}} paused={{.State.Paused}}' ac-worldserver ac-authserver
docker exec ac-sleep monitor.sh status
docker logs --tail 20 ac-sleep
```

Expected:

- both targets show `paused=true`;
- logs contain `[FREEZE] ... paused (idle ...s)`;
- `status` shows `client connections: 0` and both listeners `ok`;
- `docker stats --no-stream ac-worldserver ac-authserver` shows the containers
  still resident but consuming no CPU (record exactly what it shows; paused
  containers commonly display `0.00%`, but Docker versions differ).

Record the timestamp, the idle value from the log, and the CPU values.

### 4.4 Wake by client connection

With the stack frozen, log in from the client:

- [ ] The client connects and the realm list appears.
- [ ] The character list and world entry work.
- [ ] `docker logs ac-sleep` shows `[CONN] new connection, waking stack` and
      `[THAW] ... unpaused` (and/or `[THAW] reason=activity`).
- [ ] Wake latency is measured and recorded: compare the `[CONN]` and
      `[THAW]` timestamps, and record the client-perceived time from pressing
      "Log in" to the realm list.

The upstream project reports a thaw under 200 ms; this is an upstream figure.
Measure your own.

If you lowered `SLEEP_IDLE_TIMEOUT` for this test, restore the production value
(for example 600) in `.env` and recreate `ac-sleep` once the freeze/wake test
is complete.

### 4.5 Relog after several hours

Leave the server empty until it freezes again, then wait at least a few hours
(next day is ideal) and repeat the login:

- [ ] Realm list appears without manual intervention.
- [ ] Entering the world works.
- [ ] No new errors in `docker logs ac-sleep` or the game logs.
- [ ] If the freeze exceeded 8 hours, check for MySQL reconnect messages
      (see section 5).

Record the freeze duration, the observed wake behavior, and any client
warnings.

### 4.6 Concurrency (optional)

If you expect multiple players:

- [ ] Two clients log in and enter the world while the stack is awake.
- [ ] The monitor does not freeze while at least one connection is present.
- [ ] One logout does not freeze the stack while the other client remains
      connected.
- [ ] Both clients relog after a freeze.

## 5. Overnight soak (recommended)

The soak validates the two risks that cannot be proven by a short login:
a long freeze (including MySQL `wait_timeout`, 8 hours by default) and a
morning relog.

Prerequisites: an empty server, no scheduled restarts, no automatic players,
and a maintenance window long enough to leave the stack alone overnight.

1. Set a short idle timeout temporarily:

   ```dotenv
   SLEEP_IDLE_TIMEOUT=60
   ```

   in `<AC_DIR>/.env`, then:

   ```bash
   cd <AC_DIR>
   docker compose up -d --force-recreate ac-sleep
   ```

2. Confirm there are no connections, wait for the freeze, and verify:

   ```bash
   docker exec ac-sleep ss -Htn state established '( sport = :8085 or sport = :3724 )' | wc -l
   docker inspect -f '{{.Name}} paused={{.State.Paused}}' ac-worldserver ac-authserver
   docker exec ac-sleep monitor.sh status
   date -u +%Y-%m-%dT%H:%M:%SZ
   ```

   Record the freeze timestamp. The stack must stay frozen overnight.

3. Leave it for at least 8 hours (longer than `wait_timeout`) if you want to
   exercise the database reconnect path. Do not connect a client during the
   soak; one connection wakes the stack and resets the test.

4. In the morning, verify it is still frozen, then connect with the real
   client:

   - [ ] Still frozen before the connection.
   - [ ] Realm list appears.
   - [ ] Enter world works.
   - [ ] Record wake latency.
   - [ ] Check the supervisor log for `[CONN]`, `[THAW]`, and any `[ERROR]`.
   - [ ] Check the worldserver log for `Lost the connection to the MySQL
         server`, `Attempting to reconnect`, `Successfully reconnected`, and
         fatal/abort messages. Record the exact lines.
   - [ ] Check `docker compose ps`: no unexpected restarts.

5. Restore the production timeout:

   ```dotenv
   SLEEP_IDLE_TIMEOUT=600
   ```

   ```bash
   cd <AC_DIR>
   docker compose up -d --force-recreate ac-sleep
   docker exec ac-sleep monitor.sh status
   ```

If the morning login fails, wake the stack manually, collect the logs, and
follow section 7 (rollback). Do not change database settings to "fix" a
reconnect failure without diagnosing it first.

## 6. CPU measurement worksheet

Fill this in with observed values. Do not copy values from documentation.

Commands:

```bash
docker stats --no-stream ac-worldserver ac-authserver ac-sleep
pidstat -u 5 3
top -b -n 1 | head -20
```

Take measurements at three points, each with no players connected and after
a few minutes of settling:

| Phase | When | `ac-worldserver` CPU | `ac-authserver` CPU | `ac-sleep` CPU | Host idle |
| --- | --- | --- | --- | --- | --- |
| Baseline | before the overlay, stack awake | | | n/a | |
| Installed, awake | after `up -d`, before first freeze | | | | |
| Frozen | after `[FREEZE]`, targets paused | | | | |

Notes:

- `docker stats` reports CPU as a percentage of one host core; a value above
  100 % is possible on a multi-core host.
- Paused containers keep their memory; the saving is CPU, not RAM.
- `ac-sleep` has a small constant cost (socat listeners, one monitor
  iteration per `SLEEP_CHECK_INTERVAL`); record it rather than assuming zero.
- If the baseline and "frozen" values are close, check that the containers
  are actually paused before concluding anything.
- If the idle timeout would freeze the stack in the middle of the "installed,
  awake" sample, take the sample quickly or temporarily raise
  `SLEEP_IDLE_TIMEOUT` and restore it afterwards.

Also record wake latency samples:

| Test | Freeze duration | `[CONN]` to `[THAW]` | Client login to realm list | Notes |
| --- | --- | --- | --- | --- |
| First wake | | | | |
| Wake after hours | | | | |
| Overnight wake | | | | |

## 7. Rollback

Rollback is exact and does not touch game data. It may be executed at any
time during the change if validation fails.

```bash
cd <AC_DIR>

# 1. Wake first. Never stop or remove a paused stack.
/opt/azeroth-sleep/docker/sleepctl.sh wake
# If the container is unavailable:
# docker unpause ac-worldserver ac-authserver

# 2. Remove the sleep overlay from COMPOSE_FILE in .env.
#    If COMPOSE_FILE was added only for this overlay, delete the line.
#    If it existed before, restore the exact previous value (see the backup).
#    Also remove SLEEP_BUILD_CONTEXT if it was added for this fork.

# 3. Confirm the merge no longer contains ac-sleep.
docker compose config >/dev/null

# 4. Recreate the original port publication and remove the orphan.
docker compose up -d --remove-orphans
```

Verify:

```bash
docker compose ps
docker port ac-authserver
docker port ac-worldserver
docker inspect -f '{{.Name}} paused={{.State.Paused}}' ac-worldserver ac-authserver 2>/dev/null || true
```

Expected:

- `ac-authserver` publishes 3724 and `ac-worldserver` publishes 8085 (and
  SOAP 7878 if your original configuration published it);
- `ac-sleep` is absent; if it remains, wake it and `docker rm -f ac-sleep`;
- both game containers are running, not paused;
- a real client can log in and enter the world.

If a port is still held by a leftover container:

```bash
docker ps --format '{{.Names}}\t{{.Ports}}' | grep -E '3724|8085'
docker unpause ac-worldserver ac-authserver 2>/dev/null || true
docker rm -f ac-sleep 2>/dev/null || true
cd <AC_DIR>
docker compose up -d --force-recreate ac-authserver ac-worldserver
```

Do not use `docker compose down -v` to clear a port conflict. That destroys
the database volume.

After rollback, keep the backup SQL, the previous `.env`, the supervisor logs
(`docker logs ac-sleep > sleep-rollback.log` before removing it if possible),
and the exact failing step in the change record.

## 8. Abort criteria and escalation

Roll back and stop the validation if any of the following persists after one
diagnostic attempt:

- the authserver or worldserver crash-loops after a thaw;
- the worldserver aborts or logs a fatal database/reconnect failure, or MySQL
  becomes unhealthy;
- the realm list is empty/offline or entering the world fails for a valid
  client, with no pre-existing cause;
- `ac-sleep` reports repeated `[ERROR]` or `[SUPERVISOR]` respawns and does
  not converge;
- the stack never freezes despite zero connections and a valid timeout (check
  `SLEEP_IDLE_TIMEOUT=0` and Docker errors first);
- the host shows signs of memory pressure, disk exhaustion, or unstable
  Docker after the change;
- ports cannot be handed to `ac-sleep` or returned to the game containers.

For any abort: wake the stack, capture logs, roll back, and report the
observations. Do not improvise schema changes, timeouts, or container
restarts to "make it pass".

## 9. Mac mini Late 2012 / Ubuntu 24.04 notes

These are environment notes, not additional features of the sleep layer.

### Docker installation

Use Docker Engine from Docker's official apt repository, with the Compose
plugin. Snap-packaged Docker has confinement and socket-path quirks that make
this kind of supervisor harder to operate. Verify:

```bash
docker compose version
docker info --format '{{.CgroupVersion}}'
```

The cgroup freezer used by `docker pause` works on the default Ubuntu 24.04
cgroup v2 setup. No kernel tuning is required for pause/unpause.

### Prevent the host from sleeping

A suspended host cannot proxy connections. Disable sleep and hibernation:

```bash
sudo systemctl mask sleep.target suspend.target hibernate.target hybrid-sleep.target
systemctl status sleep.target
```

The status should show the unit masked. Keep the Mac mini ventilated and on a
stable power source; a laptop-style "lid close" policy does not apply to a
Mac mini, but a UPS is still useful.

### Tailscale and SSH

- Install Tailscale from its official package repository; `tailscale up
  --ssh` if you use Tailscale SSH.
- Confirm the host is reachable from the client: `tailscale ping <host>` and
  a login from the client.
- Restrict who can reach 3724/8085 with Tailscale ACLs. The game ports do not
  need to be exposed to the public internet for a private server.
- Keep LAN SSH or physical access as a fallback. If a firewall change locks
  you out, Tailscale may not save you.

### Firewall

If `ufw` is enabled, allow only what you need. For a tailnet-only server:

```bash
sudo ufw allow in on tailscale0 to any port 3724 proto tcp
sudo ufw allow in on tailscale0 to any port 8085 proto tcp
sudo ufw status verbose
```

Do not expose MySQL. Keep SSH access restricted.

Adjust the interface name if your Tailscale interface is not `tailscale0`.

### Time, updates, and disk

- Enable NTP: `sudo timedatectl set-ntp true`; verify with `timedatectl`.
  The sleep layer uses epoch seconds for its idle timer and does not depend on
  the game server's internal clock, but a correct host clock keeps logs
  comparable.
- Configure Docker log rotation (`/etc/docker/daemon.json`, `log-opts` with
  `max-size` and `max-file`). Without it, long-running worldserver logs can
  fill the disk. Applying this restarts Docker: wake the stack first, and
  schedule it outside the validation window.
- Monitor `df -h /var/lib/docker` and `docker system df`. AzerothCore images
  and logs grow over time.
- Unattended upgrades can restart Docker. With `restart: unless-stopped`,
  containers return and `ac-sleep` thaws the stack on startup, but schedule
  upgrades outside player hours and re-run the section 4 checks afterwards.

### Resource notes

- The Late 2012 Mac mini is an x86_64 machine: use the amd64 Ubuntu 24.04
  image and the amd64 Docker packages. Confirm with `uname -m` (`x86_64`).
- Paused containers retain their RAM. The Mac mini must have enough memory
  for MySQL, worldserver, authserver, and the supervisor simultaneously; the
  sleep layer does not reduce memory usage.
- The CPU saving is largest when the server is idle. Measure it (section 6)
  instead of assuming a figure.
- Check temperatures and fan behavior after the change; a quieter, cooler
  host is expected when the game processes are paused, but this is an
  observation to record, not a guarantee.

## 10. Post-deployment monitoring

For the first 24-72 hours:

```bash
docker logs --since 24h ac-sleep | grep -E '\[(FREEZE|THAW|RECONCILE|SUPERVISOR|ERROR)\]'
docker compose ps
docker stats --no-stream ac-worldserver ac-authserver ac-sleep
```

- Confirm freeze/thaw cycles happen as expected for the player pattern.
- Check that no `[ERROR]` or repeated `[SUPERVISOR]` lines appear.
- Ask players whether login and world entry feel normal, and record wake
  latency reports.
- If the overnight soak was skipped, schedule it before declaring the
  deployment fully validated; the MySQL reconnect path after >8 h is the
  main unproven assumption.
- Keep the rollback commands and the `.env` backup until the deployment has
  survived a full week and at least one long idle period.

## 11. Quick reference

| Task | Command |
| --- | --- |
| Status | `/opt/azeroth-sleep/docker/sleepctl.sh status` |
| Wake | `/opt/azeroth-sleep/docker/sleepctl.sh wake` |
| Force freeze (empty server) | `/opt/azeroth-sleep/docker/sleepctl.sh freeze` |
| Logs | `docker logs --tail 100 ac-sleep` |
| Follow logs | `docker logs -f ac-sleep` |
| Validate merge | `cd <AC_DIR> && docker compose config` |
| Apply/refresh | `cd <AC_DIR> && docker compose up -d --force-recreate ac-sleep` |
| Rebuild image | `cd <AC_DIR> && docker compose build ac-sleep` (or `docker build -t azerothsleep/ac-sleep:latest /opt/azeroth-sleep/docker`) |
| Rollback | wake, remove overlay + `SLEEP_BUILD_CONTEXT` from `.env`, `docker compose up -d --remove-orphans` |
| Paused state | `docker inspect -f '{{.Name}} {{.State.Paused}}' ac-worldserver ac-authserver` |
