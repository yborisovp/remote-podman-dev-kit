#!/usr/bin/env bash
set -u
ROOT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
CONFIG_FILE="$ROOT_DIR/config/dev.env"
EXAMPLE_FILE="$ROOT_DIR/config/dev.env.example"

fail() { printf '✗ %s\n' "$*" >&2; exit 1; }
note() { printf '• %s\n' "$*"; }
ok() { printf '✓ %s\n' "$*"; }
quote() { local text=${1//\'/\'\\\'\'}; printf "'%s'" "$text"; }
valid_host() { [[ "$1" =~ ^[a-zA-Z0-9_.@:-]+$ && "$1" != -* ]]; }
valid_username() { [[ "$1" =~ ^[a-z_][a-z0-9_-]{0,31}$ && "$1" != root ]]; }

for tool in ssh ssh-keygen; do command -v "$tool" >/dev/null 2>&1 || fail "Required local tool is missing: $tool (OpenSSH is included with macOS and Git for Windows)."; done
source "$ROOT_DIR/lib/ui.sh"
ui_ensure_config || fail "Cannot create project configuration."

read_config() {
  PODMAN_HOST=; ROOT_HOST=; SSH_PORT=; SSH_KEY=; PROJECT_NAME=myapp
  REMOTE_BASE=.cache/remote-podman-dev; COMPOSE_FILE=; COMPOSE_OVERRIDE=; REMOTE_PORT_OFFSET=10000
  REQUIRED_ENDPOINTS_FILE=config/required-endpoints.conf
  local key value
  while IFS='=' read -r key value || [[ -n "${key:-}" ]]; do
    key="${key%$'\r'}"; value="${value%$'\r'}"
    case "${key:-}" in
      PODMAN_HOST) PODMAN_HOST="$value";; ROOT_HOST) ROOT_HOST="$value";; SSH_PORT) SSH_PORT="$value";;
      SSH_KEY) SSH_KEY="$value";; PROJECT_NAME) PROJECT_NAME="$value";; REMOTE_BASE) REMOTE_BASE="$value";;
      PROJECT_DIR) PROJECT_DIR="$value";; COMPOSE_FILE) COMPOSE_FILE="$value";; COMPOSE_OVERRIDE) COMPOSE_OVERRIDE="$value";; REMOTE_PORT_OFFSET) REMOTE_PORT_OFFSET="$value";; REQUIRED_ENDPOINTS_FILE) REQUIRED_ENDPOINTS_FILE="$value";;
      ''|\#*) ;;
      SERVICES_FILE) fail "Legacy config: replace SERVICES_FILE with COMPOSE_FILE using config/dev.env.example.";;
      *) fail "Unknown config key: $key";;
    esac
  done < "$CONFIG_FILE"
}

save_config() {
  local host="$1" root_host="$2" key_path="$3" tmp_config="$CONFIG_FILE.tmp.$$"
  awk -F= -v host="$host" -v root="$root_host" -v key="$key_path" '
    BEGIN { seen_host=0; seen_root=0; seen_key=0 }
    /^PODMAN_HOST=/ { print "PODMAN_HOST=" host; seen_host=1; next }
    /^ROOT_HOST=/ { print "ROOT_HOST=" root; seen_root=1; next }
    /^SSH_KEY=/ { print "SSH_KEY=" key; seen_key=1; next }
    { print }
    END { if (!seen_host) print "PODMAN_HOST=" host; if (!seen_root) print "ROOT_HOST=" root; if (!seen_key) print "SSH_KEY=" key }
  ' "$CONFIG_FILE" > "$tmp_config" || fail 'Could not update config/dev.env.'
  mv "$tmp_config" "$CONFIG_FILE"
}

ensure_key() {
  if [[ -z "$SSH_KEY" ]]; then SSH_KEY="$HOME/.ssh/id_ed25519_podman_$PROJECT_NAME"; fi
  mkdir -p "$HOME/.ssh" "$(dirname -- "$SSH_KEY")"
  chmod 700 "$HOME/.ssh" 2>/dev/null || true
  if [[ ! -f "$SSH_KEY" ]]; then
    note "Creating a project SSH key at $SSH_KEY. Choose a passphrase; it will not be saved here."
    ssh-keygen -t ed25519 -a 64 -f "$SSH_KEY" -C "remote-podman-$PROJECT_NAME" || fail 'SSH key creation failed.'
    chmod 600 "$SSH_KEY" 2>/dev/null || true
    chmod 644 "$SSH_KEY.pub" 2>/dev/null || true
  fi
  [[ -f "$SSH_KEY.pub" ]] || fail "Public key not found beside private key: $SSH_KEY.pub"
  PUBLIC_KEY="$(cat "$SSH_KEY.pub")"
  [[ "$PUBLIC_KEY" =~ ^ssh-ed25519[[:space:]][A-Za-z0-9+/=]+([[:space:]][A-Za-z0-9_.@-]+)?$ ]] || fail 'The public key file has an unexpected format.'
}

