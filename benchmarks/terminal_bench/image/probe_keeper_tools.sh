#!/usr/bin/env bash
# Prove the arm K path without harbor: can an external MCP client bring up a
# keeper and get it to change the container's filesystem?
#
# Arm K's claim is that harbor's own claude-code agent can drive a MASC keeper
# fleet through the public MCP surface. Everything in that sentence except the
# model's judgement is mechanical, and this script exercises exactly the
# mechanical part — bootstrap, the pre-set approval stance, masc_keeper_up,
# masc_keeper_msg, and whether the keeper's shell landed in this container.
# One container, one keeper, one short turn.
#
#   ANTHROPIC_API_KEY=... ./image/probe_keeper_tools.sh
#   BENCH_RUNTIME_ID=anthropic.claude-sonnet-5 ./image/probe_keeper_tools.sh
#
# Exits non-zero with the failing stage named. The container is removed unless
# PROBE_KEEP=1.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
BENCH_DIR="$(dirname "$HERE")"
IMAGE="${PROBE_IMAGE:-ubuntu:24.04}"
PLATFORM="${PROBE_PLATFORM:-linux/amd64}"
RUNTIME_ID="${BENCH_RUNTIME_ID:-anthropic.claude-sonnet-5}"
POOL="${BENCH_KEEPER_POOL:-bench-1}"
KEEPER="${POOL%%,*}"
# The witness has to be producible by a single argv, because the keeper's
# Execute tool runs argv directly with no shell. Asking for
# `printf x > /tmp/marker` got argv ["printf";"x";">";"/tmp/marker"], which
# exits 0 having printed the redirect as text — masc reported that faithfully
# (the warning was right there in the output), but no file appeared and the
# probe read it as "the keeper did nothing".
MARKER="/tmp/arm-k-keeper-was-here"
NAME="masc-armk-probe-$$"

provider="${RUNTIME_ID%%.*}"
case "${provider}" in
  anthropic) key_env=ANTHROPIC_API_KEY ;;
  openrouter) key_env=OPENROUTER_API_KEY ;;
  kimi_coding) key_env=KIMI_API_KEY ;;
  claude_code) key_env=CLAUDE_CODE_OAUTH_TOKEN ;;
  *) echo "unknown provider ${provider} in ${RUNTIME_ID}" >&2; exit 2 ;;
esac
# Indirect expansion, not eval: `eval printf '%s' "\${VAR}"` expands the value
# unquoted inside the eval, so a key containing whitespace loses it and a key
# containing a glob is expanded against cwd. The corrupted value then reaches
# the provider as an auth failure.
key="${!key_env:-}"
[[ -n "${key}" ]] || { echo "${key_env} is not set" >&2; exit 2; }
[[ -x "${BENCH_DIR}/dist/masc" ]] || { echo "run image/fetch_masc.sh first" >&2; exit 2; }

cfg="${BENCH_DIR}/configs/out-probe"
rm -rf "${cfg}"
cleanup() {
  [[ "${PROBE_KEEP:-0}" = "1" ]] || docker rm -f "${NAME}" >/dev/null 2>&1
  [[ "${PROBE_KEEP:-0}" = "1" ]] || rm -rf "${cfg}"
}
trap cleanup EXIT

echo "== render arm k config for ${RUNTIME_ID}"
# Rendering takes the wire model id; masc resolves the slugged binding id, and
# BENCH_RUNTIME_ID is what bootstrap hands to masc_keeper_up. Ask the renderer
# for the effective id rather than reimplementing the slug rule in shell.
EFFECTIVE_RUNTIME_ID="$(python3 -c "
import sys; sys.path.insert(0, '${BENCH_DIR}/configs')
from pathlib import Path
from render_configs import render_arm, effective_runtime_id
render_arm('k', '${RUNTIME_ID}', 'high', out_root=Path('${cfg}'))
print(effective_runtime_id('${RUNTIME_ID}'))
")" || { echo "STAGE_FAIL render" >&2; exit 1; }
echo "   binding: ${EFFECTIVE_RUNTIME_ID}"

echo "== boot container ${IMAGE}"
docker run -d --name "${NAME}" --platform "${PLATFORM}" \
  -e "${key_env}=${key}" \
  -e "BENCH_RUNTIME_ID=${EFFECTIVE_RUNTIME_ID}" \
  -e "BENCH_KEEPER_POOL=${POOL}" \
  ${GH_TOKEN:+-e "GH_TOKEN=${GH_TOKEN}"} \
  "${IMAGE}" sleep infinity >/dev/null || { echo "STAGE_FAIL docker-run" >&2; exit 1; }

# Copy rather than bind-mount, for the same reason harbor uploads: a bind
# mount ties the run to the host path staying put and shared. Docker Desktop
# does not share /var/folders (an unshared mount arrives empty, not as an
# error), and a git operation in this worktree mid-run swaps the directory
# inode out from under a live mount. Both cost a run before this changed.
docker exec "${NAME}" mkdir -p /opt/masc-bench/bin || { echo "STAGE_FAIL mkdir" >&2; exit 1; }
for f in masc masc-exec-shim gh; do
  [[ -f "${BENCH_DIR}/dist/${f}" ]] && docker cp "${BENCH_DIR}/dist/${f}" "${NAME}:/opt/masc-bench/bin/${f}"
done
docker cp "${BENCH_DIR}/driver" "${NAME}:/opt/masc-bench/driver"
docker cp "${cfg}/k" "${NAME}:/opt/masc-bench/config"
docker exec "${NAME}" chmod -R +x /opt/masc-bench/bin /opt/masc-bench/driver

