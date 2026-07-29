#!/usr/bin/env bash
set -Eeuo pipefail

readonly SCRIPT_NAME="${0##*/}"
readonly LABEL_MANAGED="com.eslefi.gs.managed=true"
readonly LABEL_SERVICE="com.eslefi.gs.service"
readonly LABEL_SCRIPT="com.eslefi.gs.script"
readonly LINUXGSM_USER="linuxgsm"

readonly -a SERVICES=(
  minecraft
  project-zomboid
  valheim
  seven-days-to-die
)

declare -A DISPLAY_NAMES=(
  [minecraft]="Minecraft"
  [project-zomboid]="Project Zomboid"
  [valheim]="Valheim"
  [seven-days-to-die]="7 Days to Die"
)
readonly DISPLAY_NAMES

declare -A DEFAULT_SCRIPTS=(
  [minecraft]="mcserver"
  [project-zomboid]="pzserver"
  [valheim]="vhserver"
  [seven-days-to-die]="sdtdserver"
)
readonly DEFAULT_SCRIPTS

if [[ -t 1 && "${NO_COLOR:-}" == "" ]]; then
  readonly RED=$'\033[31m'
  readonly GREEN=$'\033[32m'
  readonly YELLOW=$'\033[33m'
  readonly BLUE=$'\033[34m'
  readonly BOLD=$'\033[1m'
  readonly RESET=$'\033[0m'
else
  readonly RED="" GREEN="" YELLOW="" BLUE="" BOLD="" RESET=""
fi

log_info() { printf '%s[INFO]%s %s\n' "$BLUE" "$RESET" "$*"; }
log_ok() { printf '%s[ OK ]%s %s\n' "$GREEN" "$RESET" "$*"; }
log_warn() { printf '%s[WARN]%s %s\n' "$YELLOW" "$RESET" "$*" >&2; }
log_error() { printf '%s[ERR ]%s %s\n' "$RED" "$RESET" "$*" >&2; }
die() { log_error "$*"; exit 1; }

usage() {
  cat <<EOF
Usage:
  $SCRIPT_NAME [command] [server|all] [options]

Commands:
  list                         List configured servers and container state
  status [server|all]          Show LinuxGSM status
  start <server|all>           Start game server process
  stop <server|all>            Stop game server process gracefully
  restart <server|all>         Restart game server process
  update <server|all>          Update game server files
  check-update <server|all>    Check for game server updates
  force-update <server|all>    Force game server update
  update-lgsm <server|all>     Update LinuxGSM itself
  validate <server|all>        Validate game server files
  backup <server|all>          Create a LinuxGSM backup
  monitor <server|all>         Run LinuxGSM monitor check
  details <server>             Show detailed server information
  console <server>             Open the LinuxGSM console
  logs <server> [--follow]     Show Docker container logs
  shell <server>               Open a shell as the linuxgsm user
  exec <server> <command...>   Execute an arbitrary command in the container
  upgrade <server|all>         update-lgsm, update and validate sequentially
  doctor                       Check Docker, containers, resources and ports
  help                         Show this help

Servers:
  minecraft
  project-zomboid
  valheim
  seven-days-to-die
  all

Examples:
  ./$SCRIPT_NAME list
  ./$SCRIPT_NAME restart valheim
  ./$SCRIPT_NAME update all
  ./$SCRIPT_NAME logs minecraft --follow
  ./$SCRIPT_NAME console project-zomboid
EOF
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"
}

require_docker() {
  require_command docker
  docker info >/dev/null 2>&1 || die "Docker daemon is unavailable or access is denied."
}

is_known_service() {
  local candidate=$1 service
  for service in "${SERVICES[@]}"; do
    [[ "$candidate" == "$service" ]] && return 0
  done
  return 1
}

validate_target() {
  local target=${1:-}
  [[ -n "$target" ]] || die "A server name or 'all' is required."
  [[ "$target" == "all" ]] || is_known_service "$target" || die "Unknown server: $target"
}

