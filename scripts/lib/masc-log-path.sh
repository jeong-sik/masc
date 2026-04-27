#!/usr/bin/env bash
# masc-log-path.sh - SSOT helper for resolving the active MASC server's
# structured log file path.
#
# Resolution order (deterministic-first, hardcode-last):
#   1. $MASC_LOG       - explicit override, used as-is.
#   2. running server  - lsof on the listening socket detects the actual
#                        log file the server has open. Authoritative when
#                        the server is running, regardless of how it was
#                        started (argv --base-path, env, or anything else).
#   3. $MASC_BASE_PATH - env-provided base path; <base>/.masc/logs/system_log_TODAY.jsonl
#   4. $HOME/me        - second-brain default, only as last fallback.
#
# Sourced by scripts/logs-follow.sh and scripts/op-f-leak-verification.sh.
#
# Functions provided:
#   masc_log_path        - echo today's resolved log path.
#   masc_log_resolve_base - echo the resolved base path (without /.masc/logs/...).

masc_log_resolve_base() {
  if [ -n "${MASC_BASE_PATH:-}" ]; then
    echo "$MASC_BASE_PATH"
    return 0
  fi
  echo "${HOME}/me"
}

# Detect the log file currently held open by the running MASC server.
# Echoes the path on success, prints nothing and returns non-zero if
# detection fails.
_masc_log_detect_from_running_server() {
  local port="${MASC_PORT:-8935}"
  local pid
  pid=$(lsof -nP -iTCP:"$port" -sTCP:LISTEN -t 2>/dev/null | head -1)
  if [ -z "$pid" ]; then
    return 1
  fi
  local detected
  detected=$(lsof -p "$pid" 2>/dev/null \
    | awk '/system_log_[0-9-]+\.jsonl/ {print $NF; exit}')
  if [ -z "$detected" ]; then
    return 1
  fi
  echo "$detected"
}

masc_log_path() {
  if [ -n "${MASC_LOG:-}" ]; then
    echo "$MASC_LOG"
    return 0
  fi

  local detected
  if detected=$(_masc_log_detect_from_running_server); then
    echo "$detected"
    return 0
  fi

  local base
  base=$(masc_log_resolve_base)
  echo "${base}/.masc/logs/system_log_$(date +%Y-%m-%d).jsonl"
}

# Echo the directory containing today's log file.
# Same resolution order as masc_log_path; dirname of the result.
masc_log_dir() {
  dirname "$(masc_log_path)"
}
