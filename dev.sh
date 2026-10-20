#!/usr/bin/env bash
# Server: PODMAN_HOST (first setting in config/dev.env). Compose lives beside this file.
set -o pipefail
ROOT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
CONFIG_FILE="$ROOT_DIR/config/dev.env"
RUNTIME_DIR="$ROOT_DIR/.runtime"
TUNNEL_PID_FILE="$RUNTIME_DIR/tunnel.pid"
TUNNEL_PID='' LOCKED=0
fail() { printf '✗ %s\n' "$*" >&2; exit 1; }
note() { printf '• %s\n' "$*"; }
ok() { printf '✓ %s\n' "$*"; }
quote() { local text=${1//\'/\'\\\'\'}; printf "'%s'" "$text"; }
cleanup() {
  [[ -z "$TUNNEL_PID" ]] || kill "$TUNNEL_PID" 2>/dev/null || true
  ((LOCKED == 0)) || rmdir "$RUNTIME_DIR/operation.lock" 2>/dev/null || true
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
usage() {
  cat <<'EOF'
Remote Podman / Compose

./dev.sh              Open the interactive menu (also on first run).
./dev.sh start [a|service,service]  Select Compose services; build and run on Linux.
./dev.sh status       Show the active Compose project.
./dev.sh stop [service,service]    Stop selected services; no arguments: down, keep volumes.
./dev.sh stop-tunnel  Close local forwards only.
./dev.sh check        Check SSH, rootless Podman and Compose prerequisites.
./dev.sh full-setup   Optional automation entry to full server setup.

Compose: compose.yaml / compose.yml / docker-compose.yaml / docker-compose.yml
beside dev.sh (preferred), otherwise in its parent; PROJECT_DIR selects another root.
COMPOSE_FILE in config/dev.env overrides discovery.
EOF
}
source "$ROOT_DIR/lib/ui.sh"
case "${1:-}" in help|-h|--help) usage; exit 0;; '') menu; exit $?;; full-setup) bash "$ROOT_DIR/setup.sh" full; exit $?;; esac
[[ -f "$CONFIG_FILE" ]] || fail 'Configuration missing. Open ./dev.sh → Server setup.'
PODMAN_HOST='' ROOT_HOST='' SSH_PORT= SSH_KEY='' PROJECT_NAME=myapp
PROJECT_DIR=
REMOTE_BASE=.cache/remote-podman-dev COMPOSE_FILE='' COMPOSE_OVERRIDE='' REMOTE_PORT_OFFSET=10000
REQUIRED_ENDPOINTS_FILE=config/required-endpoints.conf
while IFS='=' read -r key value || [[ -n "${key:-}" ]]; do
    key="${key%$'\r'}"; value="${value%$'\r'}"
  [[ -z "$key" || "$key" == \#* ]] && continue
  case "$key" in
    PROJECT_DIR|PODMAN_HOST|ROOT_HOST|SSH_PORT|SSH_KEY|PROJECT_NAME|REMOTE_BASE|COMPOSE_FILE|COMPOSE_OVERRIDE|REMOTE_PORT_OFFSET|REQUIRED_ENDPOINTS_FILE) printf -v "$key" '%s' "$value";;
    SERVICES_FILE) fail 'Legacy SERVICES_FILE is unsupported. Migrate config using config/dev.env.example and a Compose file.';;
    *) fail "Unknown config setting: $key";;
  esac
