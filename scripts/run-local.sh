#!/usr/bin/env bash
# run-local.sh — dir-local local-dev launcher.
# Starts the repo binary against a target directory and defaults runtime/config
# state to <target>/.masc/.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
BUILD_TARGET="bin/main_eio.exe"
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

write_dune_build_receipt() {
  local receipt="$1"
  "$REPO_ROOT/scripts/dune-build-input-fingerprint.py" \
    --repo-root "$REPO_ROOT" \
    --target "$BUILD_TARGET" \
    --receipt >"$receipt"
}

read_dune_build_receipt() {
  local receipt="$1"
  local schema=""
  {
    IFS= read -r schema
    IFS= read -r BUILT_EXE
    IFS= read -r BUILD_INPUT_FINGERPRINT
    if IFS= read -r _extra; then
      return 1
    fi
  } <"$receipt"
  [ "$schema" = "masc.dune-build-input-receipt.v1" ] \
    && [ -x "$BUILT_EXE" ] \
    && masc_runtime_artifact_valid_hash "$BUILD_INPUT_FINGERPRINT"
}

build_local_binary() {
  local receipt=""
  "$REPO_ROOT/scripts/dune-local.sh" build "$BUILD_TARGET"
  receipt="$(mktemp "${TMPDIR:-/tmp}/masc-dune-build-receipt.XXXXXX")"
  if ! write_dune_build_receipt "$receipt" || ! read_dune_build_receipt "$receipt"; then
    rm -f "$receipt"
    echo "Dune did not return an exact build-input receipt" >&2
    exit 1
  fi
  rm -f "$receipt"
  binary_matches_commit "$BUILT_EXE" "$SOURCE_COMMIT" || {
    echo "Built binary commit differs from source commit $SOURCE_COMMIT" >&2
    exit 1
  }
  BUILT_EXE_SHA256="$(masc_runtime_artifact_hash "$BUILT_EXE")" || exit 1
}

materialize_executable_provenance() {
  local git_common_dir=""
  local private_root=""
  local receipt=""
  local schema=""
  local receipt_extra=0
  git_common_dir="$(git -C "$REPO_ROOT" rev-parse --path-format=absolute --git-common-dir)"
  private_root="$git_common_dir/masc-run-local-artifacts"
  receipt="$(mktemp "${TMPDIR:-/tmp}/masc-launch-binding.XXXXXX")"
  if ! "$REPO_ROOT/scripts/run-local-executable-binding.py" \
      --private-root "$private_root" \
      --executable "$BUILT_EXE" \
      --commit "$SOURCE_COMMIT" \
      --fingerprint "$BUILD_INPUT_FINGERPRINT" >"$receipt"
  then
    rm -f "$receipt"
    exit 1
  fi
  {
    IFS= read -r schema
    IFS= read -r EXE
    IFS= read -r EXE_SHA256
    IFS= read -r EXE_PROVENANCE
    IFS= read -r EXE_PROVENANCE_SHA256
    IFS= read -r EXE_PROVENANCE_DEVICE
    IFS= read -r EXE_PROVENANCE_INODE
    if IFS= read -r _extra; then receipt_extra=1; fi
  } <"$receipt"
  rm -f "$receipt"
  if ! [ "$receipt_extra" = "0" ] \
    && [ "$schema" = "masc.run-local-launch-binding.v1" ] \
    && [ -x "$EXE" ] \
    && [ -f "$EXE_PROVENANCE" ] \
    && masc_runtime_artifact_valid_hash "$EXE_SHA256" \
    && masc_runtime_artifact_valid_hash "$EXE_PROVENANCE_SHA256" \
    && [ "$EXE_PROVENANCE_DEVICE" -ge 0 ] \
    && [ "$EXE_PROVENANCE_INODE" -ge 0 ]
  then
    echo "Executable binding did not return an exact launch receipt" >&2
    return 1
  fi
  if [ "$EXE_SHA256" != "$BUILT_EXE_SHA256" ]; then
    echo "Materialized executable differs from the initial Dune executable" >&2
    return 1
  fi
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

if [ "${MASC_DUNE_DRY_RUN:-0}" = "1" ]; then
  echo "run-local exact launch does not accept MASC_DUNE_DRY_RUN=1" >&2
  exit 1
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
  exec "$EXE" --host="$HOST" --port="$PORT" --base-path="$TARGET_DIR" \
    --build-provenance-path="$EXE_PROVENANCE" \
    --build-provenance-sha256="$EXE_PROVENANCE_SHA256" \
    --build-provenance-device="$EXE_PROVENANCE_DEVICE" \
    --build-provenance-inode="$EXE_PROVENANCE_INODE" \
    2>&1 | tee -a "$MASC_LOG_FILE"
else
  require_exec_identity
  exec "$EXE" --host="$HOST" --port="$PORT" --base-path="$TARGET_DIR" \
    --build-provenance-path="$EXE_PROVENANCE" \
    --build-provenance-sha256="$EXE_PROVENANCE_SHA256" \
    --build-provenance-device="$EXE_PROVENANCE_DEVICE" \
    --build-provenance-inode="$EXE_PROVENANCE_INODE"
fi
