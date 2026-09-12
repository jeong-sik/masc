#!/usr/bin/env bash
# One-shot container bootstrap for the MASC bench agent. Runs as root.
# Expects uploads already in place:
#   /opt/masc-bench/bin/masc      (release binary, +x)
#   /opt/masc-bench/driver/       (mcp.sh, bootstrap.sh, run_episode.sh)
#   /opt/masc-bench/config/       (rendered arm config: runtime.toml, keepers/, ...)
set -euo pipefail

source "$BENCH/driver/gh_seed.sh"

# BENCH_RUNTIME_ID must be the id masc resolves, `<provider>.<binding id>` —
# not the wire model. They differ whenever the wire name carries a slash, as
# every OpenRouter id does; the renderer's effective_runtime_id() is the one
# source of that rule and the caller applies it before setting this.
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
# Verify through the pin, not around it. With StrictHostKeyChecking=no and
# UserKnownHostsFile=/dev/null this read neither file, so an empty pin — a
# keyscan that raced sshd — passed bootstrap and failed later inside the
# keeper_up preflight, attributed to the keeper.
ssh -i "$BENCH/ssh/id_ed25519" \
  -o StrictHostKeyChecking=yes \
  -o UserKnownHostsFile="$MASC_BASE_PATH/.masc/ssh/known_hosts.d/local" \
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
    # --- keeper pool (arm K): bring the residents up, then hand the fleet to
    # --- an external MCP client. No task is sent here.
    #
    # The pool is started rather than merely declared because the chat approval
    # stance (Keeper_tool_approval_mode) can only be set for a keeper that is
    # already registered — POST /api/v1/keepers/tool-approval-mode answers 404
    # "keeper not registered" otherwise (measured on 0.35.8, 2026-09-12) — and
    # that route is REST, which an MCP client cannot reach. A keeper nobody has
    # spoken about is Auto, and Auto asks over the chat stream, which would
    # stall a headless trial. So the operator stands the fleet up and sets the
    # stance; the model addresses keepers that already exist.
    if [[ -n "${BENCH_KEEPER_POOL:-}" ]]; then
      pool_instructions="You are an autonomous engineering agent inside a Linux \
container. Your tool calls execute in this container as root. Do exactly what \
you are asked, verify it, and stop. Do not ask questions."
      IFS=',' read -r -a pool <<< "${BENCH_KEEPER_POOL}"
      pool_id=300
      for k in "${pool[@]}"; do
        # remote_ssh preflight requires <remote_root>/<name> to exist, and it
        # runs `gh auth status` against <keeper root>/.config/gh.
        mkdir -p "/root/${k}"
        seed_gh_hosts "${k}"
        pool_id=$((pool_id + 1))
        mcp_call "${pool_id}" masc_keeper_up "$(jq -cn \
          --arg name "$k" --arg ins "$pool_instructions" \
          --arg rid "${BENCH_RUNTIME_ID:?BENCH_RUNTIME_ID required}" \
          '{name:$name, instructions:$ins, runtime_id:$rid, activation_mode:"manual"}')" \
          180 >/dev/null
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
      echo "keeper pool up: ${BENCH_KEEPER_POOL}"
    fi
    echo "MASC server ready"; exit 0
  fi
  sleep 1
done
echo "MASC server failed to start; server.log tail:" >&2
tail -50 "$BENCH/server.log" >&2 || true
exit 1