install_for_existing_user() {
  local host="$1"
  valid_host "$host" || fail 'Set a valid PODMAN_HOST or pass user@host.'
  save_config "$host" "$ROOT_HOST" "$SSH_KEY"
  local -a account_args=(-o ConnectTimeout=10 -o StrictHostKeyChecking=ask -t)
  [[ -z "$SSH_PORT" ]] || account_args+=(-p "$SSH_PORT")
  [[ -z "$SSH_KEY" ]] || account_args+=(-i "$SSH_KEY")
  note 'Checking Linux Podman installation and enabling the rootless user socket.'
  ssh "${account_args[@]}" "$host" \
    'python3 -c "import yaml" || { echo "Install python3-yaml on Linux" >&2; exit 1; }; (command -v docker-compose >/dev/null || docker compose version >/dev/null) || { echo "Install a Compose provider on Linux" >&2; exit 1; }; command -v podman >/dev/null || { echo "Install Podman on Linux first; see README.md" >&2; exit 1; }; systemctl --user enable --now podman.socket && podman info --format "{{.Host.Security.Rootless}}" | grep -qi true || exit 1; if command -v loginctl >/dev/null && ! loginctl show-user "$USER" -p Linger --value 2>/dev/null | grep -qi yes; then echo "Enabling linger may ask for sudo access."; sudo loginctl enable-linger "$USER" || exit 1; fi' || fail 'Linux setup did not complete. See README.md.'
  ok 'SSH access and rootless Podman are configured.'
  note 'Review config/dev.env, then run ./dev.sh check.'
}