echo "== bootstrap"
if ! docker exec \
    -e "${key_env}=${key}" \
    -e "BENCH_RUNTIME_ID=${EFFECTIVE_RUNTIME_ID}" \
    -e "BENCH_KEEPER_POOL=${POOL}" \
    ${GH_TOKEN:+-e "GH_TOKEN=${GH_TOKEN}"} \
    "${NAME}" bash /opt/masc-bench/driver/bootstrap.sh; then
  echo "STAGE_FAIL bootstrap" >&2
  docker exec "${NAME}" tail -30 /opt/masc-bench/server.log 2>/dev/null >&2 || true
  exit 1
fi

# From here on the script speaks the MCP surface the way Claude Code would:
# streamable HTTP with a bearer token and tools/call. It reuses driver/mcp.sh,
# the same client the episode driver uses, rather than a second hand-rolled
# one. Nothing keeper-specific goes through REST, because an MCP client cannot
# reach REST.
# mcp.sh keeps MCP_SESSION_ID in a shell variable, and every docker exec is a
# fresh shell, so each call initializes its own session before using it.
# Skipping that answers "Mcp-Session-Id header required".
mcp() {
  local id="$1" tool="$2" args="$3" secs="${4:-120}"
  docker exec "${NAME}" bash -c '
    set -o pipefail
    export MCP_TOKEN="$(cat /opt/masc-bench/token)"
    source /opt/masc-bench/driver/mcp.sh
    mcp_init >/dev/null || { echo "mcp_init failed" >&2; exit 1; }
    mcp_call "$1" "$2" "$3" "$4"' _ "${id}" "${tool}" "${args}" "${secs}"
}

echo "== masc_keeper_up ${KEEPER}"
# The script runs without `set -e`, so this has to be checked. It also used to
# grep the result for '"isError":true', which can never match: mcp_call already
# returns non-zero on an error result and otherwise prints the unwrapped text,
# which never carries the envelope key. A wiring failure was therefore reported
# 300 seconds later as "keeper-did-not-act", blaming the model.
up="$(mcp 10 masc_keeper_up "$(printf '{"name":"%s","runtime_id":"%s","activation_mode":"manual","instructions":"You run shell commands in this container. Do exactly what you are asked, then stop."}' "${KEEPER}" "${EFFECTIVE_RUNTIME_ID}")" 180)" \
  || { echo "STAGE_FAIL keeper_up" >&2; exit 1; }
echo "${up}" | head -c 600; echo

echo "== masc_keeper_msg -> write ${MARKER}"
msg="$(mcp 11 masc_keeper_msg "$(printf '{"name":"%s","message":"Run exactly one command and then stop: touch %s . Your Execute tool takes an argv list and runs it without a shell, so do not use redirection, pipes, or any shell syntax."}' "${KEEPER}" "${MARKER}")" 300)" \
  || { echo "STAGE_FAIL keeper_msg" >&2; exit 1; }
echo "${msg}" | head -c 600; echo

echo "== wait for the marker the keeper was asked to write"
# Sleep on the host, not with `docker exec sleep`: a container that dies
# mid-wait turned that into a hot loop printing "is not running" once per
# iteration instead of stopping with a reason.
found=""
for _ in $(seq 1 90); do
  if ! docker inspect -f '{{.State.Running}}' "${NAME}" 2>/dev/null | grep -q true; then
    echo "STAGE_FAIL container-died during the keeper turn" >&2
    exit 1
  fi
  if docker exec "${NAME}" test -f "${MARKER}" 2>/dev/null; then found=1; break; fi
  sleep 5
done
if [[ -z "${found}" ]]; then
  echo "STAGE_FAIL keeper-did-not-act" >&2
  # The reason a turn did not act lives in the server log, not in the tool
  # result: masc_keeper_msg returns as soon as the turn is queued, so a
  # provider rejection lands minutes later and asynchronously. Surfacing it
  # here is the difference between "the keeper did nothing" and "the API key
  # is over its usage limit until 2026-10-01", which is what one run actually
  # turned out to be.
  echo "--- keeper status" >&2
  mcp 12 masc_keeper_status "$(printf '{"name":"%s"}' "${KEEPER}")" 60 2>&1 | head -c 600 >&2
  echo >&2
  echo "--- server log, turn failures" >&2
  docker exec "${NAME}" sh -c \
    'grep -iE "turn_failed|attempt_rejected|pipeline stage failed|keeper tool call failed|stop=\"error" /opt/masc-bench/server.log | tail -6' >&2 2>/dev/null || true
  exit 1
fi

echo "PROBE_OK marker=${MARKER} written by the keeper"
# The marker proves a file appeared; the receipt proves where the command ran.
# Kept in a heredoc rather than -c, because the nested quoting of a one-liner
# inside this shell string is what broke the first version of this block.
docker exec "${NAME}" sh -c \
  'find /opt/masc-bench/base/.masc/tool_calls -name "*.jsonl" -exec tail -1 {} +' \
  | python3 <<'PYEOF' || true
import json, sys
for line in sys.stdin:
    line = line.strip()
    if not line:
        continue
    try:
        record = json.loads(line)
        result = json.loads(record["output"])
    except Exception:
        continue
    receipt = (result.get("shim_execution_evidence") or {}).get("receipts") or [{}]
    print("   argv:", (record.get("input") or {}).get("argv"))
    print("   exit:", result.get("status"), "| via:", result.get("via"),
          "| host:", result.get("remote_host"),
          "| boundary:", (receipt[0].get("receipt") or {}).get("boundary"))
PYEOF
