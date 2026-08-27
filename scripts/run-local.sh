#!/usr/bin/env bash
# run-local.sh — dir-local local-dev launcher.
# Starts the repo binary against a target directory and defaults runtime/config
# state to <target>/.masc/.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
BUILD_TARGET="bin/main_eio.exe"
BUILT_EXE="$REPO_ROOT/_build/default/bin/main_eio.exe"
TARGET_DIR="${PWD}"
HOST="${MASC_HOST:-127.0.0.1}"
PORT="${MASC_PORT:-}"
PORT_EXPLICIT=0
PRINT_PORT_ONLY=0
BOOTSTRAP_ONLY=0
BUILD_DASHBOARD=0
BOOTSTRAP_KEEPERS=0

# shellcheck source=scripts/lib/runtime-artifact-contract.sh
source "$REPO_ROOT/scripts/lib/runtime-artifact-contract.sh"

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

binary_embedded_commit() {
  local exe="$1"
  if [ ! -x "$exe" ]; then
    return 1
  fi
  "$exe" build-commit 2>/dev/null
}

binary_matches_commit() {
  local exe="$1"
  local expected_commit="$2"
  local embedded_commit=""
  embedded_commit="$(binary_embedded_commit "$exe" 2>/dev/null || true)"
  [ -n "$embedded_commit" ] \
    && [ "$embedded_commit" = "$expected_commit" ]
}

build_input_fingerprint() {
  "$REPO_ROOT/scripts/dune-build-input-fingerprint.py" \
    --repo-root "$REPO_ROOT" \
    --target "$BUILD_TARGET"
}

build_local_binary() {
  "$REPO_ROOT/scripts/dune-local.sh" build "$BUILD_TARGET"
  [ -x "$BUILT_EXE" ] || {
    echo "Dune did not materialize $BUILT_EXE" >&2
    exit 1
  }
  binary_matches_commit "$BUILT_EXE" "$SOURCE_COMMIT" || {
    echo "Built binary commit differs from source commit $SOURCE_COMMIT" >&2
    exit 1
  }
  BUILD_INPUT_FINGERPRINT="$(build_input_fingerprint)" || {
    echo "Failed to fingerprint Dune inputs for $BUILD_TARGET" >&2
    exit 1
  }
  BUILT_EXE_SHA256="$(masc_runtime_artifact_hash "$BUILT_EXE")" || exit 1
}

write_executable_provenance() {
  local path="$1"
  local temp="$path.tmp.$$"
  umask 077
  printf \
    '{"schema":"masc.run-local-executable-identity.v1","binary_commit":"%s","build_input_fingerprint":"%s","executable_sha256":"%s"}\n' \
    "$SOURCE_COMMIT" "$BUILD_INPUT_FINGERPRINT" "$BUILT_EXE_SHA256" >"$temp"
  chmod 600 "$temp"
  mv -f "$temp" "$path"
}

materialize_executable_provenance() {
  local descriptor_dir="$TARGET_DIR/.masc/run-local-artifact"
  local candidate="$descriptor_dir/candidate"
  local current="$descriptor_dir/current"
  mkdir -p "$descriptor_dir"
  masc_runtime_artifact_descriptor_write \
    "$candidate" http "$BUILT_EXE" "$BUILT_EXE_SHA256" "$HOST" "$PORT"
  masc_runtime_artifact_promote "$candidate" "$current" "$REPO_ROOT"
  masc_runtime_artifact_descriptor_read "$current"
  EXE="$MASC_ARTIFACT_PATH"
  EXE_SHA256="$MASC_ARTIFACT_SHA256"
  EXE_PROVENANCE="$EXE.identity.json"
  write_executable_provenance "$EXE_PROVENANCE"
  EXE_PROVENANCE_SHA256="$(masc_runtime_artifact_hash "$EXE_PROVENANCE")" || exit 1
}

require_exec_identity() {
  local expected_fingerprint="$BUILD_INPUT_FINGERPRINT"
  local expected_built_sha256="$BUILT_EXE_SHA256"
  local observed_commit=""
  local observed_exe_sha256=""
  local observed_provenance_sha256=""

  # Dune is the build-input authority. Re-running the focused target here is
  # cached when nothing changed and materializes a new link result when any
  # transitive input changed after the first build.
  build_local_binary
  observed_commit="$(source_commit 2>/dev/null || true)"
  observed_exe_sha256="$(masc_runtime_artifact_hash "$EXE" 2>/dev/null || true)"
  observed_provenance_sha256="$(
    masc_runtime_artifact_hash "$EXE_PROVENANCE" 2>/dev/null || true
  )"
  if [ "$observed_commit" != "$SOURCE_COMMIT" ] \
    || [ "$BUILD_INPUT_FINGERPRINT" != "$expected_fingerprint" ] \
    || [ "$BUILT_EXE_SHA256" != "$expected_built_sha256" ] \
    || [ "$observed_exe_sha256" != "$EXE_SHA256" ] \
    || [ "$observed_provenance_sha256" != "$EXE_PROVENANCE_SHA256" ] \
    || ! binary_matches_commit "$EXE" "$SOURCE_COMMIT"; then
    echo "Dune input or executable identity changed before local server exec" >&2
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
echo "[local-run] Validating local binary with Dune..." >&2
build_local_binary
AFTER_COMMIT="$(source_commit)" || true
if [ "$AFTER_COMMIT" != "$SOURCE_COMMIT" ]; then
  echo "Source commit changed while building the local binary" >&2
  exit 1
fi

if [ "$BOOTSTRAP_ONLY" = "1" ]; then
  echo "[local-run] Bootstrap ready" >&2
  echo "  Target dir: $TARGET_DIR" >&2
  echo "  Config root: $LOCAL_CONFIG_DIR" >&2
  echo "  Binary: $BUILT_EXE" >&2
  echo "  Binary commit: $SOURCE_COMMIT" >&2
  echo "  Build input fingerprint: $BUILD_INPUT_FINGERPRINT" >&2
  echo "  Binary sha256: $BUILT_EXE_SHA256" >&2
  exit 0
fi

materialize_executable_provenance

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
