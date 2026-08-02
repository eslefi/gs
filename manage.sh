#!/usr/bin/env bash
set -Eeuo pipefail
# Extended globs are used by the .env parser's trimming patterns.
shopt -s extglob

readonly SCRIPT_NAME="${0##*/}"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
readonly ENV_FILE="${ENV_FILE:-$SCRIPT_DIR/.env}"
readonly MANAGED_BEGIN="# BEGIN managed by manage.sh apply-config - edits here are overwritten"
readonly MANAGED_END="# END managed by manage.sh apply-config"
readonly LABEL_MANAGED="com.eslefi.gs.managed=true"
readonly LABEL_SERVICE="com.eslefi.gs.service"
readonly LABEL_SCRIPT="com.eslefi.gs.script"
readonly LINUXGSM_USER="linuxgsm"

# Matches the running dedicated-server process inside any of the containers.
# Bracketed first characters keep the pattern from matching the pgrep shell
# itself. Container state alone does not tell us whether the game is alive.
readonly GAME_PROCESS_RE='[m]inecraft_server[.]jar|[P]rojectZomboid64|[v]alheim_server|[7]DaysToDieServer'

readonly -a SERVICES=(
  minecraft
  project-zomboid
  valheim
  seven-days-to-die
)

# Do not run `shfmt -w` on this file: shfmt misparses hyphenated associative
# array keys as arithmetic ([project-zomboid] -> [project - zomboid]) and
# silently breaks every lookup below. `shfmt -d` shows the corruption.
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

# Environment-variable prefix per service, used by `apply-config`.
declare -A ENV_PREFIX=(
  [minecraft]="MINECRAFT"
  [project-zomboid]="PROJECT_ZOMBOID"
  [valheim]="VALHEIM"
  [seven-days-to-die]="SEVEN_DAYS_TO_DIE"
)
readonly ENV_PREFIX

# Game config file per service, as "<format>|<infix>|<keystyle>|<path>".
#   infix    - the env-var segment, e.g. PROP in MINECRAFT_PROP_max_players
#   keystyle - dash:     _ becomes -, and a leading query-/rcon- becomes
#              query./rcon.  (server.properties uses characters that are
#              illegal in shell variable names, so they must be translated)
#              verbatim: the key is used exactly as written
# Valheim has no game config file of its own — everything is driven through
# LinuxGSM start parameters, so it has no entry here.
declare -A GAME_CONFIG=(
  [minecraft]="kv|PROP|dash|/data/serverfiles/server.properties"
  [project-zomboid]="kv|INI|verbatim|/data/Zomboid/Server/pzserver.ini"
  [seven-days-to-die]="xml|XML|verbatim|/data/serverfiles/sdtdserver.xml"
)
readonly GAME_CONFIG

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
  apply-config <server|all>    Push settings from .env into the server configs
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

# `docker exec -it` fails outright when stdin is not a terminal, which breaks
# every non-interactive caller (cron, CI, pipes). Allocate a TTY only when one
# actually exists.
docker_exec_tty() {
  local -a tty=()
  if [[ -t 0 && -t 1 ]]; then
    tty=(-i -t)
  fi
  docker exec ${tty[@]+"${tty[@]}"} --user "$LINUXGSM_USER" "$@"
}

require_tty() {
  [[ -t 0 && -t 1 ]] || die "'$1' requires an interactive terminal."
}

# True when the container is running the actual game process, not merely up.
game_is_running() {
  docker exec --user "$LINUXGSM_USER" "$1" \
    sh -lc "ps -eo args | grep -qE '$GAME_PROCESS_RE'" 2>/dev/null
}

# LinuxGSM writes one script log per start attempt. Count only the last hour:
# the all-time total never decreases, so it would keep warning long after a
# crash loop was fixed.
start_attempt_count() {
  docker exec --user "$LINUXGSM_USER" "$1" \
    sh -lc 'find /data/log/script -name "*-script-*.log" -mmin -60 2>/dev/null | wc -l' 2>/dev/null || echo 0
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
  docker_exec_tty "$id" "./$script" "$command"
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

  local service id name state lgsm_state
  for service in "${SERVICES[@]}"; do
    if ! id=$(container_id "$service"); then
      printf '%-22s %-28s %-12s %-12s\n' "${DISPLAY_NAMES[$service]}" "-" "missing" "-"
      continue
    fi

    name=$(container_name "$id")
    state=$(container_state "$id")
    lgsm_state="unavailable"

    # Report whether the *game* is alive, not merely whether the container is.
    # A container can sit "running" for hours around a dead or crash-looping
    # server, which is exactly the failure this column has to surface.
    if [[ "$state" == "running" ]]; then
      if game_is_running "$id"; then
        lgsm_state="running"
      else
        lgsm_state="DOWN"
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
  require_tty shell
  id=$(require_running_container "$service") || return 1
  shell=$(docker exec --user "$LINUXGSM_USER" "$id" sh -lc 'command -v bash || command -v sh')
  docker_exec_tty "$id" "$shell"
}

