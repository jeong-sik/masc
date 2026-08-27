#!/usr/bin/env bash
# run-local.sh — dir-local local-dev launcher.
# Starts the repo binary against a target directory and defaults runtime/config
# state to <target>/.masc/.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
TARGET_DIR="${PWD}"
HOST="${MASC_HOST:-127.0.0.1}"
PORT="${MASC_PORT:-}"
PORT_EXPLICIT=0
PRINT_PORT_ONLY=0
BOOTSTRAP_ONLY=0
BUILD_DASHBOARD=0
BOOTSTRAP_KEEPERS=0

usage() {
  cat >&2 <<'EOF'
Usage: scripts/run-local.sh [--target-dir PATH] [--host HOST] [--port PORT] [--print-port] [--bootstrap-only] [--build-dashboard] [--bootstrap-keepers]

Dir-local local-dev launcher:
  - runtime data root defaults to <target>/.masc/
  - config root defaults to <target>/.masc/config
  - gRPC / WS are disabled by default
  - --bootstrap-only materializes local config/build state but does not start the server
  - checked-in keeper manifests are excluded by default; pass --bootstrap-keepers to seed config/keepers

For shared repo/full-runtime startup, use ./start-masc.sh instead.
EOF
}

absolute_path() {
  local path="$1"
  if [ -d "$path" ]; then
    (cd "$path" && pwd -P)
  else
    return 1
  fi
}

derive_port_for_path() {
  local path="$1"
  local checksum
  checksum="$(printf '%s' "$path" | cksum | cut -d' ' -f1)"
  echo $((9100 + (checksum % 900)))
}

set_default_env() {
  local name="$1"
  local value="$2"
  if [ -z "${!name:-}" ]; then
    export "$name=$value"
  fi
}

source_commit() {
  git -C "$REPO_ROOT" rev-parse HEAD 2>/dev/null
}

source_fingerprint() {
  "$REPO_ROOT/scripts/source-binary-identity.sh" fingerprint
}

source_state() {
  "$REPO_ROOT/scripts/source-binary-identity.sh" state
}

binary_embedded_commit() {
  local exe="$1"
  if [ ! -x "$exe" ]; then
    return 1
  fi
  "$exe" build-commit 2>/dev/null
}

binary_embedded_source_fingerprint() {
  local exe="$1"
  if [ ! -x "$exe" ]; then
    return 1
  fi
  "$exe" build-source-fingerprint 2>/dev/null
}

binary_matches_source() {
  local exe="$1"
  local expected_commit="$2"
  local expected_fingerprint="$3"
  local embedded_commit=""
  local embedded_fingerprint=""
  embedded_commit="$(binary_embedded_commit "$exe" 2>/dev/null || true)"
  embedded_fingerprint="$(binary_embedded_source_fingerprint "$exe" 2>/dev/null || true)"
  [ -n "$embedded_commit" ] \
    && [ "$embedded_commit" = "$expected_commit" ] \
    && [ -n "$embedded_fingerprint" ] \
    && [ "$embedded_fingerprint" = "$expected_fingerprint" ]
}

require_exec_identity() {
  local observed_commit=""
  local observed_fingerprint=""
  observed_commit="$(source_commit 2>/dev/null || true)"
  observed_fingerprint="$(source_fingerprint 2>/dev/null || true)"
  if [ "$observed_commit" != "$SOURCE_COMMIT" ] \
    || [ "$observed_fingerprint" != "$SOURCE_FINGERPRINT" ] \
    || ! binary_matches_source "$EXE" "$SOURCE_COMMIT" "$SOURCE_FINGERPRINT"; then
    echo "Source or binary identity changed before executing the local server" >&2
    exit 1
  fi
}