done < "$CONFIG_FILE"
[[ "$PODMAN_HOST" =~ ^[a-zA-Z0-9_.@:-]+$ && "$PODMAN_HOST" != -* ]] || fail 'Invalid PODMAN_HOST.'
[[ "$PROJECT_NAME" =~ ^[a-z0-9][a-z0-9_-]{0,39}$ ]] || fail 'PROJECT_NAME must use lowercase letters, digits, _ or -.'
[[ -z "$SSH_PORT" ]] || { [[ "$SSH_PORT" =~ ^[0-9]{1,5}$ ]] && ((10#$SSH_PORT > 0 && 10#$SSH_PORT < 65536)); } || fail 'Invalid SSH_PORT.'
[[ "$REMOTE_PORT_OFFSET" =~ ^[0-9]{1,5}$ ]] || fail 'REMOTE_PORT_OFFSET must be a nonnegative integer.'
[[ "$REMOTE_BASE" =~ ^[a-zA-Z0-9_./-]+$ && "$REMOTE_BASE" != /* && "$REMOTE_BASE" != *..* && "$REMOTE_BASE" != -* ]] || fail 'Unsafe REMOTE_BASE.'
SSH_ARGS=(-o BatchMode=yes -o ConnectTimeout=8 -o ServerAliveInterval=30 -o ServerAliveCountMax=3)
[[ -z "$SSH_PORT" ]] || SSH_ARGS+=(-p "$SSH_PORT")
if [[ -n "$SSH_KEY" ]]; then [[ -f "$SSH_KEY" ]] || fail "SSH key not found: $SSH_KEY"; SSH_ARGS+=(-i "$SSH_KEY"); fi
ssh_to() { ssh "${SSH_ARGS[@]}" "$PODMAN_HOST" "$@"; }
remote_dir="$REMOTE_BASE/$PROJECT_NAME"
lock() { umask 077; mkdir -p "$RUNTIME_DIR"; mkdir "$RUNTIME_DIR/operation.lock" 2>/dev/null || fail 'Another project operation is running (or a stale .runtime/operation.lock remains).'; LOCKED=1; }
check_remote() {
  ssh_to 'test "$(id -u)" != 0 && command -v podman >/dev/null && podman info --format "{{.Host.Security.Rootless}}" | grep -qi true && python3 -c "import yaml" && (command -v docker-compose >/dev/null || docker compose version >/dev/null) && test -S "/run/user/$(id -u)/podman/podman.sock"' || fail 'Remote requirements failed: rootless Podman socket, Python 3 + PyYAML and Compose are required. Use Server setup.'
  ok 'SSH and remote Compose requirements are available.'
}
remote() {
  local action="$1" cmd arg; shift
  cmd="python3 $(quote "$remote_dir/compose_remote.py") $(quote "$action") $(quote "$remote_dir") $(quote "$PROJECT_NAME")"
  for arg in "$@"; do cmd+=" $(quote "$arg")"; done
  ssh_to "$cmd"
}
install_helper() {
  local temporary="$remote_dir/.helper-$$-$RANDOM"
  ssh_to "umask 077; mkdir -p $(quote "$remote_dir") && chmod 700 $(quote "$remote_dir") && cat > $(quote "$temporary") && mv $(quote "$temporary") $(quote "$remote_dir/compose_remote.py")" < "$ROOT_DIR/lib/compose_remote.py" || fail 'Could not transfer the Compose helper.'
}
find_compose() {
  local file candidates=() directory
  if [[ -n "$PROJECT_DIR" ]]; then
    [[ "$PROJECT_DIR" == /* ]] || PROJECT_DIR="$ROOT_DIR/$PROJECT_DIR"
    PROJECT_DIR="$(CDPATH= cd -- "$PROJECT_DIR" && pwd)" || fail 'Invalid PROJECT_DIR.'
  else
    for directory in "$ROOT_DIR" "$(dirname "$ROOT_DIR")"; do
      for file in compose.yaml compose.yml docker-compose.yaml docker-compose.yml; do
        [[ ! -f "$directory/$file" ]] || candidates+=("$file")
      done
      if ((${#candidates[@]})); then PROJECT_DIR="$directory"; break; fi
    done
    [[ -n "$PROJECT_DIR" ]] || PROJECT_DIR="$ROOT_DIR"
  fi
  candidates=()
  if [[ -z "$COMPOSE_FILE" ]]; then
    for file in compose.yaml compose.yml docker-compose.yaml docker-compose.yml; do [[ ! -f "$PROJECT_DIR/$file" ]] || candidates+=("$file"); done
    ((${#candidates[@]} == 1)) || fail 'Put one Compose file beside the kit or in its parent, or set PROJECT_DIR / COMPOSE_FILE explicitly. No fallback to demo services.'
    COMPOSE_FILE="${candidates[0]}"
    if [[ -z "$COMPOSE_OVERRIDE" ]]; then
      candidates=()
      for file in compose.override.yaml compose.override.yml docker-compose.override.yaml docker-compose.override.yml; do [[ ! -f "$PROJECT_DIR/$file" ]] || candidates+=("$file"); done
      ((${#candidates[@]} <= 1)) || fail 'Multiple overrides: set COMPOSE_OVERRIDE explicitly.'
      [[ ${#candidates[@]} == 0 ]] || COMPOSE_OVERRIDE="${candidates[0]}"
    fi
  fi
  COMPOSE_FILES=("$COMPOSE_FILE")
  [[ -z "$COMPOSE_OVERRIDE" ]] || COMPOSE_FILES+=("$COMPOSE_OVERRIDE")
  for file in "${COMPOSE_FILES[@]}"; do
    [[ "$file" =~ ^[a-zA-Z0-9_./-]+$ && "$file" != /* && "$file" != *..* && -f "$PROJECT_DIR/$file" ]] || fail "Invalid Compose path: $file"
  done
  note "Compose source: ${COMPOSE_FILES[*]}"
}
declare -a SERVICE_NAMES=() SERVICE_LPORTS=() SELECTED=() FORWARD_LOCAL=() FORWARD_REMOTE=()
read_report() {
  SERVICE_NAMES=(); SERVICE_LPORTS=(); FORWARD_LOCAL=(); FORWARD_REMOTE=()
  local kind name first second
  while IFS=$'\t' read -r kind name first second; do
    case "$kind" in
      S) [[ "$name" =~ ^[a-zA-Z0-9][a-zA-Z0-9_.-]{0,63}$ ]] || fail 'Invalid remote service name.'; SERVICE_NAMES+=("$name"); SERVICE_LPORTS+=("$first");;
      P) [[ "$first" =~ ^[0-9]+$ && "$second" =~ ^[0-9]+$ ]] || fail 'Invalid port report.'; FORWARD_LOCAL+=("$first"); FORWARD_REMOTE+=("$second");;
      '') ;;
      *) fail 'Unexpected Compose report.';;
    esac
  done < "$RUNTIME_DIR/report"
}
prepare() {
  find_compose
  check_remote
  install_helper
  snapshot="$remote_dir/snapshots/$(date +%s)-$$"
  ssh_to "umask 077; mkdir -p $(quote "$snapshot")" || fail 'Cannot create remote snapshot.'
  local exclusions=()
  [[ ! -f "$PROJECT_DIR/.devkitignore" ]] || exclusions=(-X "$PROJECT_DIR/.devkitignore")
  note 'Uploading project snapshot over SSH (includes .env and Compose env files).'
  local kit_relative="${ROOT_DIR#"$PROJECT_DIR"/}"
  if [[ "$ROOT_DIR" == "$PROJECT_DIR" ]]; then kit_relative=.; fi
  exclusions+=(--exclude="$kit_relative/config/dev.env" --exclude="$kit_relative/.runtime")
  COPYFILE_DISABLE=1 tar -C "$PROJECT_DIR" --exclude=.git --exclude=.runtime --exclude=config/dev.env --exclude=./config/dev.env --exclude=node_modules --exclude=bin --exclude=obj --exclude=__pycache__ "${exclusions[@]}" -cf - . |
    ssh_to "umask 077; tar -xf - -C $(quote "$snapshot") && chmod 700 $(quote "$snapshot")" || fail 'Source transfer failed.'
  remote prepare "$snapshot" "$REMOTE_PORT_OFFSET" "${COMPOSE_FILES[@]}" > "$RUNTIME_DIR/report" || fail 'Compose validation failed; no containers started.'
  read_report
}
select_services() {
  if [[ $# == 0 && -t 0 ]]; then ui_select_services; return $?; fi
  local input="${1:-}" item found name
  [[ -n "$input" ]] || fail 'Specify services, or open the interactive menu.'
  SELECTED=()
  if [[ "$input" == a ]]; then SELECTED=("${SERVICE_NAMES[@]}"); return; fi
  local items=(); IFS=',' read -r -a items <<< "$input"
  for item in "${items[@]}"; do
    found=0
    for name in "${SERVICE_NAMES[@]}"; do [[ "$item" != "$name" ]] || found=1; done
    ((found)) || fail "Unknown Compose service: $item"
    SELECTED+=("$item")
  done
}
stop_tunnel() {
  [[ -f "$TUNNEL_PID_FILE" ]] || { note 'No saved tunnel.'; return; }
  local pid token args; { IFS= read -r pid; IFS= read -r token; } < "$TUNNEL_PID_FILE"
  if [[ "$pid" =~ ^[0-9]+$ ]] && kill -0 "$pid" 2>/dev/null; then
    args="$(ps -p "$pid" -o args= 2>/dev/null)"
    [[ -n "$token" && "$args" == *ssh* && "$args" == *"DEVKIT_TUNNEL=$token"* ]] || fail 'Tunnel process identity does not match; refusing to kill it.'
    kill "$pid" || fail 'Could not close the tunnel.'
  fi
  rm -f "$TUNNEL_PID_FILE"
  ok 'Local tunnel closed.'
}
open_tunnel() {
  ((${#FORWARD_LOCAL[@]})) || { note 'Selected services have no published ports; no tunnel needed.'; return; }
  local i args=() token="$PROJECT_NAME-$$-$(date +%s)"
  for ((i=0; i<${#FORWARD_LOCAL[@]}; i++)); do args+=(-L "127.0.0.1:${FORWARD_LOCAL[i]}:127.0.0.1:${FORWARD_REMOTE[i]}"); done
  nohup ssh "${SSH_ARGS[@]}" -N -o ExitOnForwardFailure=yes -o "SetEnv=DEVKIT_TUNNEL=$token" "${args[@]}" "$PODMAN_HOST" </dev/null >"$RUNTIME_DIR/tunnel.log" 2>&1 &
  TUNNEL_PID=$!
  sleep 1
  kill -0 "$TUNNEL_PID" 2>/dev/null || fail 'Tunnel failed; containers may be running. See .runtime/tunnel.log and use Status/Stop from the menu.'
  printf '%s\n%s\n' "$TUNNEL_PID" "$token" > "$TUNNEL_PID_FILE"
  TUNNEL_PID=''
  for i in "${FORWARD_LOCAL[@]}"; do ok "Forward ready: 127.0.0.1:$i"; done
}
case "$1" in
  start)
    shift; lock
    [[ ! -f "$TUNNEL_PID_FILE" ]] || fail 'Close the existing tunnel before starting services.'
    prepare
    select_services "$@" || { note 'Cancelled.'; exit 0; }
    remote plan "$snapshot" "${SELECTED[@]}" > "$RUNTIME_DIR/report" || fail 'Could not resolve service dependencies.'
    read_report
    for port in "${FORWARD_LOCAL[@]}"; do
      if command -v nc >/dev/null 2>&1 && nc -z 127.0.0.1 "$port" >/dev/null 2>&1; then fail "Local port $port is occupied."; fi
    done
    remote up "$snapshot" "${SELECTED[@]}" || fail 'Compose startup failed; use Status or Stop all to inspect/clean up a partial start.'
    open_tunnel;;
  status)
    lock; install_helper; remote status || exit $?
    if [[ -f "$TUNNEL_PID_FILE" ]]; then
      IFS= read -r pid < "$TUNNEL_PID_FILE"
      note "Local tunnel record: PID $pid (Close tunnel only validates identity before stopping)."
    else note 'No local tunnel recorded.'; fi;;
  stop|stop-selected)
    action="$1"; shift; lock; install_helper
    if [[ "$action" == stop-selected || $# -gt 0 ]]; then
      remote active-services > "$RUNTIME_DIR/report" || exit $?; read_report
      ((${#SERVICE_NAMES[@]})) || { note 'No active services.'; exit 0; }
      select_services "$@" || { note 'Cancelled.'; exit 0; }
    fi
    stop_tunnel; remote stop "${SELECTED[@]}" || exit $?;;
  stop-tunnel) lock; stop_tunnel;;
  check) check_remote;;
  *) usage >&2; exit 2;;
esac