exec_in_container() {
  local service=$1
  shift
  (( $# > 0 )) || die "exec requires a command."
  local id
  id=$(require_running_container "$service") || return 1
  docker_exec_tty "$id" "$@"
}

# Load .env so apply-config can see the *_LGSM_/_PROP_/_INI_/_XML_ variables.
# Compose reads this file too, but only for its own interpolation — it does not
# pass these through to the containers, and the LinuxGSM images have no
# mechanism to consume arbitrary settings from the environment anyway.
# Settings from the host .env file (lowest precedence).
declare -A ENVFILE=()
# Effective settings for the service currently being configured.
declare -A SETTINGS=()

# Parsed rather than sourced, deliberately. This file is also read by docker
# compose, whose quoting rules differ from the shell's: `ServerName=My Game Host`
# is valid for compose but would make the shell try to run `Game`. Parsing keeps
# both consumers agreeing, and stops a config file from executing code.
#
# Missing is not fatal: on a Coolify host the settings normally arrive through
# the container environment instead, and there is no .env in the deployment.
load_env_file() {
  ENVFILE=()
  if [[ ! -f "$ENV_FILE" ]]; then
    log_info "No $ENV_FILE; using the container environment only."
    return 0
  fi

  local line key value
  while IFS= read -r line || [[ -n "$line" ]]; do
    line=${line%$'\r'}
    [[ "$line" =~ ^[[:space:]]*(#|$) ]] && continue
    [[ "$line" == *=* ]] || continue

    key=${line%%=*}
    value=${line#*=}
    key=${key##*([[:space:]])}
    key=${key%%*([[:space:]])}
    key=${key#export }
    [[ "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || continue

    if [[ ${#value} -ge 2 && "$value" == \"*\" ]]; then
      value=${value:1:${#value}-2}
    elif [[ ${#value} -ge 2 && "$value" == \'*\' ]]; then
      value=${value:1:${#value}-2}
    else
      # Unquoted: drop a trailing ` # comment`, matching compose's behaviour.
      value=${value%%+([[:space:]])#*}
      value=${value%%*([[:space:]])}
    fi

    ENVFILE["$key"]=$value
  done < "$ENV_FILE"
}

# Build the effective settings for one service. The container environment wins
# over the host .env, so a value set in Coolify beats a stale local file. The
# LinuxGSM images ignore these variables themselves — the container environment
# is being used purely as a transport that Coolify already knows how to fill.
collect_settings() {
  local id=$1 line key value
  SETTINGS=()
  for key in "${!ENVFILE[@]}"; do
    SETTINGS["$key"]=${ENVFILE[$key]}
  done
  while IFS= read -r line; do
    [[ "$line" == *=* ]] || continue
    key=${line%%=*}
    value=${line#*=}
    [[ "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || continue
    SETTINGS["$key"]=$value
  done < <(docker inspect --format '{{range .Config.Env}}{{println .}}{{end}}' "$id" 2> /dev/null || true)
}

# Emit "key<TAB>value" for every setting named <PREFIX>_<INFIX>_<KEY>.
# The convention means every setting the game exposes is reachable without this
# script carrying a table of hundreds of key names.
env_pairs() {
  local prefix=$1 infix=$2 var key
  for var in "${!SETTINGS[@]}"; do
    [[ "$var" == "${prefix}_${infix}_"* ]] || continue
    key=${var#"${prefix}_${infix}_"}
    [[ -n "$key" ]] || continue
    printf '%s\t%s\n' "$key" "${SETTINGS[$var]}"
  done
}

# Rewrite the managed block of the LinuxGSM instance config. Anything the
# operator added outside the markers is preserved.
apply_lgsm_config() {
  local service=$1 id=$2 script=$3
  local prefix=${ENV_PREFIX[$service]}
  local cfg="/data/config-lgsm/$script/$script.cfg"
  local block existing key value count=0

  block="$MANAGED_BEGIN"$'\n'
  # Sorted so the output is deterministic, and so a setting that another one
  # interpolates is assigned first. LinuxGSM's configs expand eagerly: a
  # `startparameters` referencing ${serverpassword} captures whatever the
  # variable held at assignment time, so `serverpassword` must precede it.
  while IFS=$'\t' read -r key value; do
    [[ -n "$key" ]] || continue
    # LinuxGSM config keys are lowercase; values are always quoted strings.
    block+="${key,,}=\"${value}\""$'\n'
    ((count++))
  done < <(env_pairs "$prefix" "LGSM" | sort -t$'\t' -k1,1)
  block+="$MANAGED_END"

  if ((count == 0)); then
    log_info "${DISPLAY_NAMES[$service]}: no ${prefix}_LGSM_* settings; leaving $script.cfg alone"
    return 0
  fi

  existing=$(docker exec --user "$LINUXGSM_USER" "$id" \
    sh -lc "sed '/^${MANAGED_BEGIN//\//\\/}\$/,/^${MANAGED_END//\//\\/}\$/d' '$cfg' 2>/dev/null || true")

  printf '%s\n%s\n' "$existing" "$block" \
    | docker exec -i --user "$LINUXGSM_USER" "$id" sh -lc "cat > '$cfg'"

  log_ok "${DISPLAY_NAMES[$service]}: wrote $count LinuxGSM setting(s) to $script.cfg"
}

# Translate an env-var key segment into the real config key.
config_key() {
  local key=$1 style=$2
  if [[ "$style" == "dash" ]]; then
    key=${key//_/-}
    # server.properties groups these under a dot, not a dash.
    key=${key/#query-/query.}
    key=${key/#rcon-/rcon.}
  fi
  printf '%s\n' "$key"
}

# Fetch a config file out of the container. Fails loudly rather than returning
# an empty body, so a missing file can never be mistaken for an empty one.
read_remote_file() {
  docker exec --user "$LINUXGSM_USER" "$1" sh -c '[ -f "$1" ] && cat "$1"' _ "$2" 2>/dev/null
}

# Write a body back over a config file. The path travels as an argument, never
# as text spliced into the remote command.
write_remote_file() {
  docker exec -i --user "$LINUXGSM_USER" "$1" sh -c 'cat > "$1"' _ "$2"
}

# key=value files (Minecraft server.properties, Project Zomboid .ini).
#
# The file is fetched, rewritten here in bash, and written back whole. The edit
# deliberately does NOT happen in a `sh -c` inside the container. It used to,
# with the value interpolated into the remote command text as `v='$value'`, so
# any value containing an apostrophe closed that quote early: setting
# `PublicName=drifter9000's server` made the remote shell die with
# "Unterminated quoted string", the setting was skipped, and only a warning
# marked it. The same splice also fed the value to `sed` as a replacement, where
# `|`, `&` and `\` are metacharacters. Rewriting host-side re-parses nothing.
apply_kv_config() {
  local service=$1 id=$2 path=$3 infix=$4 style=$5
  local prefix=${ENV_PREFIX[$service]}
  local key value real count=0
  local -A wanted=() seen=()

  while IFS=$'\t' read -r key value; do
    [[ -n "$key" ]] || continue
    real=$(config_key "$key" "$style")
    wanted["$real"]=$value
  done < <(env_pairs "$prefix" "$infix")

  ((${#wanted[@]} > 0)) || return 0

  local content
  if ! content=$(read_remote_file "$id" "$path"); then
    log_warn "${DISPLAY_NAMES[$service]}: ${path##*/} is missing or unreadable; wrote nothing"
    return 0
  fi

  local -a out=()
  local line linekey
  while IFS= read -r line; do
    linekey=${line%%=*}
    linekey=${linekey##*([[:space:]])}
    linekey=${linekey%%*([[:space:]])}
    if [[ "$line" == *=* ]] && [[ -v wanted["$linekey"] ]]; then
      out+=("$linekey=${wanted[$linekey]}")
      if [[ ! -v seen["$linekey"] ]]; then
        seen["$linekey"]=1
        count=$((count + 1))
      fi
    else
      out+=("$line")
    fi
  done <<< "$content"

  # A key the file does not already carry is appended, as before.
  for key in "${!wanted[@]}"; do
    if [[ ! -v seen["$key"] ]]; then
      out+=("$key=${wanted[$key]}")
      count=$((count + 1))
    fi
  done

  printf '%s\n' "${out[@]}" | write_remote_file "$id" "$path"
  log_ok "${DISPLAY_NAMES[$service]}: wrote $count setting(s) to ${path##*/}"
}

# Attribute values are delimited with ", so an apostrophe needs no escaping, but
# a bare & or < would silently produce XML that 7 Days to Die cannot parse.
xml_escape() {
  local s=${1//&/\&amp;}
  s=${s//</\&lt;}
  s=${s//>/\&gt;}
  printf '%s' "${s//\"/\&quot;}"
}

# 7 Days to Die's <property name="X" value="Y"/> XML.
# Same fetch/rewrite/write-back shape as apply_kv_config, for the same reason.
apply_xml_config() {
  local service=$1 id=$2 path=$3 infix=$4
  local prefix=${ENV_PREFIX[$service]}
  local key value count=0
  local -A wanted=() seen=()

  while IFS=$'\t' read -r key value; do
    [[ -n "$key" ]] || continue
    wanted["$key"]=$value
  done < <(env_pairs "$prefix" "$infix")

  ((${#wanted[@]} > 0)) || return 0

  local content
  if ! content=$(read_remote_file "$id" "$path"); then
    log_warn "${DISPLAY_NAMES[$service]}: ${path##*/} is missing or unreadable; wrote nothing"
    return 0
  fi

  local -a out=() missing=()
  local line name
  while IFS= read -r line; do
    if [[ "$line" =~ name=\"([^\"]+)\"[[:space:]]*value=\" ]]; then
      name=${BASH_REMATCH[1]}
      if [[ -v wanted["$name"] ]] && [[ "$line" =~ ^(.*value=\")[^\"]*(\".*)$ ]]; then
        out+=("${BASH_REMATCH[1]}$(xml_escape "${wanted[$name]}")${BASH_REMATCH[2]}")
        if [[ ! -v seen["$name"] ]]; then
          seen["$name"]=1
          count=$((count + 1))
        fi
        continue
      fi
    fi
    out+=("$line")
  done <<< "$content"

  for key in "${!wanted[@]}"; do
    [[ -v seen["$key"] ]] || missing+=("$key")
  done
  ((${#missing[@]} == 0)) \
    || log_warn "${DISPLAY_NAMES[$service]}: no XML property named: ${missing[*]}"

  printf '%s\n' "${out[@]}" | write_remote_file "$id" "$path"
  ((count == 0)) || log_ok "${DISPLAY_NAMES[$service]}: wrote $count property/properties to ${path##*/}"
}

apply_config_one() {
  local service=$1 id script spec format infix style path
  id=$(require_running_container "$service") || return 1
  script=$(linuxgsm_script "$service" "$id")
  collect_settings "$id"

  apply_lgsm_config "$service" "$id" "$script"

  spec=${GAME_CONFIG[$service]:-}
  if [[ -n "$spec" ]]; then
    IFS='|' read -r format infix style path <<< "$spec"
    case "$format" in
      kv) apply_kv_config "$service" "$id" "$path" "$infix" "$style" ;;
      xml) apply_xml_config "$service" "$id" "$path" "$infix" ;;
    esac
  fi

  log_warn "${DISPLAY_NAMES[$service]}: restart required for changes to take effect."
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
  local failures=0 service id state disk_used mem_available starts

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
    if [[ "$state" != "running" ]]; then
      log_error "${DISPLAY_NAMES[$service]}: container state is $state"
      failures=1
      continue
    fi

    if game_is_running "$id"; then
      log_ok "${DISPLAY_NAMES[$service]}: server running ($(container_name "$id"))"
    else
      log_error "${DISPLAY_NAMES[$service]}: container is up but the game server is NOT running"
      failures=1
    fi

    # LinuxGSM's in-container monitor restarts a dead server every minute or so.
    # A large pile of per-start logs is the only visible trace of that loop.
    starts=$(start_attempt_count "$id")
    if [[ "$starts" =~ ^[0-9]+$ ]] && ((starts >= 10)); then
      log_warn "${DISPLAY_NAMES[$service]}: $starts start attempts logged - possible restart loop"
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
    update-lgsm validate backup monitor upgrade apply-config details logs console shell exec \
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
      require_tty console
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
    apply-config)
      local target=${1:-}
      validate_target "$target"
      load_env_file
      for_target "$target" apply_config_one
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
