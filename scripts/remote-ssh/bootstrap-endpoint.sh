#!/usr/bin/env bash
# bootstrap-endpoint.sh
#
# Provision any Linux box (Vultr / AWS / Azure / GCP / a bare container) as a
# masc remote_ssh endpoint, using only ssh + scp. The script drives the exact
# contract the server's preflight enforces (perform_preflight in
# lib/keeper/keeper_sandbox_ssh.ml):
#
#   1. masc-exec-shim on PATH        (static binary, arch picked by uname -m)
#   2. /etc/masc-exec-shim.conf      (remote_root=<abs path>)
#   3. <remote_root>/<keeper>/       (one directory per keeper)
#   4. <keeper>/.config/gh identity  (copied from the local keeper bundle)
#   5. git available                 (gh too, for the identity preflight)
#
# plus the local half: endpoint keypair, pinned host key, and the
# runtime.toml [exec.ssh.endpoints.<name>] block (printed; --write-config
# appends it).
#
# The provisioning connection uses the operator's EXISTING ssh access (cloud
# vendors hand out root/key access at instance creation). The endpoint's own
# key is generated locally and installed into authorized_keys, then every
# verification step runs over that key with BatchMode and the pinned host key
# — the same connection shape the server will use.
#
# Usage:
#   scripts/remote-ssh/bootstrap-endpoint.sh \
#     --name build-box --host 203.0.113.7 --user masc \
#     [--port 22] [--remote-root /opt/masc-playground] \
#     [--keeper rondo]... [--shim-dist dist/remote-ssh] \
#     [--base-path ~/me] [--write-config]
#
# Idempotent: every remote step is a no-op when its outcome is already in
# place, so re-running after a partial failure is safe.
set -euo pipefail

NAME="" HOST="" USER_NAME="" PORT=22
REMOTE_ROOT="/opt/masc-playground"
SHIM_DIST="dist/remote-ssh"
BASE_PATH="${MASC_BASE_PATH:-$HOME/me}"
WRITE_CONFIG=0
KEEPERS=()

usage() {
  sed -n '2,40p' "$0" | sed 's/^# \{0,1\}//'
  exit 2
}

while [ $# -gt 0 ]; do
  case "$1" in
    --name) shift; NAME="${1:?}" ;;
    --host) shift; HOST="${1:?}" ;;
    --user) shift; USER_NAME="${1:?}" ;;
    --port) shift; PORT="${1:?}" ;;
    --remote-root) shift; REMOTE_ROOT="${1:?}" ;;
    --keeper) shift; KEEPERS+=("${1:?}") ;;
    --shim-dist) shift; SHIM_DIST="${1:?}" ;;
    --base-path) shift; BASE_PATH="${1:?}" ;;
    --write-config) WRITE_CONFIG=1 ;;
    -h | --help) usage ;;
    *) echo "unknown argument: $1" >&2; usage ;;
  esac
  shift
done

