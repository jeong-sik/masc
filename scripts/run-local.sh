#!/usr/bin/env bash
# run-local.sh — dir-local local-dev launcher.
# Starts the repo binary against a target directory and defaults runtime/config
# state to <target>/.masc/.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
TARGET_DIR="${PWD}"
HOST="${MASC_HOST:-127.0.0.1}"
PORT="${MASC_MCP_PORT:-}"
PORT_EXPLICIT=0
PRINT_PORT_ONLY=0
BOOTSTRAP_ONLY=0
BUILD_DASHBOARD=0
BOOTSTRAP_KEEPERS=0
DUNE_JOBS="${MASC_DUNE_JOBS:-8}"

git_common_root() {
  if ! command -v git >/dev/null 2>&1; then
    return 1
  fi
  local common_dir
  common_dir="$(git -C "$REPO_ROOT" rev-parse --git-common-dir 2>/dev/null || true)"
  if [ -z "$common_dir" ]; then
    return 1
  fi
  if [[ "$common_dir" != /* ]]; then
    common_dir="$REPO_ROOT/$common_dir"
  fi
  (cd "$(dirname "$common_dir")" && pwd)
}

usage() {
  cat >&2 <<'EOF'
Usage: scripts/run-local.sh [--target-dir PATH] [--host HOST] [--port PORT] [--print-port] [--bootstrap-only] [--build-dashboard] [--bootstrap-keepers]

Dir-local local-dev launcher:
  - runtime data root defaults to <target>/.masc/
  - config root defaults to <target>/.masc/config
  - personas root defaults to <target>/.masc/config/personas
  - gRPC / WS / WebRTC are disabled by default
  - --bootstrap-only materializes local config/build state but does not start the server
  - checked-in keeper manifests are excluded by default; pass --bootstrap-keepers to seed config/keepers

For shared repo/full-runtime startup, use ./start-masc-mcp.sh instead.
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

binary_is_stale() {
  local exe="$1"
  if [ ! -x "$exe" ]; then
    return 0
  fi
  if [[ "$exe" != "$REPO_ROOT/"* ]]; then
    local common_root="" common_head=""
    common_root="$(git_common_root 2>/dev/null || true)"
    if [ -n "$common_root" ] && [ "$common_root" != "$REPO_ROOT" ]; then
      common_head="$(git -C "$common_root" rev-parse HEAD 2>/dev/null || true)"
      if [ -n "$common_head" ] \
        && git -C "$REPO_ROOT" diff --quiet "${common_head}"...HEAD -- bin lib proto dune-project 2>/dev/null \
        && git -C "$REPO_ROOT" diff --quiet -- bin lib proto dune-project 2>/dev/null \
        && git -C "$REPO_ROOT" diff --cached --quiet -- bin lib proto dune-project 2>/dev/null; then
        if ! git -C "$REPO_ROOT" ls-files --others --exclude-standard -- bin lib proto dune-project 2>/dev/null \
          | grep -q .; then
          return 1
        fi
      fi
    fi
  fi
  if [ "$REPO_ROOT/dune-project" -nt "$exe" ]; then
    return 0
  fi
  if find "$REPO_ROOT/bin" "$REPO_ROOT/lib" "$REPO_ROOT/proto" \
      -type f \( -name '*.ml' -o -name '*.mli' -o -name 'dune' \) \
      -newer "$exe" -print -quit 2>/dev/null \
    | grep -q .; then
    return 0
  fi
  return 1
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
  local common_root=""
  common_root="$(git_common_root 2>/dev/null || true)"
  local -a candidates=(
    "$REPO_ROOT/_build/default/bin/main_eio.exe"
  )
  if [ -n "$common_root" ] && [ "$common_root" != "$REPO_ROOT" ]; then
    candidates+=("$common_root/_build/default/bin/main_eio.exe")
  fi
  local candidate
  for candidate in "${candidates[@]}"; do
    if [ -x "$candidate" ]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done
  printf '%s\n' "$REPO_ROOT/_build/default/bin/main_eio.exe"
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
LOCAL_PERSONAS_DIR="${MASC_PERSONAS_DIR:-$LOCAL_CONFIG_DIR/personas}"
EXE="$(resolve_built_exe)"

if binary_is_stale "$EXE"; then
  echo "[local-run] Building local binary..." >&2
  dune build -j "$DUNE_JOBS" --root "$REPO_ROOT" bin/main_eio.exe
fi

if [ ! -x "$EXE" ]; then
  echo "Failed to resolve built binary: $EXE" >&2
  exit 1
fi

if [ "$BOOTSTRAP_ONLY" = "1" ]; then
  echo "[local-run] Bootstrap ready" >&2
  echo "  Target dir: $TARGET_DIR" >&2
  echo "  Config root: $LOCAL_CONFIG_DIR" >&2
  echo "  Personas root: $LOCAL_PERSONAS_DIR" >&2
  echo "  Binary: $EXE" >&2
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
set_default_env MASC_PERSONAS_DIR "$LOCAL_PERSONAS_DIR"
set_default_env MASC_GRPC_ENABLED "0"
set_default_env MASC_WS_ENABLED "0"
set_default_env MASC_WEBRTC_ENABLED "0"

echo "Starting MASC MCP local-dev server..." >&2
echo "  Target dir: $TARGET_DIR" >&2
echo "  Data root: $TARGET_DIR/.masc" >&2
echo "  Config root: ${MASC_CONFIG_DIR}" >&2
echo "  Personas root: ${MASC_PERSONAS_DIR}" >&2
echo "  Host: $HOST" >&2
echo "  Port: $PORT" >&2
echo "  Dashboard build: $(if [ "$BUILD_DASHBOARD" = "1" ]; then echo enabled; else echo skipped; fi)" >&2
echo "  Transports: http=on grpc=${MASC_GRPC_ENABLED} ws=${MASC_WS_ENABLED} webrtc=${MASC_WEBRTC_ENABLED}" >&2

if [ -n "${MASC_LOG_FILE:-}" ]; then
  mkdir -p "$(dirname "$MASC_LOG_FILE")"
  echo "  Log file: $MASC_LOG_FILE (stdout+stderr tee'd)" >&2
  set -o pipefail
  exec "$EXE" --host="$HOST" --port="$PORT" --base-path="$TARGET_DIR" 2>&1 | tee -a "$MASC_LOG_FILE"
else
  exec "$EXE" --host="$HOST" --port="$PORT" --base-path="$TARGET_DIR"
fi
