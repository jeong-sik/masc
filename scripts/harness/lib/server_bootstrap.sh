#!/usr/bin/env bash
set -euo pipefail

harness_find_server_exe() {
  local repo_root="$1"
  local explicit="${2:-}"
  local common_root=""
  if [[ -n "$explicit" && -x "$explicit" ]]; then
    printf '%s\n' "$explicit"
    return 0
  fi

  if command -v git >/dev/null 2>&1; then
    local common_dir
    common_dir="$(git -C "$repo_root" rev-parse --git-common-dir 2>/dev/null || true)"
    if [[ -n "$common_dir" ]]; then
      if [[ "$common_dir" != /* ]]; then
        common_dir="$repo_root/$common_dir"
      fi
      common_root="$(cd "$(dirname "$common_dir")" && pwd)"
    fi
  fi

  local -a candidates=(
    "${repo_root}/_build/default/bin/main_eio.exe"
    "${repo_root}/bin/main_eio.exe"
  )
  if [[ -n "$common_root" && "$common_root" != "$repo_root" ]]; then
    candidates+=(
      "${common_root}/_build/default/bin/main_eio.exe"
      "${common_root}/bin/main_eio.exe"
    )
  fi
  local candidate
  for candidate in "${candidates[@]}"; do
    if [[ -x "$candidate" ]]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done

  echo "server executable not found; build with: dune build --root . ./bin/main_eio.exe" >&2
  return 1
}

harness_pick_free_port() {
  python3 - <<'PY'
import socket
s = socket.socket()
s.bind(("127.0.0.1", 0))
print(s.getsockname()[1])
s.close()
PY
}

harness_wait_for_health() {
  local port="$1"
  local timeout_sec="${2:-20}"
  local deadline=$(( $(date +%s) + timeout_sec ))
  while [[ "$(date +%s)" -lt "$deadline" ]]; do
    if curl -fsS "http://127.0.0.1:${port}/health" >/dev/null 2>&1; then
      return 0
    fi
    sleep 1
  done
  return 1
}

harness_start_server() {
  local server_exe="$1"
  local port="$2"
  local base_path="$3"
  local log_file="$4"

  (
    export ME_ROOT="$base_path"
    export MASC_BASE_PATH="$base_path"
    export MASC_STORAGE_TYPE="filesystem"
    export MASC_LODGE_ENABLED="0"
    export MASC_LODGE_DAEMON_ENABLED="0"
    export MASC_GUARDIAN_ENABLED="0"
    export MASC_ORCHESTRATOR_ENABLED="0"
    export GRAPHQL_API_KEY=""
    export GRAPHQL_URL="http://127.0.0.1:9/graphql"
    exec "$server_exe" --port "$port" --base-path "$base_path"
  ) >"$log_file" 2>&1 &
  printf '%s\n' "$!"
}

harness_stop_server() {
  local pid="${1:-}"
  local wait_sec="${2:-10}"
  if [[ -z "$pid" ]]; then
    return 0
  fi

  if kill -0 "$pid" >/dev/null 2>&1; then
    kill "$pid" >/dev/null 2>&1 || true
    local deadline=$(( $(date +%s) + wait_sec ))
    while kill -0 "$pid" >/dev/null 2>&1; do
      if [[ "$(date +%s)" -ge "$deadline" ]]; then
        kill -9 "$pid" >/dev/null 2>&1 || true
        break
      fi
      sleep 1
    done
  fi
}

harness_print_log_tail() {
  local log_file="$1"
  local lines="${2:-120}"
  if [[ -f "$log_file" ]]; then
    echo "---- tail -n ${lines} ${log_file} ----" >&2
    tail -n "$lines" "$log_file" >&2 || true
  fi
}
