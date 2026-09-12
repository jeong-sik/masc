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

# shellcheck source-path=SCRIPTDIR source=deps.sh
source "$BENCH/driver/deps.sh"
bench_install_deps

# The remote_ssh exec lane runs `masc-exec-shim` on the remote PATH; the
# "remote" here is this same container, so install the static binary system-wide.
install -m 0755 "$BENCH/bin/masc-exec-shim" /usr/local/bin/masc-exec-shim
# The shim refuses to run without its config (exec_shim.mli): remote_root must
# match the endpoint's remote_root in the rendered runtime.toml (/root).
printf 'remote_root=/root\n' > /etc/masc-exec-shim.conf
chmod 644 /etc/masc-exec-shim.conf

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
# MASC's ssh lane uses strict host-key checking against the endpoint's
# known_hosts_file (default <base>/.masc/ssh/known_hosts.d/<name>); pin the
# freshly started sshd's host key there.
install -d -m 0700 "$MASC_BASE_PATH/.masc/ssh/known_hosts.d"
ssh-keyscan -t ed25519 127.0.0.1 2>/dev/null \
  > "$MASC_BASE_PATH/.masc/ssh/known_hosts.d/local"
chmod 600 "$MASC_BASE_PATH/.masc/ssh/known_hosts.d/local"
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
  if mcp_init 2>/dev/null; then
    # --- keeper pool mode (arm K): no keeper is started here; an external MCP
    # --- client brings them up by name.
    if [[ -n "${BENCH_KEEPER_POOL:-}" ]]; then
      # The chat approval stance (Keeper_tool_approval_mode) is in-memory, has
      # no config default by design, and is set only over REST — which an MCP
      # client cannot reach. A keeper nobody has spoken about is Auto, and Auto
      # asks over the chat stream, which would stall a headless trial. resolve
      # is keyed by name and does not need the keeper to exist, so the stance
      # is set for every pool name before any of them is brought up.
      IFS=',' read -r -a pool <<< "${BENCH_KEEPER_POOL}"
      for k in "${pool[@]}"; do
        mkdir -p "/root/${k}"
        if [[ -n "${GH_TOKEN:-}" ]]; then
          install -d -m 0700 "/root/${k}/.config/gh"
          printf 'github.com:\n    oauth_token: %s\n    git_protocol: https\n' \
            "${GH_TOKEN}" > "/root/${k}/.config/gh/hosts.yml"
          chmod 600 "/root/${k}/.config/gh/hosts.yml"
        fi
        curl -fsS -m 20 -X POST \
          "http://127.0.0.1:8935/api/v1/keepers/tool-approval-mode" \
          -H "Authorization: Bearer ${MCP_TOKEN}" \
          -H 'Content-Type: application/json' \
          -d "{\"name\":\"${k}\",\"mode\":\"yolo\"}" >/dev/null
      done
      # The MCP client runs as the agent user and reads the token to build its
      # .claude.json entry. Localhost-only admin token, single-task disposable
      # container.
      chmod 644 "$BENCH/token"
      echo "keeper pool approved: ${BENCH_KEEPER_POOL}"
    fi
    echo "MASC server ready"; exit 0
  fi
  sleep 1
done
echo "MASC server failed to start; server.log tail:" >&2
tail -50 "$BENCH/server.log" >&2 || true
exit 1