full_setup() {
  read_config
  [[ -z "$SSH_PORT" ]] || { [[ "$SSH_PORT" =~ ^[0-9]+$ ]] && ((10#$SSH_PORT > 0 && 10#$SSH_PORT < 65536)); } || fail 'SSH_PORT must be between 1 and 65535.'
  [[ "$PROJECT_NAME" =~ ^[a-zA-Z0-9][a-zA-Z0-9_-]{0,39}$ ]] || fail 'Invalid PROJECT_NAME in config/dev.env.'

  local root_host host_part local_user username candidate endpoint_file image registry endpoint_blob=''
  root_host="$ROOT_HOST"
  if [[ -z "$root_host" ]]; then
    printf 'Administrative SSH target (user@host or SSH alias; sudo supported): '
    IFS= read -r root_host || fail 'No administrative SSH target entered.'
  fi
  valid_host "$root_host" || fail 'ROOT_HOST must be an SSH alias or user@host using letters, digits, ., _, @, :, and -.'

  local_user="$(id -un 2>/dev/null || true)"
  valid_username "$local_user" || local_user=developer
  if [[ -d /c/Users ]]; then
    note 'Windows profile folders (optional username suggestions):'
    for path in /c/Users/*; do [[ -d "$path" ]] && printf '  %s\n' "${path##*/}"; done
  fi
  printf 'Linux project username [%s]: ' "$local_user"
  IFS= read -r candidate || fail 'Could not read a Linux username.'
  username="$(printf '%s' "${candidate:-$local_user}" | tr '[:upper:]' '[:lower:]')"
  valid_username "$username" || fail 'Use a Linux username with lowercase letters, digits, _ or -, starting with a letter or _; root is reserved.'

  endpoint_file="$ROOT_DIR/$REQUIRED_ENDPOINTS_FILE"
  [[ "$REQUIRED_ENDPOINTS_FILE" =~ ^[a-zA-Z0-9_./-]+$ && "$REQUIRED_ENDPOINTS_FILE" != /* && "$REQUIRED_ENDPOINTS_FILE" != *..* ]] || fail 'REQUIRED_ENDPOINTS_FILE must be a safe relative path.'
  [[ -r "$endpoint_file" ]] || fail "Required endpoint file not found: $REQUIRED_ENDPOINTS_FILE"
  local line_host line_port line_description line_number=0
  local -a endpoint_hosts=() endpoint_ports=()
  while IFS='|' read -r line_host line_port line_description || [[ -n "${line_host:-}" ]]; do
    line_number=$((line_number + 1))
    [[ -z "${line_host:-}" || "$line_host" == \#* ]] && continue
    [[ "$line_host" =~ ^[a-zA-Z0-9][a-zA-Z0-9.-]*$ && "$line_port" =~ ^[0-9]+$ ]] || fail "Invalid required endpoint on line $line_number."
    ((10#$line_port > 0 && 10#$line_port < 65536)) || fail "Invalid port on endpoint line $line_number."
    endpoint_hosts+=("$line_host"); endpoint_ports+=("$line_port")
  done < "$endpoint_file"

  ((${#endpoint_hosts[@]} > 0)) || fail 'No required network endpoints are configured.'
  for i in "${!endpoint_hosts[@]}"; do
    printf '  Required TCP endpoint: %s:%s\n' "${endpoint_hosts[i]}" "${endpoint_ports[i]}"
    [[ -z "$endpoint_blob" ]] || endpoint_blob+=','
    endpoint_blob+="${endpoint_hosts[i]}:${endpoint_ports[i]}"
  done

  ensure_key
  printf '\nFull setup will use administrative access at %s (port: %s) and create/use Linux user %s.\n' "$root_host" "${SSH_PORT:-SSH config}" "$username"
  printf 'It checks required TCP endpoints, installs missing Podman/Docker/Compose packages on Debian or Ubuntu, creates the rootless user, installs this SSH public key, and enables linger. Docker Engine runs as root; the project user is not added to the docker group.\n'
  printf 'Continue? [y/N] '
  local answer; IFS= read -r answer || fail 'Could not read confirmation.'
  [[ "$answer" == y || "$answer" == Y || "$answer" == yes || "$answer" == YES ]] || { note 'Full setup cancelled; no server changes were made.'; return 0; }

  local remote_script remote_command
  remote_script=$(cat <<'REMOTE_SCRIPT'
set -euo pipefail
dev_user="$1"
pubkey="$2"
endpoints="$3"
[[ "$(id -u)" == 0 ]] || { echo 'Full setup requires root privileges through sudo or root login.' >&2; exit 10; }
. /etc/os-release
os_family="${ID:-} ${ID_LIKE:-}"
if [[ "$os_family" != *debian* && "$os_family" != *ubuntu* ]]; then
  echo "Unsupported distribution: ${PRETTY_NAME:-unknown}. Full setup supports Debian/Ubuntu with apt-get." >&2
  exit 11
fi

IFS=',' read -r -a endpoint_array <<< "$endpoints"
for endpoint in "${endpoint_array[@]}"; do
  host="${endpoint%:*}"; port="${endpoint##*:}"
  printf 'Checking required TCP endpoint %s:%s ... ' "$host" "$port"
  if command -v nc >/dev/null 2>&1; then
    nc -z -w 5 "$host" "$port" >/dev/null 2>&1 || { echo 'FAILED'; exit 20; }
  elif command -v timeout >/dev/null 2>&1 && command -v bash >/dev/null 2>&1; then
    timeout 6 bash -c ":</dev/tcp/$host/$port" >/dev/null 2>&1 || { echo 'FAILED'; exit 20; }
  else
    echo 'cannot check (install netcat-openbsd or coreutils timeout)' >&2; exit 21
  fi
  echo 'OK'
done

packages=()
for package in uidmap slirp4netns fuse-overlayfs dbus-user-session python3 python3-yaml; do
  dpkg-query -W -f='${Status}' "$package" 2>/dev/null | grep -q 'install ok installed' || packages+=("$package")
done
if command -v podman >/dev/null 2>&1; then echo 'Podman: already installed'; else echo 'Podman: missing'; packages+=(podman uidmap slirp4netns fuse-overlayfs dbus-user-session); fi
if command -v docker >/dev/null 2>&1 && systemctl cat docker.service >/dev/null 2>&1; then echo 'Docker Engine: already installed'; else echo 'Docker Engine: missing'; packages+=(docker.io)
fi
if command -v docker-compose >/dev/null 2>&1 || docker compose version >/dev/null 2>&1; then echo 'Docker Compose: already installed'; else echo 'Docker Compose: missing'; packages+=(docker-compose)
fi
if ((${#packages[@]})); then
  printf 'Installing missing packages: %s\n' "${packages[*]}"
  export DEBIAN_FRONTEND=noninteractive
  apt-get update
  apt-get install -y "${packages[@]}" netcat-openbsd
fi

command -v podman >/dev/null 2>&1 || { echo 'Podman installation did not provide podman.' >&2; exit 30; }
command -v docker >/dev/null 2>&1 || { echo 'Docker installation did not provide docker.' >&2; exit 31; }
if ! command -v docker-compose >/dev/null 2>&1 && ! docker compose version >/dev/null 2>&1; then echo 'Docker Compose is unavailable.' >&2; exit 32; fi
if systemctl cat docker.service >/dev/null 2>&1; then systemctl enable --now docker.service; fi

if ! id "$dev_user" >/dev/null 2>&1; then useradd --create-home --shell /bin/bash "$dev_user"; fi
usermod --shell /bin/bash "$dev_user"
ensure_subid_range() {
  file="$1" option="$2"
  touch "$file"
  if awk -F: -v name="$dev_user" '$1 == name && $3 >= 65536 { found=1 } END { exit !found }' "$file"; then return; fi
  start="$(awk -F: 'NF >= 3 { end=$2+$3; if (end>max) max=end } END { if (max<100000) print 100000; else print max+1 }' "$file")"
  end=$((start + 65535))
  usermod "$option" "$start-$end" "$dev_user"
}
ensure_subid_range /etc/subuid --add-subuids
ensure_subid_range /etc/subgid --add-subgids

home="$(getent passwd "$dev_user" | cut -d: -f6)"
[[ -n "$home" && -d "$home" && ! -L "$home" ]] || { echo "Home directory is missing or is a symlink for $dev_user." >&2; exit 40; }
[[ ! -L "$home/.ssh" && ! -L "$home/.ssh/authorized_keys" ]] || { echo "Refusing to follow an SSH directory or authorized_keys symlink for $dev_user." >&2; exit 41; }
install -d -m 700 -o "$dev_user" -g "$(id -gn "$dev_user")" "$home/.ssh"
touch "$home/.ssh/authorized_keys"
grep -qxF "$pubkey" "$home/.ssh/authorized_keys" || printf '%s\n' "$pubkey" >> "$home/.ssh/authorized_keys"
chown "$dev_user:$(id -gn "$dev_user")" "$home/.ssh/authorized_keys"
chmod 600 "$home/.ssh/authorized_keys"
loginctl enable-linger "$dev_user"
printf 'Prepared rootless account %s (no password set; SSH public-key access installed).\n' "$dev_user"
REMOTE_SCRIPT
)
  remote_command="bash -c $(quote "$remote_script") -- $(quote "$username") $(quote "$PUBLIC_KEY") $(quote "$endpoint_blob")"
  # Keep stdin attached to the remote terminal so sudo can ask for a password.
  remote_command="if [ \"\$(id -u)\" = 0 ]; then $remote_command; else sudo -- $remote_command; fi"
  note "Connecting to $root_host using SSH configuration. SSH and sudo may ask for credentials; they are never saved."
  local -a root_ssh_args=(-o ConnectTimeout=10 -o StrictHostKeyChecking=ask -tt)
  [[ -z "$SSH_PORT" ]] || root_ssh_args+=(-p "$SSH_PORT")
  ssh "${root_ssh_args[@]}" "$root_host" "$remote_command" || fail 'Full server setup failed. Check SSH access, sudo permission and the remote error above.'

  host_part="${root_host#*@}"
  PODMAN_HOST="$username@$host_part"
  save_config "$PODMAN_HOST" "$root_host" "$SSH_KEY"
  note 'Checking the new project account and enabling its rootless Podman user socket.'
  ssh "${root_ssh_args[@]}" -i "$SSH_KEY" "$PODMAN_HOST" \
    'systemctl --user enable --now podman.socket && podman info --format "{{.Host.Security.Rootless}}" | grep -qi true' || fail 'The account was prepared, but the rootless Podman check failed. Review Linux user-session and linger setup.'
  ok "Full setup finished. PODMAN_HOST is now $PODMAN_HOST."
  note 'Run ./dev.sh check, then choose services with ./dev.sh.'
}

read_config
[[ -z "$SSH_PORT" ]] || { [[ "$SSH_PORT" =~ ^[0-9]{1,5}$ ]] && ((10#$SSH_PORT > 0 && 10#$SSH_PORT < 65536)); } || fail "Invalid SSH_PORT."
[[ "$PROJECT_NAME" =~ ^[a-z0-9][a-z0-9_-]{0,39}$ ]] || fail "Invalid PROJECT_NAME: use lowercase letters, digits, _ or -."
action="${1:-setup}"
case "$action" in
  full|full-setup)
    full_setup
    ;;
  setup)
    target="${2:-$PODMAN_HOST}"
    [[ -n "$target" ]] || fail 'Usage: ./setup.sh [setup] user@linux-host | ./setup.sh full'
    install_for_existing_user "$target"
    ;;
  help|-h|--help)
    printf 'Usage: ./setup.sh [setup] user@linux-host\n       ./setup.sh full  # create a rootless project user on Debian/Ubuntu\n'
    ;;
  *@*) install_for_existing_user "$action";;
  *) fail "Unknown setup mode: $action. Use setup or full.";;
esac
