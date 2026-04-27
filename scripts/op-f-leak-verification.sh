#!/usr/bin/env bash
# op-f-leak-verification.sh
#
# 30-minute Operational Verification (OP-F) for the Plan v3 8-Leak fix
# bundle.  Runs five independent grep checks against the active server
# log and reports which Swiss Cheese layers are open or closed in the
# observed window.
#
# Designed to be re-runnable: each criterion is a single grep against a
# JSONL log produced by the masc-mcp server.  The log path is resolved
# via scripts/lib/masc-log-path.sh, which detects the active file from
# the running server (lsof on the listening socket) and falls back to
# $MASC_BASE_PATH or $HOME/me when no server is running.  No state is
# kept between runs — re-execute after any merge or restart to refresh
# the snapshot.
#
# Origin: 2026-04-25 keeper docker git_clone E2E investigation
# (memory/procedural-memory/2026-04-25-keeper-docker-clone-end-to-end-evidence-record.md).
# Plan v3 reference: ~/me/planning/claude-plans/20m-me-workspace-yousleepwhen-masc-mcp-k-wise-pudding.md
#
# Usage:
#   scripts/op-f-leak-verification.sh           # today's log
#   scripts/op-f-leak-verification.sh /path/to/system_log.jsonl
#   MASC_LOG=/tmp/masc-postmerge.log scripts/op-f-leak-verification.sh

set -u

# Resolve the active log path through the SSOT helper.  When the server
# is running, this detects the actual file via lsof on the listening
# socket — authoritative regardless of how the server was started.
# Otherwise falls back to MASC_BASE_PATH or $HOME/me.  Override with $1
# or $MASC_LOG when the log lives elsewhere (e.g. /tmp/masc-postmerge.log).
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
. "${SCRIPT_DIR}/lib/masc-log-path.sh"
LOG="${1:-$(masc_log_path)}"

if [ ! -r "${LOG}" ]; then
  echo "error: cannot read log file: ${LOG}" >&2
  echo "  hint: pass an explicit path, set MASC_LOG, or run after server start" >&2
  exit 2
fi

bytes=$(wc -c < "${LOG}" | tr -d ' ')
lines=$(wc -l < "${LOG}" | tr -d ' ')

printf '== OP-F Leak Verification ==\n'
printf 'log    : %s\n' "${LOG}"
printf 'bytes  : %s\n' "${bytes}"
printf 'lines  : %s\n' "${lines}"
printf '\n'

pass=0
fail=0

check() {
  local label="$1"
  local cond="$2"
  local detail="$3"
  if [ "${cond}" = "true" ]; then
    printf '  PASS  %s\n' "${label}"
    if [ -n "${detail}" ]; then
      printf '         %s\n' "${detail}"
    fi
    pass=$((pass + 1))
  else
    printf '  FAIL  %s\n' "${label}"
    if [ -n "${detail}" ]; then
      printf '         %s\n' "${detail}"
    fi
    fail=$((fail + 1))
  fi
}

# ── #1: keeper_shell op=git_clone via=docker reached at least once ─────
git_clone_ok=$(grep -c '"op":"git_clone".*"via":"docker".*"ok":true' "${LOG}" 2>/dev/null || true)
git_clone_ok=${git_clone_ok:-0}
git_clone_attempts=$(grep -c '"op":"git_clone"' "${LOG}" 2>/dev/null || true)
git_clone_attempts=${git_clone_attempts:-0}
if [ "${git_clone_ok}" -ge 1 ]; then
  check "#1 git_clone via=docker ok=true" true "ok=${git_clone_ok} (out of ${git_clone_attempts} attempts)"
else
  check "#1 git_clone via=docker ok=true" false "ok=0 (attempts=${git_clone_attempts}) — primary goal not yet reached"
fi

# ── #2: routine allowlist firing (PR-E + PR-J + PR-F effect) ───────────
routine=$(grep -c auto_approved_keeper_routine "${LOG}" 2>/dev/null || true)
routine=${routine:-0}
if [ "${routine}" -ge 5 ]; then
  check "#2 auto_approved_keeper_routine >= 5" true "count=${routine}"
