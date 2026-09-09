#!/usr/bin/env bash
# One-shot container bootstrap for the MASC bench agent. Runs as root.
# Expects uploads already in place:
#   /opt/masc-bench/bin/masc      (release binary, +x)
#   /opt/masc-bench/driver/       (mcp.sh, bootstrap.sh, run_episode.sh)
#   /opt/masc-bench/config/       (rendered arm config: runtime.toml, keepers/, ...)
set -euo pipefail

BENCH=/opt/masc-bench
export MASC_BASE_PATH=$BENCH/base
export MASC_CONFIG_DIR=$BENCH/config
export MASC_KEEPER_AUTONOMOUS_ENABLED=0
export MASC_ORCHESTRATOR_ENABLED=0
export AGENT_CORE_MCP_SERVERS_CONFIG="mcp_servers={}"

# config dir must be writable (server writes runtime state overlays); if the
# mount is read-only, fall back to a writable copy.
if ! ( touch "$MASC_CONFIG_DIR/.write-test" 2>/dev/null ); then
  if [[ -d "$BENCH/config-rw" ]]; then
    export MASC_CONFIG_DIR="$BENCH/config-rw"
  else
    cp -r "$MASC_CONFIG_DIR" "$BENCH/config-rw"
    export MASC_CONFIG_DIR="$BENCH/config-rw"
  fi
else
  rm -f "$MASC_CONFIG_DIR/.write-test"
fi

# ship skills into the base-path source root for skills-on arms
if [[ -d "$MASC_CONFIG_DIR/skills" ]]; then
  mkdir -p "$MASC_BASE_PATH/.masc"
  rm -rf "$MASC_BASE_PATH/.masc/skills"
  cp -r "$MASC_CONFIG_DIR/skills" "$MASC_BASE_PATH/.masc/skills"
fi

export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq --no-install-recommends \
  openssh-server jq curl ca-certificates \
  libffi8 libgmp10 libsqlite3-0 libssl3t64 libzstd1 zlib1g >/dev/null

# --- sshd on localhost, root key auth (keeper remote_ssh endpoint target) ---
install -d -m 0755 /run/sshd
install -d -m 0700 "$BENCH/ssh" /root/.ssh
[[ -f "$BENCH/ssh/id_ed25519" ]] || ssh-keygen -t ed25519 -N '' -q -f "$BENCH/ssh/id_ed25519"
install -m 0600 "$BENCH/ssh/id_ed25519.pub" /root/.ssh/authorized_keys
{
  echo 'PasswordAuthentication no'
  echo 'PermitRootLogin prohibit-password'
  echo 'PubkeyAuthentication yes'
} >> /etc/ssh/sshd_config
pgrep -x sshd >/dev/null || /usr/sbin/sshd
ssh -i "$BENCH/ssh/id_ed25519" \
  -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
  root@127.0.0.1 true

# --- token BEFORE server start (minting against a live base path makes the
# --- server yield ownership; harness_coding_eval.sh:195-199) ---
if [[ ! -s "$BENCH/token" ]]; then
  "$BENCH/bin/masc" login \
    --base-path "$MASC_BASE_PATH" --host 127.0.0.1 --port 8935 \
    --agent bench --role admin --client-env MCP_TOKEN --no-expiry --json \
    | jq -r '.bearer_token // empty' > "$BENCH/token"
  chmod 600 "$BENCH/token"
  [[ -s "$BENCH/token" ]] || { echo "login did not yield bearer_token" >&2; exit 1; }
fi

# --- start server (idempotent) ---
if ! pgrep -f "masc start" >/dev/null; then
  nohup "$BENCH/bin/masc" start --host 127.0.0.1 --port 8935 \
    --base-path "$MASC_BASE_PATH" > "$BENCH/server.log" 2>&1 &
fi

# --- wait until MCP answers ---
MCP_TOKEN="$(cat "$BENCH/token")"
export MCP_TOKEN
# shellcheck source-path=SCRIPTDIR source=mcp.sh
source "$BENCH/driver/mcp.sh"
for _ in $(seq 1 60); do
  if mcp_init 2>/dev/null; then echo "MASC server ready"; exit 0; fi
  sleep 1
done
echo "MASC server failed to start; server.log tail:" >&2
tail -50 "$BENCH/server.log" >&2 || true
exit 1
