#!/usr/bin/env bash
# Apply ollama host-level tuning to keep keeper fleet from stalling on
# 27B model cold-starts and concurrent-request queueing.
#
# This script encodes a recurring failure pattern documented across the
# Vincent operator's memory entries:
#   - feedback_ollama_keepalive_kv_cache_root_cause.md
#   - "Ollama keepalive vs watchdog 5m race + KV cache" (cycle15, cycle17b)
# Each cycle re-applied the same launchctl + restart sequence by hand;
# this script makes the recovery one command.
#
# What it sets:
#   OLLAMA_KEEP_ALIVE   -1     persistent model load (no 5-minute unload race)
#   OLLAMA_NUM_PARALLEL 1      keep the 27B nvfp4 runner single-flight by
#                              default. qwen3.6 with 262k context can stall
#                              tiny probes under parallel=2; use a higher
#                              OLLAMA_NUM_PARALLEL_TARGET only after a local
#                              runtime probe proves the machine can absorb it.
#
# What it does NOT do:
#   - install ollama (assumed already present at /Applications/Ollama.app)
#   - touch cascade.toml (provider weights are an operator decision; see
#     ~/me/.masc/config/cascade.toml [keeper_unified] keep_alive setting)
#   - persist across macOS reboots beyond launchctl scope (login-session
#     env survives until reboot; for permanent set add to ~/.zshenv too)
#
# Usage:
#   ./scripts/host-ollama-tune.sh             # show current vs target, no change
#   ./scripts/host-ollama-tune.sh --apply     # apply launchctl env + restart ollama
#   ./scripts/host-ollama-tune.sh --status    # print current launchctl values

set -euo pipefail

KEEP_ALIVE_TARGET="${OLLAMA_KEEP_ALIVE_TARGET:--1}"
NUM_PARALLEL_TARGET="${OLLAMA_NUM_PARALLEL_TARGET:-1}"

usage() {
  sed -n '1,32p' "$0"
}

show_current() {
  local ka np
  ka="$(launchctl getenv OLLAMA_KEEP_ALIVE 2>/dev/null || true)"
  np="$(launchctl getenv OLLAMA_NUM_PARALLEL 2>/dev/null || true)"
  printf 'OLLAMA_KEEP_ALIVE   current=%-6s target=%s\n' "${ka:-<unset>}" "$KEEP_ALIVE_TARGET"
  printf 'OLLAMA_NUM_PARALLEL current=%-6s target=%s\n' "${np:-<unset>}" "$NUM_PARALLEL_TARGET"
}

apply() {
  echo "Setting launchctl env (OLLAMA_KEEP_ALIVE=$KEEP_ALIVE_TARGET, OLLAMA_NUM_PARALLEL=$NUM_PARALLEL_TARGET)..."
  launchctl setenv OLLAMA_KEEP_ALIVE "$KEEP_ALIVE_TARGET"
  launchctl setenv OLLAMA_NUM_PARALLEL "$NUM_PARALLEL_TARGET"

  if pgrep -x Ollama >/dev/null 2>&1; then
    echo "Restarting Ollama.app to pick up new env..."
    osascript -e 'tell application "Ollama" to quit' 2>/dev/null || killall Ollama 2>/dev/null || true
    # Wait for clean exit before relaunching
    for _ in 1 2 3 4 5; do
      if ! pgrep -x Ollama >/dev/null 2>&1; then break; fi
      sleep 1
    done
    open -a Ollama
    echo "Ollama relaunched. New runner will inherit env from launchctl."
  else
    echo "Ollama not running; launching now."
    open -a Ollama || echo "(Ollama.app not found at /Applications/Ollama.app — install or launch manually.)"
  fi

  echo ""
  echo "After-state:"
  show_current

  echo ""
  echo "Note: env is scoped to current login session. To persist across"
  echo "macOS reboots, also add the following to ~/.zshenv:"
  echo "  export OLLAMA_KEEP_ALIVE=$KEEP_ALIVE_TARGET"
  echo "  export OLLAMA_NUM_PARALLEL=$NUM_PARALLEL_TARGET"
}

case "${1:-}" in
  --apply) apply ;;
  --status) show_current ;;
  -h|--help) usage ;;
  "")
    echo "Current vs target (dry-run; pass --apply to change):"
    show_current
    ;;
  *) echo "unknown arg: $1" >&2; usage >&2; exit 2 ;;
esac
