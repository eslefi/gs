# eslefi/gs

Coolify-managed LinuxGSM servers for:

- Minecraft Java Edition
- Project Zomboid
- Valheim
- 7 Days to Die

The stack uses host networking because the servers expose several TCP and UDP ports and are accessed directly through the host IP. Coolify's HTTP reverse proxy is not involved in game traffic.

## Deployment

Create a Coolify application from this repository and select **Docker Compose** with:

```text
docker-compose.yaml
```

Copy `.env.example` values to Coolify's environment variables and adjust the resource limits for the host.

The Compose services have stable labels used by `manage.sh`. This lets the script locate containers even though Coolify generates deployment-specific container names.

## Configuration

Settings live in `.env` (gitignored; copy from `.env.example`) and fall into
three tiers. **Which tier a value belongs to decides whether it does anything.**

| Tier | What | Delivered by | Settable in Coolify |
| --- | --- | --- | --- |
| 1 | Container shape — `TZ`, `*_MEMORY_LIMIT`, `*_CPU_LIMIT` | `docker compose` | yes |
| 2 | `UPDATE_CHECK`, `VALIDATE_ON_START`, `UID`/`GID`, `LGSM_*` | container environment | yes |
| 3 | Every game and LinuxGSM setting | `./manage.sh apply-config` | yes |

Tier 2 is the **complete** set of variables the LinuxGSM images read — verified
against `/app/entrypoint.sh` and `/app/entrypoint-user.sh`. A game setting can
therefore never take effect just by being present in the environment: putting
`max-players` in Compose's `environment:` would create a variable the server
never reads. `apply-config` writes Tier 3 into the config files instead:

```bash
./manage.sh apply-config all
./manage.sh restart all
```

Because Tier 2 variables are declared in Compose, **our default wins whenever
one is unset** — so each default is pinned to the image's own default. Leaving
`GS_UPDATE_CHECK` blank, for instance, would override the image's `60` and
silently disable update checks.

### Where Tier 3 values come from

`apply-config` reads the **container's environment first** and falls back to the
host `.env`. Both work, and a value set in Coolify beats a stale local one:

```text
Coolify env var  ─┐
                  ├─►  apply-config  ─►  server.properties / *.ini / *.xml / LinuxGSM cfg
host .env        ─┘    (container env wins)
```

Setting them in Coolify keeps a single source of truth and works on hosts with
no `.env` at all. The container environment is only a transport here — LinuxGSM
still ignores these variables; `apply-config` is what turns them into config.

`apply-config` is idempotent. It rewrites only the block it owns in each
LinuxGSM config, so anything you added by hand outside the markers is kept.

### Naming convention

Any setting the game supports is reachable, whether or not `.env.example`
lists it:

| Prefix | Target |
| --- | --- |
| `<SERVICE>_LGSM_<key>` | LinuxGSM `/data/config-lgsm/<script>/<script>.cfg` |
| `MINECRAFT_PROP_<key>` | Minecraft `server.properties` |
| `PROJECT_ZOMBOID_INI_<Key>` | Project Zomboid `/data/Zomboid/Server/pzserver.ini` |
| `SEVEN_DAYS_TO_DIE_XML_<Property>` | 7 Days to Die `sdtdserver.xml` |

`<SERVICE>` is `MINECRAFT`, `PROJECT_ZOMBOID`, `VALHEIM`, or
`SEVEN_DAYS_TO_DIE`. Valheim has no game config file — all of its settings are
LinuxGSM start parameters.

Key names are used verbatim except for `MINECRAFT_PROP_`, because
`server.properties` uses characters that are illegal in shell variable names:
`_` becomes `-`, and a leading `query_`/`rcon_` becomes `query.`/`rcon.`.

```text
MINECRAFT_PROP_max_players=20      ->  max-players=20
MINECRAFT_PROP_query_port=25565    ->  query.port=25565
```

Values may be unquoted, single-quoted, or double-quoted; unquoted values keep
their spaces and lose a trailing ` # comment`. `.env` is parsed rather than
sourced, so Compose's quoting rules and this script's agree.

### Required credentials

Project Zomboid and Valheim will not start without these. Set them **before**
first deployment, or the servers sit in a restart loop that reports as healthy:

| Server | `.env` variable | Constraint |
| --- | --- | --- |
| Project Zomboid | `PROJECT_ZOMBOID_LGSM_ADMINPASSWORD` | without it the server blocks forever on an interactive prompt and never binds its ports |
| Valheim | `VALHEIM_LGSM_SERVERPASSWORD` | minimum 5 characters, must differ from the server name |

