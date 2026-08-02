#!/usr/bin/env bats
# shellcheck shell=bash disable=SC2154,SC2030,SC2031
# SC2154: BATS_TEST_DIRNAME/status/output are provided by bats-core, not
# assigned in this file.
# SC2030/SC2031: MOCK_MISSING_SERVICE is exported per-@test and consumed by
# the `run` call in that same test body; bats does not lose the export the
# way shellcheck's generic subshell heuristic assumes.
#
# Stubs `docker` via PATH injection so manage.sh's command dispatch and
# container-lookup error handling can be exercised without a real Docker
# daemon or LinuxGSM containers.
#
# MOCK_MISSING_SERVICE (space-separated) marks services with no container at
# all. Everything else is reported as a running container.

setup() {
  MANAGE_SH="$(cd "$BATS_TEST_DIRNAME/.." && pwd)/manage.sh"
  TEST_BIN="$(mktemp -d)"

  cat >"$TEST_BIN/docker" <<'MOCK'
#!/usr/bin/env bash
set -Eeuo pipefail

is_missing() {
  local svc=$1 m
  for m in ${MOCK_MISSING_SERVICE:-}; do
    [[ "$m" == "$svc" ]] && return 0
  done
  return 1
}

case "$1" in
  info) exit 0 ;;
  ps)
    svc=""
    for a in "$@"; do
      case "$a" in
        label=com.eslefi.gs.service=*) svc="${a#label=com.eslefi.gs.service=}" ;;
      esac
    done
    is_missing "$svc" || echo "id-$svc"
    exit 0
    ;;
  inspect)
    id="${*: -1}"
    if [[ -z "$id" ]]; then
      echo "Error: No such object: " >&2
      exit 1
    fi
    case "$3" in
      *State.Status*) echo "running" ;;
      *Config.Env*)
        # Stands in for what Coolify injects into the container. Set
        # MOCK_CONTAINER_ENV to newline-separated KEY=VALUE pairs.
        [[ -n "${MOCK_CONTAINER_ENV:-}" ]] && printf '%s\n' "${MOCK_CONTAINER_ENV}"
        ;;
      *.Name*) echo "/${id}" ;;
      *Labels*) echo "" ;;
    esac
    exit 0
    ;;
  exec)
    # Skip the flags manage.sh may or may not pass (-i -t) to find the id.
    id=""; has_i=0
    shift
    while (( $# )); do
      case "$1" in
        -i) has_i=1; shift ;;
        -it) has_i=1; shift ;;
        -t) shift ;;
        --user) shift 2 ;;
        *) id="$1"; break ;;
      esac
    done
    if [[ -z "$id" ]]; then
      echo "Error: No such container: " >&2
      exit 1
    fi
    echo "MOCK-EXEC: $*"
    # -i means manage.sh is piping a file body in (apply-config writes the
    # LinuxGSM config this way). Echo it so tests can assert on the content
    # that would have been written.
    if (( has_i )); then
      echo "MOCK-STDIN:"
      cat
    fi
    exit 0
    ;;
  logs)
    echo "MOCK-LOGS: $*"
    exit 0
    ;;
  *)
    echo "unhandled docker subcommand: $*" >&2
    exit 1
    ;;
esac
MOCK
  chmod +x "$TEST_BIN/docker"
  PATH="$TEST_BIN:$PATH"
  export MOCK_MISSING_SERVICE=""
}

teardown() {
  rm -rf "$TEST_BIN"
}

@test "restart on a missing container prints exactly one diagnostic and exits 1" {
  export MOCK_MISSING_SERVICE=valheim
  run bash "$MANAGE_SH" restart valheim
  [ "$status" -eq 1 ]
  count=$(grep -c "No Coolify-managed container found for 'valheim'" <<<"$output")
  [ "$count" -eq 1 ]
  [[ "$output" != *"vhserver restart ()"* ]]
}