[ -n "$NAME" ] && [ -n "$HOST" ] && [ -n "$USER_NAME" ] || usage
case "$REMOTE_ROOT" in
  /*) ;;
  *) echo "--remote-root must be absolute, got: $REMOTE_ROOT" >&2; exit 2 ;;
esac

repo_root="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
key_file="$BASE_PATH/.masc/ssh/$NAME.key"
known_hosts="$BASE_PATH/.masc/ssh/known_hosts.d/$NAME"
runtime_toml="$BASE_PATH/.masc/config/runtime.toml"

# Operator connection: whatever ssh access already exists for this box.
# accept-new keeps the first contact non-interactive; the security pin lives
# on the endpoint connection below, which only trusts the scanned host key.
op_ssh() { ssh -p "$PORT" -o StrictHostKeyChecking=accept-new "$USER_NAME@$HOST" "$@"; }
op_scp() { scp -q -P "$PORT" -o StrictHostKeyChecking=accept-new "$1" "$USER_NAME@$HOST:$2"; }

# Endpoint connection: the exact shape the server uses (key + pinned host
# key + BatchMode), so passing here means the server's dispatch will too.
ep_ssh() {
  ssh -p "$PORT" -i "$key_file" -o IdentitiesOnly=yes -o BatchMode=yes \
    -o StrictHostKeyChecking=yes -o "UserKnownHostsFile=$known_hosts" \
    "$USER_NAME@$HOST" "$@"
}

# Remote privilege: root runs things directly, anyone else needs sudo for
# /usr/local/bin and /etc.
SUDO=""
if [ "$(op_ssh 'id -u')" != "0" ]; then
  if op_ssh 'sudo -n true' 2>/dev/null; then
    SUDO="sudo"
  else
    echo "[bootstrap] $USER_NAME cannot sudo non-interactively; shim/conf installation needs root" >&2
    exit 1
  fi
fi

step() { printf '[bootstrap] %s\n' "$*" >&2; }

# --- 0. local endpoint key -------------------------------------------------
if [ ! -f "$key_file" ]; then
  step "generating endpoint key $key_file"
  mkdir -p "$(dirname "$key_file")"
  ssh-keygen -q -t ed25519 -N "" -C "masc-$NAME" -f "$key_file"
fi

# --- 1. authorized_keys ----------------------------------------------------
pub="$(cat "$key_file.pub")"
op_ssh "mkdir -p ~/.ssh && chmod 700 ~/.ssh && touch ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys && grep -qxF '$pub' ~/.ssh/authorized_keys || echo '$pub' >> ~/.ssh/authorized_keys"
step "endpoint key authorized"

# --- 2. pinned host key ----------------------------------------------------
if [ ! -s "$known_hosts" ]; then
  step "pinning host key into $known_hosts"
  mkdir -p "$(dirname "$known_hosts")"
  ssh-keyscan -p "$PORT" -t ed25519 "$HOST" > "$known_hosts" 2>/dev/null
  [ -s "$known_hosts" ] || { echo "ssh-keyscan returned nothing for $HOST:$PORT" >&2; exit 1; }
fi

# --- 3. packages: git + gh -------------------------------------------------
step "ensuring git and gh"
op_ssh "$SUDO sh -c '
  set -e
  need() { ! command -v \"\$1\" >/dev/null 2>&1; }
  if need git || need gh; then
    if command -v apt-get >/dev/null; then apt-get update -qq && apt-get install -y -qq git gh
    elif command -v dnf >/dev/null; then dnf install -y -q git gh || dnf install -y -q git
    elif command -v apk >/dev/null; then apk add -q git github-cli
    elif command -v zypper >/dev/null; then zypper -q install -y git gh
    else echo \"no known package manager; install git and gh manually\" >&2; exit 1
    fi
  fi
  command -v gh >/dev/null 2>&1 || { echo \"gh not installable from base repos; add the GitHub CLI repo for this distro and re-run\" >&2; exit 1; }
'"

# --- 4. shim binary --------------------------------------------------------
arch="$(op_ssh 'uname -m')"
case "$arch" in
  x86_64) shim_src="$repo_root/$SHIM_DIST/masc-exec-shim-linux-amd64" ;;
  aarch64 | arm64) shim_src="$repo_root/$SHIM_DIST/masc-exec-shim-linux-arm64" ;;
  *) echo "unsupported remote architecture: $arch" >&2; exit 1 ;;
esac
[ -f "$shim_src" ] || { echo "missing $shim_src — run scripts/remote-ssh/build-shim.sh first" >&2; exit 1; }
local_sha="$(shasum -a 256 "$shim_src" | cut -d' ' -f1)"
remote_sha="$(op_ssh 'sha256sum /usr/local/bin/masc-exec-shim 2>/dev/null | cut -d" " -f1' || true)"
if [ "$local_sha" != "$remote_sha" ]; then
  step "installing masc-exec-shim ($arch)"
  op_scp "$shim_src" "/tmp/masc-exec-shim.new"
  op_ssh "$SUDO install -m 755 /tmp/masc-exec-shim.new /usr/local/bin/masc-exec-shim && rm -f /tmp/masc-exec-shim.new"
fi

# --- 5. shim config + playground roots ------------------------------------
step "writing /etc/masc-exec-shim.conf and creating $REMOTE_ROOT"
op_ssh "$SUDO sh -c 'printf \"remote_root=%s\\n\" \"$REMOTE_ROOT\" > /etc/masc-exec-shim.conf && mkdir -p \"$REMOTE_ROOT\" && chown $USER_NAME \"$REMOTE_ROOT\"'"

for keeper in "${KEEPERS[@]:-}"; do
  [ -n "$keeper" ] || continue
  step "keeper $keeper: directory + GitHub identity"
  op_ssh "mkdir -p '$REMOTE_ROOT/$keeper/.config/gh'"
  id_dir="$BASE_PATH/.masc/keepers/$keeper/github-cli"
  if [ -f "$id_dir/hosts.yml" ]; then
    op_scp "$id_dir/hosts.yml" "$REMOTE_ROOT/$keeper/.config/gh/hosts.yml"
    [ -f "$id_dir/config.yml" ] && op_scp "$id_dir/config.yml" "$REMOTE_ROOT/$keeper/.config/gh/config.yml"
    op_ssh "chmod 600 '$REMOTE_ROOT/$keeper/.config/gh/hosts.yml'"
  else
    step "  no local identity at $id_dir — preflight will fail until one is placed"
  fi
done

# --- 6. verify over the endpoint key: the five preflight probes ------------
step "verifying with the server's connection shape"
probe="$(ep_ssh 'masc-exec-shim --probe')"
case "$probe" in
  '{"name":"masc-exec-shim"'*) step "  probe: $probe" ;;
  *) echo "unexpected probe output: $probe" >&2; exit 1 ;;
esac
ep_ssh 'git --version' >/dev/null && step "  git: ok"
ep_ssh "test -d '$REMOTE_ROOT'" && step "  remote_root: ok"
ep_ssh "df -Pk '$REMOTE_ROOT' >/dev/null" && step "  disk probe: ok"
for keeper in "${KEEPERS[@]:-}"; do
  [ -n "$keeper" ] || continue
  ep_ssh "test -d '$REMOTE_ROOT/$keeper'" && step "  keeper root $keeper: ok"
  if ep_ssh "env GH_CONFIG_DIR='$REMOTE_ROOT/$keeper/.config/gh' gh auth status" >/dev/null 2>&1; then
    step "  gh identity $keeper: ok"
  else
    step "  gh identity $keeper: MISSING (preflight will reject this keeper)"
  fi
done

# --- 7. server-side config -------------------------------------------------
block="
[exec.ssh.endpoints.$NAME]
host = \"$HOST\"
user = \"$USER_NAME\"
port = $PORT
remote_root = \"$REMOTE_ROOT\"
"
if [ "$WRITE_CONFIG" = 1 ]; then
  if grep -q "\[exec\.ssh\.endpoints\.$NAME\]" "$runtime_toml" 2>/dev/null; then
    step "runtime.toml already has endpoint $NAME — not touching it"
  else
    printf '%s' "$block" >> "$runtime_toml"
    step "appended endpoint $NAME to $runtime_toml (parsed live on next dispatch; no restart)"
  fi
else
  step "add this to $runtime_toml (or re-run with --write-config):"
  printf '%s' "$block"
fi

step "keeper TOML lines for each keeper using this endpoint:"
printf 'sandbox_profile = "remote_ssh"\nremote_endpoint = "%s"\n' "$NAME"