Keep `PROJECT_ZOMBOID_LGSM_STARTPARAMETERS` in sync with the admin password —
passing `-adminpassword` is what stops the first-start prompt from appearing.

```bash
./manage.sh apply-config all
./manage.sh restart all
```

Verify the servers actually came up, which is the check that catches this class
of failure:

```bash
./manage.sh doctor
```

## Sizing

Limits are sized for **15 concurrent players** per server — except Valheim,
which vanilla hard-caps at 10 (see below).

`*_MEMORY_LIMIT` is the *container* limit. For the two Java servers it is **not**
the setting that bounds the game's memory — raising it alone does nothing. The
container limit must always exceed the game's heap, never equal it.

| Server | Players | Container limit | Game memory setting | Player cap setting | Documented basis |
| --- | --- | --- | --- | --- | --- |
| Minecraft | 15 | `MINECRAFT_MEMORY_LIMIT` (9g) | `javaram=7168` in `/data/config-lgsm/mcserver/mcserver.cfg` | `max-players` in `server.properties` | 4–8 GB heap |
| Project Zomboid | 15 | `PROJECT_ZOMBOID_MEMORY_LIMIT` (15g) | `-Xmx12g` in `/data/serverfiles/ProjectZomboid64.json` | `MaxPlayers` in the server `.ini` | ~6 GB base + 0.5 GB/player |
| Valheim | **10** | `VALHEIM_MEMORY_LIMIT` (5g) | none (native binary) | **not configurable** | 2 GB official min, 4–6 GB practical |
| 7 Days to Die | 15 | `SEVEN_DAYS_TO_DIE_MEMORY_LIMIT` (17g) | none (native binary) | `ServerMaxPlayerCount` in `sdtdserver.xml` | 8 GB + 0.5–1 GB/player |

The limits total **46 GiB** and are sized to fit the host even in the worst
case. Measured budget: 62.6 GiB total, minus 4.4 GiB used by the 25 other
(unlimited) containers on this host, minus kernel and slab — so all four game
servers can sit at their ceiling simultaneously with roughly 10 GiB still spare.

For the two Java servers the container limit must clear `-Xmx` with room for
non-heap memory: Minecraft 7 GB heap in 9g, Project Zomboid 12 GB heap in 15g.
Both heaps sit at the lower end of the documented 15-player range, which is the
trade-off for fitting the host — if you see GC pauses or tick lag with a full
server, raise the heap and the container limit together, never one alone.

LinuxGSM ships Minecraft with `javaram="1024"`, i.e. a 1 GB heap. That default
must be overridden or the server will exhaust its heap well before the container
limit matters.

### Two capability limits

**Valheim cannot exceed 10 players.** Vanilla hard-caps it; there is no server
setting and no `-maxplayers` argument in the binary. Raising it requires a mod
(ValheimPlus or MaxPlayerCount) installed on the server **and on every
connecting client**.

**Minecraft has no join password.** `server.properties` offers only
`white-list`, `online-mode` and `rcon.password` — the last being remote admin
console access, not a join gate. To restrict who can connect, use the whitelist:

```bash
MINECRAFT_PROP_white_list=true
MINECRAFT_PROP_enforce_whitelist=true
```

then add accounts with `./manage.sh exec minecraft ./mcserver console` and
`whitelist add <name>`.

CPU limits total 11 on an 8-core host. This is a deliberate mild overcommit —
these games are single-thread bound and are not expected to peak simultaneously.
Reduce each to 2 for a strict fit.

## Firewall

Open at least the following default ports on the host and any upstream firewall:

| Server | Ports |
| --- | --- |
| Minecraft | `25565/tcp`, `25565/udp` (query; `enable-query=true`) |
| Project Zomboid | `16261/udp`, player ports beginning at `16262/udp` |
| Valheim | `2456-2458/udp` |
| 7 Days to Die | `26900/tcp`, `26900-26903/udp`, `11000/udp` (Steam networking) |

Omitting Minecraft's UDP port makes the server invisible to the multiplayer
server list even though direct connections still work.

Verify the effective ports after installation:

```bash
./manage.sh details minecraft
./manage.sh details project-zomboid
./manage.sh details valheim
./manage.sh details seven-days-to-die
```

## Management

Run `manage.sh` on the Docker host. The user needs access to the Docker daemon.