bootstrap_local_config() {
  local target="$1"
  local local_masc_dir="$target/.masc"
  local local_config_dir="$local_masc_dir/config"
  local item=""
  local name=""
  if [ "${MASC_CONFIG_DIR+x}" = "x" ]; then
    return 0
  fi
  if [ -d "$local_config_dir" ]; then
    return 0
  fi

  mkdir -p "$local_masc_dir"
  if [ -d "$REPO_ROOT/config" ]; then
    mkdir -p "$local_config_dir"
    for item in "$REPO_ROOT/config"/*; do
      if [ ! -e "$item" ]; then
        continue
      fi
      name="$(basename "$item")"
      if [ "$name" = "keepers" ]; then
        if [ "$BOOTSTRAP_KEEPERS" = "1" ]; then
          cp -R "$item" "$local_config_dir/$name"
        else
          mkdir -p "$local_config_dir/keepers"
        fi
      else
        cp -R "$item" "$local_config_dir/$name"
      fi
    done
    if [ "$BOOTSTRAP_KEEPERS" = "1" ]; then
      echo "[local-run] Bootstrapped config into $local_config_dir (keepers included)" >&2
    else
      echo "[local-run] Bootstrapped config into $local_config_dir (keepers excluded; pass --bootstrap-keepers to include)" >&2
    fi
  else
    mkdir -p "$local_config_dir"
    echo "[local-run] Repo config/ missing; created empty $local_config_dir" >&2
  fi
}

build_dashboard_if_requested() {
  if [ "$BUILD_DASHBOARD" != "1" ]; then
    return 0
  fi
  if [ -x "$REPO_ROOT/scripts/build-dashboard-if-needed.sh" ]; then
    "$REPO_ROOT/scripts/build-dashboard-if-needed.sh"
  else
    echo "[local-run] Dashboard build helper missing, skipping." >&2
  fi
}

resolve_built_exe() {
  local expected_commit="$1"
  local expected_fingerprint="$2"
  local -a candidates=(
    "$REPO_ROOT/_build/default/bin/main_eio.exe"
  )
  local candidate
  for candidate in "${candidates[@]}"; do
    if binary_matches_source "$candidate" "$expected_commit" "$expected_fingerprint"; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done
  return 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --target-dir)
      TARGET_DIR="$2"
      shift 2
      ;;
    --host)
      HOST="$2"
      shift 2
      ;;
    --port)
      PORT="$2"
      PORT_EXPLICIT=1
      shift 2
      ;;
    --print-port)
      PRINT_PORT_ONLY=1
      shift
      ;;
    --bootstrap-only)
      BOOTSTRAP_ONLY=1
      shift
      ;;
    --build-dashboard)
      BUILD_DASHBOARD=1
      shift
      ;;
    --bootstrap-keepers)
      BOOTSTRAP_KEEPERS=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage
      exit 1
      ;;
  esac
done

TARGET_DIR="$(absolute_path "$TARGET_DIR")" || {
  echo "Target directory does not exist: $TARGET_DIR" >&2
  exit 1
}

if [ "$PORT_EXPLICIT" != "1" ] && [ -z "$PORT" ]; then
  PORT="$(derive_port_for_path "$TARGET_DIR")"
fi

if [ "$PRINT_PORT_ONLY" = "1" ]; then
  echo "$PORT"
  exit 0
fi

bootstrap_local_config "$TARGET_DIR"
build_dashboard_if_requested

LOCAL_CONFIG_DIR="${MASC_CONFIG_DIR:-$TARGET_DIR/.masc/config}"
SOURCE_COMMIT="$(source_commit)" || {
  echo "Failed to resolve source commit for $REPO_ROOT" >&2
  exit 1
}
SOURCE_FINGERPRINT="$(source_fingerprint)" || {
  echo "Failed to fingerprint binary source inputs for $REPO_ROOT" >&2
  exit 1
}
SOURCE_STATE="$(source_state)"
EXE="$(resolve_built_exe "$SOURCE_COMMIT" "$SOURCE_FINGERPRINT" || true)"

if [ -z "$EXE" ]; then
  echo "[local-run] Building local binary..." >&2
  "$REPO_ROOT/scripts/dune-local.sh" build bin/main_eio.exe
  AFTER_COMMIT="$(source_commit)" || true
  AFTER_FINGERPRINT="$(source_fingerprint)" || true
  if [ "$AFTER_COMMIT" != "$SOURCE_COMMIT" ] \
    || [ "$AFTER_FINGERPRINT" != "$SOURCE_FINGERPRINT" ]; then
    echo "Source changed while building the local binary; refusing a raced executable" >&2
    exit 1
  fi
  EXE="$(resolve_built_exe "$SOURCE_COMMIT" "$SOURCE_FINGERPRINT" || true)"
fi

if [ -z "$EXE" ]; then
  echo "Failed to resolve a worktree-local binary for commit $SOURCE_COMMIT" >&2
  exit 1
fi

if [ "$BOOTSTRAP_ONLY" = "1" ]; then
  echo "[local-run] Bootstrap ready" >&2
  echo "  Target dir: $TARGET_DIR" >&2
  echo "  Config root: $LOCAL_CONFIG_DIR" >&2
  echo "  Binary: $EXE" >&2
  echo "  Binary commit: $SOURCE_COMMIT" >&2
  echo "  Source fingerprint: $SOURCE_FINGERPRINT" >&2
  echo "  Source state: $SOURCE_STATE" >&2
  exit 0
fi

if lsof -iTCP:"$PORT" -sTCP:LISTEN -t >/dev/null 2>&1; then
  listener_pid="$(lsof -iTCP:"$PORT" -sTCP:LISTEN -t 2>/dev/null | head -n 1)"
  listener_cmd=""
  if [ -n "$listener_pid" ]; then
    listener_cmd="$(ps -p "$listener_pid" -o command= 2>/dev/null || true)"
  fi
  echo "Port $PORT already in use." >&2
  if [ -n "$listener_pid" ]; then
    echo "  Existing listener: pid=$listener_pid ${listener_cmd}" >&2
  fi
  exit 1
fi

export MASC_BASE_PATH="$TARGET_DIR"
set_default_env MASC_CONFIG_DIR "$LOCAL_CONFIG_DIR"
set_default_env MASC_GRPC_ENABLED "0"
set_default_env MASC_WS_ENABLED "0"

echo "Starting MASC MCP local-dev server..." >&2
echo "  Target dir: $TARGET_DIR" >&2
echo "  Data root: $TARGET_DIR/.masc" >&2
echo "  Config root: ${MASC_CONFIG_DIR}" >&2
echo "  Host: $HOST" >&2
echo "  Port: $PORT" >&2
echo "  Dashboard build: $(if [ "$BUILD_DASHBOARD" = "1" ]; then echo enabled; else echo skipped; fi)" >&2
echo "  Transports: http=on grpc=${MASC_GRPC_ENABLED} ws=${MASC_WS_ENABLED}" >&2

if [ -n "${MASC_LOG_FILE:-}" ]; then
  mkdir -p "$(dirname "$MASC_LOG_FILE")"
  echo "  Log file: $MASC_LOG_FILE (stdout+stderr tee'd)" >&2
  set -o pipefail
  require_exec_identity
  exec "$EXE" --host="$HOST" --port="$PORT" --base-path="$TARGET_DIR" 2>&1 | tee -a "$MASC_LOG_FILE"
else
  require_exec_identity
  exec "$EXE" --host="$HOST" --port="$PORT" --base-path="$TARGET_DIR"
fi