container_id() {
  local service=$1
  local -a ids=()
  mapfile -t ids < <(docker ps -aq \
    --filter "label=$LABEL_MANAGED" \
    --filter "label=$LABEL_SERVICE=$service")

  if (( ${#ids[@]} == 0 )); then
    return 1
  fi

  if (( ${#ids[@]} > 1 )); then
    log_warn "Multiple containers found for '$service'; using the newest one."
    docker ps -aq --no-trunc \
      --filter "label=$LABEL_MANAGED" \
      --filter "label=$LABEL_SERVICE=$service" | head -n 1
    return
  fi

  printf '%s\n' "${ids[0]}"
}

container_name() {
  docker inspect --format '{{.Name}}' "$1" | sed 's#^/##'
}

container_state() {
  docker inspect --format '{{.State.Status}}' "$1"
}

is_running() {
  [[ "$(container_state "$1")" == "running" ]]
}

linuxgsm_script() {
  local service=$1 id=$2 script
  script=$(docker inspect --format "{{ index .Config.Labels \"$LABEL_SCRIPT\" }}" "$id" 2>/dev/null || true)
  if [[ -z "$script" || "$script" == "<no value>" ]]; then
    script=${DEFAULT_SCRIPTS[$service]}
  fi
  printf '%s\n' "$script"
}

require_container() {
  local service=$1 id
  id=$(container_id "$service") || die "No Coolify-managed container found for '$service'. Deploy docker-compose.yaml first."
  printf '%s\n' "$id"
}

require_running_container() {
  local service=$1 id
  id=$(require_container "$service") || return 1
  is_running "$id" || die "Container for '$service' is not running. Start it from Coolify first."
  printf '%s\n' "$id"
}

run_lgsm() {
  local service=$1 command=$2
  local id script name
  id=$(require_running_container "$service") || return 1
  script=$(linuxgsm_script "$service" "$id")
  name=$(container_name "$id")

  log_info "${DISPLAY_NAMES[$service]}: ./$script $command ($name)"
  docker exec -it --user "$LINUXGSM_USER" "$id" "./$script" "$command"
}

run_lgsm_noninteractive() {
  local service=$1 command=$2
  local id script name
  id=$(require_running_container "$service") || return 1
  script=$(linuxgsm_script "$service" "$id")
  name=$(container_name "$id")

  log_info "${DISPLAY_NAMES[$service]}: ./$script $command ($name)"
  docker exec --user "$LINUXGSM_USER" "$id" "./$script" "$command"
}

for_target() {
  local target=$1 callback=$2
  shift 2
  local service failed=0

  if [[ "$target" == "all" ]]; then
    for service in "${SERVICES[@]}"; do
      "$callback" "$service" "$@" || failed=1
    done
  else
    "$callback" "$target" "$@" || failed=1
  fi

  return "$failed"
}

print_list() {
  printf '%-22s %-28s %-12s %-12s\n' "SERVER" "CONTAINER" "CONTAINER" "LINUXGSM"
  printf '%-22s %-28s %-12s %-12s\n' "----------------------" "----------------------------" "------------" "------------"

  local service id name state script lgsm_state
  for service in "${SERVICES[@]}"; do
    if ! id=$(container_id "$service"); then
      printf '%-22s %-28s %-12s %-12s\n' "${DISPLAY_NAMES[$service]}" "-" "missing" "-"
      continue
    fi

    name=$(container_name "$id")
    state=$(container_state "$id")
    script=$(linuxgsm_script "$service" "$id")
    lgsm_state="unavailable"

    if [[ "$state" == "running" ]]; then
      if docker exec --user "$LINUXGSM_USER" "$id" "./$script" details >/dev/null 2>&1; then
        lgsm_state="available"
      else
        lgsm_state="check failed"
      fi
    fi

    printf '%-22s %-28s %-12s %-12s\n' "${DISPLAY_NAMES[$service]}" "$name" "$state" "$lgsm_state"
  done
}

show_status_one() {
  local service=$1 id script
  id=$(require_running_container "$service") || return 1
  script=$(linuxgsm_script "$service" "$id")
  printf '\n%s%s%s\n' "$BOLD" "${DISPLAY_NAMES[$service]}" "$RESET"
  docker exec --user "$LINUXGSM_USER" "$id" "./$script" details
}

show_logs() {
  local service=$1 follow=${2:-false} id
  id=$(require_container "$service") || return 1
  if [[ "$follow" == "true" ]]; then
    docker logs --follow --tail 200 "$id"
  else
    docker logs --tail 200 "$id"
  fi
}

open_shell() {
  local service=$1 id shell
  id=$(require_running_container "$service") || return 1
  shell=$(docker exec --user "$LINUXGSM_USER" "$id" sh -lc 'command -v bash || command -v sh')
  docker exec -it --user "$LINUXGSM_USER" "$id" "$shell"
}

exec_in_container() {
  local service=$1
  shift
  (( $# > 0 )) || die "exec requires a command."
  local id
  id=$(require_running_container "$service") || return 1
  docker exec -it --user "$LINUXGSM_USER" "$id" "$@"
}

upgrade_one() {
  local service=$1
  run_lgsm_noninteractive "$service" update-lgsm || return 1
  run_lgsm_noninteractive "$service" update || return 1
  run_lgsm_noninteractive "$service" validate || return 1
}

port_summary() {
  require_command ss
  printf '%sListening game-server ports:%s\n' "$BOLD" "$RESET"
  ss -H -lntu | awk '{print $1, $5}' | sort -u
}

doctor() {
  local failures=0 service id state disk_used mem_available

  printf '%sSystem checks%s\n' "$BOLD" "$RESET"

  if docker info >/dev/null 2>&1; then
    log_ok "Docker daemon is available."
  else
    log_error "Docker daemon is unavailable."
    failures=1
  fi

  disk_used=$(df -P /var/lib/docker 2>/dev/null | awk 'NR==2 {print $5}' || df -P / | awk 'NR==2 {print $5}')
  log_info "Docker filesystem usage: ${disk_used:-unknown}"

  mem_available=$(awk '/MemAvailable:/ {printf "%.1f GiB", $2/1024/1024}' /proc/meminfo 2>/dev/null || true)
  log_info "Available memory: ${mem_available:-unknown}"

  printf '\n%sContainer checks%s\n' "$BOLD" "$RESET"
  for service in "${SERVICES[@]}"; do
    if ! id=$(container_id "$service"); then
      log_error "${DISPLAY_NAMES[$service]}: container missing"
      failures=1
      continue
    fi

    state=$(container_state "$id")
    if [[ "$state" == "running" ]]; then
      log_ok "${DISPLAY_NAMES[$service]}: container running ($(container_name "$id"))"
    else
      log_error "${DISPLAY_NAMES[$service]}: container state is $state"
      failures=1
    fi
  done

  if command -v ss >/dev/null 2>&1; then
    printf '\n'
    port_summary
  else
    log_warn "The 'ss' command is unavailable; port inspection skipped."
  fi

  return "$failures"
}

interactive_menu() {
  local action target
  printf '%sLinuxGSM server manager%s\n\n' "$BOLD" "$RESET"
  PS3="Select action: "
  select action in list status start stop restart update check-update force-update \
    update-lgsm validate backup monitor upgrade details logs console shell exec \
    doctor help quit; do
    [[ -n "$action" ]] || continue
    [[ "$action" == "quit" ]] && return 0
    if [[ "$action" == "list" || "$action" == "doctor" || "$action" == "help" ]]; then
      main "$action"
      return
    fi

    printf '\n'
    PS3="Select server: "
    select target in "${SERVICES[@]}" all cancel; do
      [[ -n "$target" ]] || continue
      [[ "$target" == "cancel" ]] && return 0
      if [[ "$action" =~ ^(details|logs|console|shell|exec)$ && "$target" == "all" ]]; then
        log_warn "'$action' requires one server."
        continue
      fi
      if [[ "$action" == "exec" ]]; then
        local -a cmd_args=()
        read -rp "Command to run: " -a cmd_args
        (( ${#cmd_args[@]} > 0 )) || { log_warn "exec requires a command."; continue; }
        main "$action" "$target" "${cmd_args[@]}"
        return
      fi
      main "$action" "$target"
      return
    done
  done
}

main() {
  require_docker

  local command=${1:-}
  if [[ -z "$command" ]]; then
    interactive_menu
    return
  fi
  shift || true

  case "$command" in
    help|-h|--help)
      usage
      ;;
    list)
      print_list
      ;;
    status)
      local target=${1:-all}
      validate_target "$target"
      for_target "$target" show_status_one
      ;;
    start|stop|restart|update|check-update|force-update|update-lgsm|validate|backup|monitor)
      local target=${1:-}
      validate_target "$target"
      for_target "$target" run_lgsm_noninteractive "$command"
      ;;
    details)
      local target=${1:-}
      validate_target "$target"
      [[ "$target" != "all" ]] || die "details requires one server."
      run_lgsm "$target" details
      ;;
    console)
      local target=${1:-}
      validate_target "$target"
      [[ "$target" != "all" ]] || die "console requires one server."
      run_lgsm "$target" console
      ;;
    logs)
      local target=${1:-}
      validate_target "$target"
      [[ "$target" != "all" ]] || die "logs requires one server."
      show_logs "$target" "$( [[ "${2:-}" == "--follow" || "${2:-}" == "-f" ]] && echo true || echo false )"
      ;;
    shell)
      local target=${1:-}
      validate_target "$target"
      [[ "$target" != "all" ]] || die "shell requires one server."
      open_shell "$target"
      ;;
    exec)
      local target=${1:-}
      validate_target "$target"
      [[ "$target" != "all" ]] || die "exec requires one server."
      shift
      exec_in_container "$target" "$@"
      ;;
    upgrade)
      local target=${1:-}
      validate_target "$target"
      for_target "$target" upgrade_one
      ;;
    doctor)
      doctor
      ;;
    *)
      usage >&2
      die "Unknown command: $command"
      ;;
  esac
}

main "$@"
