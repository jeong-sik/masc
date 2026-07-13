#!/usr/bin/env bash
set -euo pipefail

harness_find_server_exe() {
  local repo_root="$1"
  local explicit="${2:-}"
  local common_root=""
  local dune_build_dir="${DUNE_BUILD_DIR:-_build}"
  local repo_build_dir="$repo_root/$dune_build_dir"
  local common_build_dir=""
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
      common_build_dir="$common_root/$dune_build_dir"
    fi
  fi

  if [[ "$dune_build_dir" = /* ]]; then
    repo_build_dir="$dune_build_dir"
    if [[ -n "$common_root" ]]; then
      common_build_dir="$dune_build_dir"
    fi
  fi

  local -a candidates=(
    "${repo_build_dir}/default/bin/main_eio.exe"
    "${repo_root}/_build/default/bin/main_eio.exe"
    "${repo_root}/bin/main_eio.exe"
  )
  if [[ -n "$common_root" && "$common_root" != "$repo_root" ]]; then
    candidates+=(
      "${common_build_dir}/default/bin/main_eio.exe"
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
  local seed start port attempts=2048
  local tmp_root reservation_file
  seed="${HARNESS_PORT_SEED:-$$}"
  if [[ ! "$seed" =~ ^[0-9]+$ ]]; then
    seed="$$"
  fi
  tmp_root="$(harness_tmp_root)"
  reservation_file="${tmp_root%/}/masc-harness-ports.${seed}.txt"
  start=$((9200 + (seed % 1000)))
  port="$start"

  while (( attempts > 0 )); do
    if ! lsof -iTCP:"$port" -sTCP:LISTEN -t >/dev/null 2>&1 \
      && ! grep -qx "$port" "$reservation_file" 2>/dev/null; then
      printf '%s\n' "$port" >>"$reservation_file"
      printf '%s\n' "$port"
      return 0
    fi
    port=$((port + 1))
    if (( port > 65535 )); then
      port=9200
    fi
    attempts=$((attempts - 1))
  done

  echo "unable to find a free TCP port for harness startup" >&2
  return 1
}

harness_tmp_root() {
  printf '%s\n' "${TMPDIR:-/tmp}"
}

harness_mktemp_dir() {
  local prefix="$1"
  local tmp_root
  tmp_root="$(harness_tmp_root)"
  mktemp -d "${tmp_root%/}/${prefix}.XXXXXX"
}

harness_mktemp_file() {
  local prefix="$1"
  local suffix="${2:-}"
  local tmp_root
  local path
  tmp_root="$(harness_tmp_root)"
  path="$(mktemp "${tmp_root%/}/${prefix}.XXXXXX")" || return 1
  if [[ -n "$suffix" ]]; then
    local target="${path}${suffix}"
    mv "$path" "$target"
    path="$target"
  fi
  printf '%s\n' "$path"
}

harness_seed_server_config() {
  local repo_root="$1"
  local base_path="$2"
  local config_dir="${base_path%/}/.masc/config"

  mkdir -p \
    "$config_dir" \
    "$config_dir/keepers" \
    "$config_dir/personas" \
    "$config_dir/prompts"

  if [[ ! -f "$config_dir/runtime.toml" ]]; then
    cat >"$config_dir/runtime.toml" <<'EOF'
[runtime]
default = "transport_harness.smoke"

[providers.transport_harness]
display-name = "Transport Harness Smoke"
protocol = "openai-compatible-http"
endpoint = "http://127.0.0.1:9/v1"

[models.smoke]
# Borrow a real repo catalog id for strict capability lookup. The transport
# harness never reaches the provider endpoint, but Runtime.init_default_strict
# must still see model capability metadata instead of falling back to provider
# defaults.
api-name = "deepseek-v4-flash"
max-context = 32768
tools-support = true
streaming = true

[transport_harness.smoke]
is-default = true
max-concurrent = 1
EOF
  fi
}

harness_wait_for_health() {
  local port="$1"
  local timeout_sec="${2:-20}"
  local deadline=$(( $(date +%s) + timeout_sec ))
  while [[ "$(date +%s)" -lt "$deadline" ]]; do
    if curl -fsS --max-time 2 "http://127.0.0.1:${port}/health" >/dev/null 2>&1; then
      return 0
    fi
    sleep 1
  done
  return 1
}

harness_mint_admin_token() {
  local server_exe="$1"
  local port="$2"
  local base_path="$3"
  local agent="${4:-contract-harness-admin}"
  local token_json token

  if [[ ! -x "$server_exe" ]]; then
    echo "server executable missing for auth bootstrap: $server_exe" >&2
    return 1
  fi
  if ! command -v jq >/dev/null 2>&1; then
    echo "jq is required for auth bootstrap token extraction" >&2
    return 1
  fi

  if ! token_json="$(
    env -u MCP_TOKEN -u MCP_AUTH_TOKEN -u MASC_ADMIN_TOKEN -u MASC_TOKEN \
      MASC_BASE_PATH="$base_path" \
      MASC_BASE_PATH_INPUT="$base_path" \
      "$server_exe" login \
      --base-path "$base_path" \
      --host 127.0.0.1 \
      --port "$port" \
      --agent "$agent" \
      --role admin \
      --client-env MCP_TOKEN \
      --no-expiry \
      --json
  )"; then
    echo "failed to mint harness admin token for base_path=$base_path" >&2
    return 1
  fi

  token="$(printf '%s\n' "$token_json" | jq -r '.bearer_token // empty')"
  if [[ -z "$token" ]]; then
    echo "login output did not include bearer_token for base_path=$base_path" >&2
    return 1
  fi
  printf '%s\n' "$token"
}

harness_start_server() {
  local server_exe="$1"
  local port="$2"
  local base_path="$3"
  local log_file="$4"
  local repo_root="${MASC_HARNESS_REPO_ROOT:-${ROOT_DIR:-${REPO_ROOT:-}}}"

  if [[ -z "$repo_root" ]]; then
    repo_root="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
  fi

  mkdir -p "$base_path"
  harness_seed_server_config "$repo_root" "$base_path"
  (
    export MASC_BASE_PATH="$base_path"
    export MASC_BASE_PATH_INPUT="$base_path"
    unset MCP_TOKEN
    unset MCP_AUTH_TOKEN
    unset MASC_ADMIN_TOKEN
    unset MASC_TOKEN
    export MASC_AUTONOMY_ENABLED="0"
    export MASC_ORCHESTRATOR_ENABLED="0"
    export MASC_OTEL_ENABLED="0"
    export MASC_TOOL_TIMEOUT_DEFAULT_SEC="${MASC_TOOL_TIMEOUT_DEFAULT_SEC:-90}"
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
