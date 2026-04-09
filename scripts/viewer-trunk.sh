#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
VIEWER_DIR="$REPO_ROOT/viewer"
LOCK_DIR="$VIEWER_DIR/.trunk-lock"
TRUNK_ARGS=("$@")

# trunk 0.21 expects boolean values for --no-color.
# Some environments export NO_COLOR as 1/0, which breaks trunk argument parsing.
if [[ "${NO_COLOR:-}" == "1" ]]; then
  export NO_COLOR=true
elif [[ "${NO_COLOR:-}" == "0" ]]; then
  export NO_COLOR=false
fi

resolve_serve_port() {
  local port="8080"
  local i=0

  while (( i < ${#TRUNK_ARGS[@]} )); do
    local arg="${TRUNK_ARGS[$i]}"
    case "$arg" in
      --port=*)
        port="${arg#--port=}"
        ;;
      --port|-p)
        if (( i + 1 < ${#TRUNK_ARGS[@]} )); then
          port="${TRUNK_ARGS[$((i + 1))]}"
          ((i++))
        fi
        ;;
    esac
    ((i++))
  done

  printf '%s' "$port"
}

resolve_dist_dir() {
  local dist="dist"
  local i=0

  while (( i < ${#TRUNK_ARGS[@]} )); do
    local arg="${TRUNK_ARGS[$i]}"
    case "$arg" in
      --dist=*)
        dist="${arg#--dist=}"
        ;;
      --dist|-d)
        if (( i + 1 < ${#TRUNK_ARGS[@]} )); then
          dist="${TRUNK_ARGS[$((i + 1))]}"
          ((i++))
        fi
        ;;
    esac
    ((i++))
  done

  printf '%s' "$dist"
}

has_dist_arg() {
  local i=0
  while (( i < ${#TRUNK_ARGS[@]} )); do
    local arg="${TRUNK_ARGS[$i]}"
    case "$arg" in
      --dist=*|--dist|-d)
        return 0
        ;;
    esac
    ((i++))
  done
  return 1
}

maybe_isolate_build_dist() {
  if [[ "${TRUNK_ARGS[0]:-}" != "build" ]]; then
    return
  fi
  if has_dist_arg; then
    return
  fi
  if [[ "${MASC_BUILD_MAIN_DIST:-}" == "1" ]]; then
    return
  fi
  echo "viewer-trunk: defaulting build output to 'dist-build' (set MASC_BUILD_MAIN_DIST=1 for 'dist')." >&2
  TRUNK_ARGS+=("--dist" "dist-build")
}

check_serve_port_available() {
  if [[ "${TRUNK_ARGS[0]:-}" != "serve" ]]; then
    return
  fi

  local port
  port="$(resolve_serve_port)"
  if [[ ! "$port" =~ ^[0-9]+$ ]]; then
    return
  fi

  if ! command -v lsof >/dev/null 2>&1; then
    return
  fi

  local listeners
  listeners="$(lsof -nP -iTCP:"$port" -sTCP:LISTEN 2>/dev/null || true)"
  if [[ -z "$listeners" ]]; then
    return
  fi

  echo "viewer-trunk: port ${port} is already in use." >&2
  echo "$listeners" | head -n 4 >&2
  echo "Stop the process above or run on another port:" >&2
  echo "  scripts/viewer-trunk.sh serve --port 8081" >&2
  exit 1
}

maybe_prune_trpg_room() {
  if [[ "${TRUNK_ARGS[0]:-}" != "serve" ]]; then
    return
  fi

  if [[ "${MASC_TRPG_PRUNE_DEFAULT_ROOM:-0}" != "1" ]]; then
    return
  fi

  local prune_script="$SCRIPT_DIR/trpg-room-prune.sh"
  if [[ ! -x "$prune_script" ]]; then
    echo "viewer-trunk: skip TRPG prune (script not executable): $prune_script" >&2
    return
  fi

  local room_id="${MASC_TRPG_PRUNE_ROOM_ID:-default}"
  local base_path="${MASC_TRPG_PRUNE_BASE_PATH:-${MASC_BASE_PATH:-${HOME}/me}}"
  local keep_sessions="${MASC_TRPG_PRUNE_KEEP_SESSIONS:-1}"
  local -a prune_args=(
    --room-id "$room_id"
    --base-path "$base_path"
    --keep-sessions "$keep_sessions"
    --apply
  )
  if [[ "${MASC_TRPG_PRUNE_VACUUM:-0}" == "1" ]]; then
    prune_args+=(--vacuum)
  fi

  echo "viewer-trunk: running TRPG prune for room '$room_id' (keep=$keep_sessions)" >&2
  if ! "$prune_script" "${prune_args[@]}"; then
    echo "viewer-trunk: TRPG prune failed; continue serving" >&2
  fi
}

acquire_lock() {
  if mkdir "$LOCK_DIR" 2>/dev/null; then
    echo "$$" > "$LOCK_DIR/pid"
    return 0
  fi

  if [[ "${MASC_FORCE_UNLOCK:-}" == "1" ]]; then
    rm -rf "$LOCK_DIR"
    if mkdir "$LOCK_DIR" 2>/dev/null; then
      echo "$$" > "$LOCK_DIR/pid"
      return 0
    fi
  fi

  echo "viewer-trunk: another trunk command is already running for viewer." >&2
  echo "If this is stale, run: MASC_FORCE_UNLOCK=1 scripts/viewer-trunk.sh ${TRUNK_ARGS[*]}" >&2
  echo "Stop the existing command or wait for it to complete, then retry." >&2
  exit 1
}

release_lock() {
  rm -rf "$LOCK_DIR"
}

acquire_lock
trap release_lock EXIT INT TERM
maybe_isolate_build_dist
check_serve_port_available
maybe_prune_trpg_room

# Mitigate intermittent trunk stage-dir creation races.
DIST_DIR="$(resolve_dist_dir)"
mkdir -p "$VIEWER_DIR/$DIST_DIR/.stage"
mkdir -p "$VIEWER_DIR/target/wasm-bindgen/release"

cd "$VIEWER_DIR"
trunk "${TRUNK_ARGS[@]}"
