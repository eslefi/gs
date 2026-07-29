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

## Firewall

Open at least the following default ports on the host and any upstream firewall:

| Server | Ports |
| --- | --- |
| Minecraft | `25565/tcp` |
| Project Zomboid | `16261/udp`, player ports beginning at `16262/udp` |
| Valheim | `2456-2458/udp` |
| 7 Days to Die | `26900/tcp`, `26900-26903/udp` |

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

Each server uses its own named volume:

```text
minecraft-data
project-zomboid-data
valheim-data
seven-days-to-die-data
```

Back up these volumes through Coolify and use `./manage.sh backup all` for LinuxGSM's own server backups.

## License

[MIT](LICENSE)