```bash
./manage.sh list
./manage.sh status all
./manage.sh restart valheim
./manage.sh update all
./manage.sh backup all
./manage.sh logs minecraft --follow
./manage.sh console project-zomboid
./manage.sh doctor
```

Running the script without arguments opens an interactive menu:

```bash
./manage.sh
```

`list` and `doctor` report whether the **game process** is alive, not just the
container. A container can sit `running` for hours around a dead or
crash-looping server. `doctor` also warns when a service has accumulated many
LinuxGSM start attempts, which is the visible trace of a restart loop.

`docker-compose.yaml` overrides the image's default healthcheck for the same
reason: that default runs LinuxGSM `monitor`, which *restarts* a dead server and
exits 0, so it can never report unhealthy.

`monitor` is LinuxGSM's own hung-process check; Docker's `restart: unless-stopped`
only recovers a container that has actually exited, not one that is alive but
unresponsive. Schedule it with a host crontab entry so hangs are caught
automatically:

```cron
*/5 * * * * /path/to/manage.sh monitor all >> /var/log/manage-monitor.log 2>&1
```

### Commands

```text
list
status [server|all]
start <server|all>
stop <server|all>
restart <server|all>
update <server|all>
check-update <server|all>
force-update <server|all>
update-lgsm <server|all>
validate <server|all>
backup <server|all>
monitor <server|all>
details <server>
console <server>
logs <server> [--follow]
shell <server>
exec <server> <command...>
upgrade <server|all>
apply-config <server|all>
doctor
```

`upgrade` runs these LinuxGSM operations sequentially:

1. `update-lgsm`
2. `update`
3. `validate`

## Initial setup

LinuxGSM installs the selected dedicated server into its `/data` volume during initial container setup. Follow the container logs from Coolify or with:

```bash
./manage.sh logs minecraft --follow
```

Minecraft Java Edition requires accepting Mojang's EULA. After the server files exist, set this in the Minecraft volume:

```text
serverfiles/eula.txt
```

```text
eula=true
```

Restart the Minecraft container afterward.

## Persistent data

Each server bind-mounts its own folder under `/opt/gs` to `/data` inside the
container:

```text
/opt/gs/
├── minecraft/
├── project-zomboid/
├── valheim/
└── seven-days-to-die/
```

These paths are **literal in `docker-compose.yaml` and deliberately not an
environment variable**. Coolify rejects any volume source containing a variable
reference outright ("Shell metacharacters are not allowed for security
reasons"), and the short `source:target` volume form additionally mis-splits a
`${VAR:-default}` expression on the colon inside it — which silently mounts the
wrong directory rather than failing. To relocate the data, edit the four
`source:` lines in `docker-compose.yaml`.

They must stay **absolute**. A relative path would resolve inside Coolify's
per-deployment checkout directory, which changes on every deploy.

Each folder must be owned by `GS_UID:GS_GID` (default `1000:1000`), matching the
container's `linuxgsm` user. The entrypoint chowns `/data` on start, so a
mismatch is repaired but costs a slow recursive chown on every boot.

```bash
sudo mkdir -p /opt/gs/{minecraft,project-zomboid,valheim,seven-days-to-die}
sudo chown 1000:1000 /opt/gs/*
```

Back these folders up directly with any file-level tool, and use
`./manage.sh backup all` for LinuxGSM's own in-server backups. Bind mounts make
the data readable from the host without going through Docker — `du`, `rsync`,
restic and friends all work on `/opt/gs` unaided.

### Migrating from named volumes

If you are moving an existing deployment off named volumes, copy the data
across **with the servers stopped**, or worlds will be copied mid-write:

```bash
./manage.sh stop all                       # graceful; flushes world saves
docker stop $(docker ps -q --filter label=com.eslefi.gs.managed=true)

for s in minecraft project-zomboid valheim seven-days-to-die; do
  docker run --rm -v "<project>_${s}-data:/src:ro" -v "/opt/gs/$s:/dst" \
    alpine:latest cp -a /src/. /dst/
done
```

Then redeploy in Coolify so the containers are recreated on the bind mounts.
Verify before deleting the old volumes:

```bash
./manage.sh doctor                         # all four must report "server running"
docker volume rm <project>_minecraft-data  # ...only once verified
```

Note that Docker will happily create an **empty** directory for a bind mount
that does not exist. A typo in a `source:` path therefore does not fail loudly —
it presents as LinuxGSM reinstalling the game from scratch onto a blank folder,
with the real data still sitting in the old location.

## License

[MIT](LICENSE)
