#!/usr/bin/env bash
set -euo pipefail
KIT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/remote-compose-smoke.XXXXXX")"
cleanup() {
  if [[ -f "$TMP_DIR/project/.runtime/tunnel.pid" ]]; then
    read -r pid < "$TMP_DIR/project/.runtime/tunnel.pid"
    kill "$pid" 2>/dev/null || true
  fi
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT
cp -R "$KIT_DIR" "$TMP_DIR/project"
mkdir -p "$TMP_DIR/bin" "$TMP_DIR/remote" "$TMP_DIR/home"
cp "$KIT_DIR/config/dev.env.example" "$TMP_DIR/project/config/dev.env"
printf '\nPODMAN_HOST=mock-host\nPROJECT_NAME=smoke\n' >> "$TMP_DIR/project/config/dev.env"
printf 'services: {}\n' > "$TMP_DIR/project/docker-compose.yml"
cat > "$TMP_DIR/bin/ssh" <<'MOCK'
#!/usr/bin/env bash
raw="$*"
tunnel=0
while (($#)); do
  case "$1" in
    -p|-i|-o|-L) shift 2;;
    -N) tunnel=1; shift;;
    -*) shift;;
    *) shift; break;;
  esac
done
printf '%s\n' "$*" >> "$MOCK_SSH_LOG"
if ((tunnel)); then printf '%s\n' "$raw" > "$MOCK_TUNNEL_ARGS"; exec -a ssh sleep 60; fi
case "$*" in
  *'podman info'*|*'apt-get install'*) printf 'true\n'; exit 0;;
esac
cd "$MOCK_REMOTE" || exit 1
bash -c "$*"
MOCK
cat > "$TMP_DIR/bin/docker-compose" <<'MOCK'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$MOCK_COMPOSE_LOG"
case " $* " in
  *' config --help '*) printf '%s\n' '--format';;
  *' config --format json '*) python3 - <<'PY'
import json, os
print(json.dumps({'services': {
 'worker': {'build': {'context': os.getcwd()}, 'depends_on': {'database': {'condition': 'service_started'}}, 'ports':[{'target':8000,'published':'45011'},{'target':8001,'published':'45012'}]},
 'database': {'build': {'context': os.getcwd()}, 'ports':[{'target':5432,'published':'45013'}]},
 'headless': {'build': {'context': os.getcwd()}}
}, 'volumes': {'data': {}}}))
PY
    ;;
  *) printf 'mock compose operation complete\n';;
esac
MOCK
cat > "$TMP_DIR/bin/ps" <<'MOCK'
#!/usr/bin/env bash
printf 'ssh %s\n' "$(cat "$MOCK_TUNNEL_ARGS")"
MOCK
cat > "$TMP_DIR/bin/ssh-keygen" <<'MOCK'
#!/usr/bin/env bash
while (($#)); do case "$1" in -f) key="$2"; shift 2;; *) shift;; esac; done
mkdir -p "$(dirname "$key")"
printf 'fixture\n' > "$key"
printf 'ssh-ed25519 AAAATEST fixture\n' > "$key.pub"
MOCK
printf '#!/usr/bin/env bash\nexit 0\n' > "$TMP_DIR/bin/ssh-copy-id"
chmod +x "$TMP_DIR/bin/"*
export PATH="$TMP_DIR/bin:$PATH" HOME="$TMP_DIR/home"
export MOCK_SSH_LOG="$TMP_DIR/ssh.log" MOCK_REMOTE="$TMP_DIR/remote" MOCK_COMPOSE_LOG="$TMP_DIR/compose.log" MOCK_TUNNEL_ARGS="$TMP_DIR/tunnel.args"
for file in dev.sh setup.sh lib/ui.sh tests/smoke.sh; do bash -n "$TMP_DIR/project/$file"; done
sed -n '/^set -euo pipefail$/,/^REMOTE_SCRIPT$/p' "$TMP_DIR/project/setup.sh" | sed '$d' | bash -n
bash "$TMP_DIR/project/dev.sh" check >/dev/null
cp "$TMP_DIR/project/docker-compose.yml" "$TMP_DIR/project/compose.yaml"
if bash "$TMP_DIR/project/dev.sh" start a >/dev/null 2>&1; then printf 'Ambiguous Compose accepted\n' >&2; exit 1; fi
rm "$TMP_DIR/project/compose.yaml"
bash "$TMP_DIR/project/dev.sh" start worker >/dev/null
python3 - "$MOCK_REMOTE" <<'PY'
import json, pathlib, sys
root=pathlib.Path(sys.argv[1]) / '.cache/remote-podman-dev/smoke'
state=json.loads((root/'active.json').read_text())
assert state['selected']==['worker','database']
assert len(state['ports'])==3
for svc in state['model']['services'].values():
 for p in svc.get('ports',[]): assert p['host_ip']=='127.0.0.1'
workspace=pathlib.Path(state['workspace'])
assert not (workspace/'config/dev.env').exists()
assert (workspace/'docker-compose.yml').exists()
assert root.stat().st_mode & 0o777 == 0o700
assert workspace.stat().st_mode & 0o777 == 0o700
PY
grep -q -- '127.0.0.1:45012:127.0.0.1:55012' "$MOCK_TUNNEL_ARGS"
grep -q -- '127.0.0.1:45013:127.0.0.1:55013' "$MOCK_TUNNEL_ARGS"
bash "$TMP_DIR/project/dev.sh" status >/dev/null
bash "$TMP_DIR/project/dev.sh" stop >/dev/null
[[ ! -f "$TMP_DIR/project/.runtime/tunnel.pid" ]]
grep -q -- 'down' "$MOCK_COMPOSE_LOG"
if bash "$TMP_DIR/project/dev.sh" start missing >/dev/null 2>&1; then printf 'Unknown service accepted\n' >&2; exit 1; fi
rm "$TMP_DIR/project/docker-compose.yml"
if bash "$TMP_DIR/project/dev.sh" start a >/dev/null 2>&1; then printf 'Missing Compose accepted\n' >&2; exit 1; fi
bash "$TMP_DIR/project/setup.sh" developer@mock-host >/dev/null
printf 'developer\ny\n' | bash "$TMP_DIR/project/setup.sh" full >/dev/null
grep -q 'python3-yaml' "$MOCK_SSH_LOG"
printf 'PASS: Compose discovery, real remote adapter with mocked provider, dependencies, multiple ports, source transfer, tunnels, status/stop and setup\n'