@test "restart all skips the missing service but still restarts the rest" {
  export MOCK_MISSING_SERVICE=valheim
  run bash "$MANAGE_SH" restart all
  [ "$status" -eq 1 ]
  [[ "$output" == *"Minecraft: ./mcserver restart"* ]]
  [[ "$output" == *"Project Zomboid: ./pzserver restart"* ]]
  [[ "$output" == *"7 Days to Die: ./sdtdserver restart"* ]]
  count=$(grep -c "No Coolify-managed container found for 'valheim'" <<<"$output")
  [ "$count" -eq 1 ]
}

@test "restart all succeeds cleanly when every container is present" {
  run bash "$MANAGE_SH" restart all
  [ "$status" -eq 0 ]
  [[ "$output" == *"Minecraft: ./mcserver restart"* ]]
  [[ "$output" == *"Project Zomboid: ./pzserver restart"* ]]
  [[ "$output" == *"Valheim: ./vhserver restart"* ]]
  [[ "$output" == *"7 Days to Die: ./sdtdserver restart"* ]]
}

@test "upgrade stops after the first failed step instead of repeating the diagnostic" {
  export MOCK_MISSING_SERVICE=valheim
  run bash "$MANAGE_SH" upgrade valheim
  [ "$status" -eq 1 ]
  count=$(grep -c "No Coolify-managed container found for 'valheim'" <<<"$output")
  [ "$count" -eq 1 ]
}

@test "upgrade all skips the missing service but still upgrades the rest" {
  export MOCK_MISSING_SERVICE=valheim
  run bash "$MANAGE_SH" upgrade all
  [ "$status" -eq 1 ]
  [[ "$output" == *"Minecraft: ./mcserver update-lgsm"* ]]
  [[ "$output" == *"Minecraft: ./mcserver update"* ]]
  [[ "$output" == *"Minecraft: ./mcserver validate"* ]]
  [[ "$output" == *"7 Days to Die: ./sdtdserver validate"* ]]
}

@test "list reports a missing container without dying" {
  export MOCK_MISSING_SERVICE=valheim
  run bash "$MANAGE_SH" list
  [ "$status" -eq 0 ]
  [[ "$output" == *"missing"* ]]
}

@test "an unknown server name is rejected" {
  run bash "$MANAGE_SH" restart not-a-real-server
  [ "$status" -eq 1 ]
  [[ "$output" == *"Unknown server: not-a-real-server"* ]]
}

@test "an unknown command is rejected" {
  run bash "$MANAGE_SH" not-a-real-command
  [ "$status" -eq 1 ]
  [[ "$output" == *"Unknown command: not-a-real-command"* ]]
}

@test "doctor exits 1 and names the service when a container is missing" {
  export MOCK_MISSING_SERVICE=valheim
  run bash "$MANAGE_SH" doctor
  [ "$status" -eq 1 ]
  [[ "$output" == *"Valheim: container missing"* ]]
}

@test "doctor exits 0 when every container is present and the game is running" {
  run bash "$MANAGE_SH" doctor
  [ "$status" -eq 0 ]
  [[ "$output" == *"server running"* ]]
}

@test "logs passes --follow through to docker" {
  run bash "$MANAGE_SH" logs minecraft --follow
  [ "$status" -eq 0 ]
  [[ "$output" == *"--follow"* ]]
}

@test "logs without --follow does not pass it through" {
  run bash "$MANAGE_SH" logs minecraft
  [ "$status" -eq 0 ]
  [[ "$output" != *"--follow"* ]]
}

@test "exec succeeds when stdin is not a TTY" {
  run bash -c "bash '$MANAGE_SH' exec valheim echo hello </dev/null"
  [ "$status" -eq 0 ]
  [[ "$output" == *"MOCK-EXEC"* ]]
}

@test "exec with no command is rejected" {
  run bash "$MANAGE_SH" exec valheim
  [ "$status" -eq 1 ]
  [[ "$output" == *"exec requires a command"* ]]
}