else
  check "#2 auto_approved_keeper_routine >= 5" false "count=${routine} — Leak 1+3 may still be open"
fi

# ── #3: identity drift resolved (PR-F effect) ───────────────────────────
identity_block=$(grep -c 'keeper-analyst-agent cannot use' "${LOG}" 2>/dev/null || true)
identity_block=${identity_block:-0}
if [ "${identity_block}" -eq 0 ]; then
  check "#3 keeper-analyst-agent forbidden == 0" true "count=0 — identity drift cleared"
else
  check "#3 keeper-analyst-agent forbidden == 0" false "count=${identity_block} — Leak 2 still firing"
fi

# ── #4: PR creation reached (LLM downstream goal) ───────────────────────
pr_create=$(grep -cE '"op":"gh".*"action":"pr_create"|"pr_create".*"ok":true' "${LOG}" 2>/dev/null || true)
pr_create=${pr_create:-0}
if [ "${pr_create}" -ge 1 ]; then
  check "#4 pr_create reached" true "count=${pr_create}"
else
  check "#4 pr_create reached" false "count=0 — LLM may not have planned a PR yet (system prompt / task assignment)"
fi

# ── #5: fiber stability (no crash regressions) ──────────────────────────
fiber_crash=$(grep -cE 'fiber_crash|keeper_dead|max_restarts' "${LOG}" 2>/dev/null || true)
fiber_crash=${fiber_crash:-0}
if [ "${fiber_crash}" -eq 0 ]; then
  check "#5 fiber stability" true "no fiber_crash / keeper_dead / max_restarts"
else
  check "#5 fiber stability" false "count=${fiber_crash} — investigate before relying on observed metrics"
fi

# ── Auxiliary observability counters (PR-I effect) ─────────────────────
silent_token=$(grep -c '\[silent:auth_token_resolve_error\]' "${LOG}" 2>/dev/null || true)
silent_token=${silent_token:-0}
silent_dash=$(grep -c '\[silent:dashboard_actor_fallback\]' "${LOG}" 2>/dev/null || true)
silent_dash=${silent_dash:-0}
ambiguous=$(grep -c masc_auth_credential_ambiguous_lookup "${LOG}" 2>/dev/null || true)
ambiguous=${ambiguous:-0}

printf '\n-- PR-I observability (PR-I merged?) --\n'
printf '  silent:auth_token_resolve_error   = %s\n' "${silent_token}"
printf '  silent:dashboard_actor_fallback   = %s\n' "${silent_dash}"
printf '  auth_credential_ambiguous_lookup  = %s\n' "${ambiguous}"

# ── Summary ────────────────────────────────────────────────────────────
printf '\n-- Summary --\n'
printf '  passed: %s / 5\n' "${pass}"
printf '  failed: %s / 5\n' "${fail}"

if [ "${pass}" -eq 5 ]; then
  printf '\nALL CHECKS PASS — production-ready entry; queue 24h stability watch.\n'
  exit 0
elif [ "${pass}" -ge 3 ] && [ "${git_clone_ok}" -ge 1 ]; then
  printf '\nPARTIAL PASS — primary goal reached, run a 24h soak before fleet rollout.\n'
  exit 0
elif [ "${routine}" -ge 5 ] && [ "${identity_block}" -eq 0 ]; then
  printf '\nINFRA PATH OPEN — leak 1/2/3 cleared. If git_clone (#1) still 0, check\n'
  printf '  Leak 4 (pre-LLM filter) or LLM planning (system prompt / task assignment).\n'
  exit 1
else
  printf '\nLEAKS REMAIN — review the FAIL items above and consult the Plan v3 record:\n'
  printf '  ~/me/memory/procedural-memory/2026-04-25-keeper-docker-clone-end-to-end-evidence-record.md\n'
  exit 1
fi
