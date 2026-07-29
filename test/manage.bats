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
      *.Name*) echo "/${id}" ;;
      *Labels*) echo "" ;;
    esac
    exit 0
    ;;
  exec)
    id="$4"
    if [[ -z "$id" ]]; then
      echo "Error: No such container: " >&2
      exit 1
    fi
    echo "MOCK-EXEC: $*"
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