@test "shell fails fast with a clear message when there is no TTY" {
  run bash -c "bash '$MANAGE_SH' shell valheim </dev/null"
  [ "$status" -eq 1 ]
  [[ "$output" == *"requires an interactive terminal"* ]]
}

@test "commands that require one server reject 'all'" {
  run bash "$MANAGE_SH" details all
  [ "$status" -eq 1 ]
  [[ "$output" == *"details requires one server"* ]]
}

# On a Coolify host there is no .env in the deployment; settings arrive through
# the container environment instead, so a missing file must not be fatal.
@test "apply-config continues without an env file, using the container env" {
  export MOCK_CONTAINER_ENV="MINECRAFT_LGSM_JAVARAM=4096"
  run env ENV_FILE="$TEST_BIN/nope.env" bash "$MANAGE_SH" apply-config minecraft
  [ "$status" -eq 0 ]
  [[ "$output" == *"No $TEST_BIN/nope.env"* ]]
  [[ "$output" == *"wrote 1 LinuxGSM setting"* ]]
}

@test "apply-config reads settings from the container environment alone" {
  : >"$TEST_BIN/empty.env"
  export MOCK_CONTAINER_ENV="MINECRAFT_PROP_max_players=32"
  run env ENV_FILE="$TEST_BIN/empty.env" bash "$MANAGE_SH" apply-config minecraft
  [ "$status" -eq 0 ]
  [[ "$output" == *"max-players"* ]]
  [[ "$output" == *"32"* ]]
}

# Coolify is the source of truth: a value set there must beat a stale local one.
@test "container environment overrides the host env file" {
  cat >"$TEST_BIN/t.env" <<'ENV'
MINECRAFT_LGSM_JAVARAM=1111
ENV
  export MOCK_CONTAINER_ENV="MINECRAFT_LGSM_JAVARAM=9999"
  run env ENV_FILE="$TEST_BIN/t.env" bash "$MANAGE_SH" apply-config minecraft
  [ "$status" -eq 0 ]
  [[ "$output" == *"9999"* ]]
  [[ "$output" != *"1111"* ]]
}

@test "host env file still applies for keys the container does not set" {
  cat >"$TEST_BIN/t.env" <<'ENV'
MINECRAFT_LGSM_JAVARAM=6144
ENV
  export MOCK_CONTAINER_ENV="SOME_UNRELATED_VAR=x"
  run env ENV_FILE="$TEST_BIN/t.env" bash "$MANAGE_SH" apply-config minecraft
  [ "$status" -eq 0 ]
  [[ "$output" == *"6144"* ]]
}

# The container environment is full of unrelated variables (PATH, COOLIFY_*).
@test "unrelated container variables are ignored" {
  : >"$TEST_BIN/empty.env"
  export MOCK_CONTAINER_ENV="PATH=/usr/bin
COOLIFY_URL=https://example.test
SERVICE_NAME_MINECRAFT=minecraft
UID=1000"
  run env ENV_FILE="$TEST_BIN/empty.env" bash "$MANAGE_SH" apply-config minecraft
  [ "$status" -eq 0 ]
  [[ "$output" == *"no MINECRAFT_LGSM_* settings"* ]]
}

@test "apply-config writes LinuxGSM settings from <PREFIX>_LGSM_ vars" {
  cat >"$TEST_BIN/t.env" <<'ENV'
MINECRAFT_LGSM_JAVARAM=6144
ENV
  run env ENV_FILE="$TEST_BIN/t.env" bash "$MANAGE_SH" apply-config minecraft
  [ "$status" -eq 0 ]
  [[ "$output" == *"wrote 1 LinuxGSM setting"* ]]
}

@test "apply-config reports when a service has no settings at all" {
  : >"$TEST_BIN/empty.env"
  run env ENV_FILE="$TEST_BIN/empty.env" bash "$MANAGE_SH" apply-config valheim
  [ "$status" -eq 0 ]
  [[ "$output" == *"no VALHEIM_LGSM_* settings"* ]]
}

# server.properties keys use characters that are illegal in shell variable
# names, so the _ -> - and query_/rcon_ -> query./rcon. translation is the part
# most likely to regress.
@test "apply-config translates _ to - and query_/rcon_ to a dot" {
  cat >"$TEST_BIN/t.env" <<'ENV'
MINECRAFT_PROP_max_players=20
MINECRAFT_PROP_query_port=25565
MINECRAFT_PROP_rcon_password=secret
ENV
  run env ENV_FILE="$TEST_BIN/t.env" bash "$MANAGE_SH" apply-config minecraft
  [ "$status" -eq 0 ]
  [[ "$output" == *"wrote 3 setting"* ]]
  [[ "$output" == *"max-players"* ]]
  [[ "$output" == *"query.port"* ]]
  [[ "$output" == *"rcon.password"* ]]
  [[ "$output" != *"max_players"* ]]
}

# .env is shared with docker compose, whose quoting rules are not the shell's.
@test "apply-config accepts unquoted spaces, quotes and inline comments" {
  cat >"$TEST_BIN/t.env" <<'ENV'
# a comment
MINECRAFT_PROP_motd=A Minecraft Server
MINECRAFT_PROP_difficulty="normal"
MINECRAFT_PROP_level_name='my world'
MINECRAFT_PROP_view_distance=10   # trailing comment
ENV
  run env ENV_FILE="$TEST_BIN/t.env" bash "$MANAGE_SH" apply-config minecraft
  [ "$status" -eq 0 ]
  [[ "$output" == *"wrote 4 setting"* ]]
  [[ "$output" == *"A Minecraft Server"* ]]
  [[ "$output" == *"my world"* ]]
  # the inline comment must not survive into the value
  [[ "$output" != *"trailing comment"* ]]
}

# An apostrophe used to close the quote that the value was spliced into, so the
# remote shell died with "Unterminated quoted string" and the setting was
# skipped. Server names like `drifter9000's Minecraft server` are exactly the
# case that regressed.
@test "apply-config applies values containing apostrophes and shell metacharacters" {
  cat >"$TEST_BIN/t.env" <<'ENV'
MINECRAFT_PROP_motd=drifter9000's Minecraft server
MINECRAFT_PROP_level_name=a|b&c$d`e
ENV
  run env ENV_FILE="$TEST_BIN/t.env" bash "$MANAGE_SH" apply-config minecraft
  [ "$status" -eq 0 ]
  [[ "$output" == *"wrote 2 setting"* ]]
  [[ "$output" == *"motd=drifter9000's Minecraft server"* ]]
  # sed would have eaten | and &; the shell would have eaten $ and `
  [[ "$output" == *'level-name=a|b&c$d`e'* ]]
  [[ "$output" != *"Unterminated"* ]]
  [[ "$output" != *"could not set"* ]]
}

@test "apply-config writes 7 Days to Die XML properties verbatim" {
  cat >"$TEST_BIN/t.env" <<'ENV'
SEVEN_DAYS_TO_DIE_XML_ServerMaxPlayerCount=10
ENV
  run env ENV_FILE="$TEST_BIN/t.env" bash "$MANAGE_SH" apply-config seven-days-to-die
  [ "$status" -eq 0 ]
  [[ "$output" == *"ServerMaxPlayerCount"* ]]
}

@test "apply-config rejects an unknown server" {
  cat >"$TEST_BIN/t.env" <<'ENV'
MINECRAFT_LGSM_JAVARAM=6144
ENV
  run env ENV_FILE="$TEST_BIN/t.env" bash "$MANAGE_SH" apply-config not-a-real-server
  [ "$status" -eq 1 ]
  [[ "$output" == *"Unknown server: not-a-real-server"* ]]
}
