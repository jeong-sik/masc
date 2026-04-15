#!/bin/bash
# MASC MCP Server (OCaml) - Shared/full-runtime start script (HTTP/SSE default)
# Usage: ./start-masc-mcp.sh [--print-port] [--stdio] [--http] [--eio] [--lwt] [--host HOST] [--port PORT] [--base-path PATH|--path PATH]
# Note: Eio is the default runtime; --lwt exits with an error.
# For dir-local local-dev startup, prefer scripts/run-local.sh.

set -e

# OCaml GC: use defaults. Large minor heap (s=4194304) caused 10GB+ RSS
# because Eio fibers share the domain heap and 360 tools + 12 keepers
# amplify allocation pressure. The default 256KB minor heap is sufficient.

# Optional: load OPAM environment if available (must never be fatal for MCP startup)
if command -v opam >/dev/null 2>&1; then
    eval "$(opam env 2>/dev/null)" >/dev/null 2>/dev/null || true
fi

# Storage backend: filesystem by default.
export MASC_STORAGE_TYPE="${MASC_STORAGE_TYPE:-filesystem}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# Build concurrency limit: use half of available cores to prevent system freeze
# when multiple worktrees trigger simultaneous dune builds.
DUNE_JOBS="${MASC_DUNE_JOBS:-8}"

# mkdir-based build mutex (atomic on POSIX, works on macOS without flock).
# Prevents multiple start-masc-mcp.sh instances from building concurrently.
# Stores owner PID to detect and recover from stale locks left by crashed processes.
MASC_BUILD_LOCK="/tmp/masc-mcp-build.lock"
_MASC_LOCK_HELD=""
_masc_cleanup_lock() {
    if [ -n "$_MASC_LOCK_HELD" ] && [ -d "$MASC_BUILD_LOCK" ]; then
        rm -f "$MASC_BUILD_LOCK/pid"
        rmdir "$MASC_BUILD_LOCK" 2>/dev/null || true
        _MASC_LOCK_HELD=""
    fi
}
trap '_masc_cleanup_lock' EXIT
acquire_build_lock() {
    if mkdir "$MASC_BUILD_LOCK" 2>/dev/null; then
        echo $$ > "$MASC_BUILD_LOCK/pid"
        _MASC_LOCK_HELD="1"
        return 0
    fi
    # Check for stale lock (owner process no longer running)
    local owner_pid
    owner_pid="$(cat "$MASC_BUILD_LOCK/pid" 2>/dev/null || echo "")"
    if [ -n "$owner_pid" ] && ! kill -0 "$owner_pid" 2>/dev/null; then
        echo "Removing stale build lock (pid $owner_pid no longer running)" >&2
        rm -f "$MASC_BUILD_LOCK/pid"
        rmdir "$MASC_BUILD_LOCK" 2>/dev/null || true
        if mkdir "$MASC_BUILD_LOCK" 2>/dev/null; then
            echo $$ > "$MASC_BUILD_LOCK/pid"
            _MASC_LOCK_HELD="1"
            return 0
        fi
    fi
    echo "Another MASC build in progress (pid ${owner_pid:-unknown}), skipping rebuild" >&2
    return 1
}
release_build_lock() {
    _masc_cleanup_lock
}

is_truthy() {
    case "$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]')" in
        1|true|yes|y|on) return 0 ;;
        *) return 1 ;;
    esac
}

is_absolute_path() {
    case "${1:-}" in
        /*) return 0 ;;
        *) return 1 ;;
    esac
}

# Resolve a path to its git-root equivalent (worktree-aware).
# Used both by the ambiguity guard and the final MASC_BASE_PATH export
# so both see the same effective base path.
resolve_base_path() {
    local path="$1"
    local abs_path=""

    if [ -d "$path" ]; then
        abs_path="$(cd "$path" && pwd -P)"
    fi

    if [ -f "$path/.git" ]; then
        local gitdir
        gitdir="$(sed -n 's/^gitdir: //p' "$path/.git")"
        if [ -n "$gitdir" ]; then
            case "$gitdir" in
                */.git/worktrees/*)
                    echo "${gitdir%/.git/worktrees/*}"
                    return
                    ;;
                */.git)
                    echo "${gitdir%/.git}"
                    return
                    ;;
            esac
        fi
    fi

    if [ -d "$path/.git" ]; then
        echo "${abs_path:-$path}"
        return
    fi

    if command -v git >/dev/null 2>&1; then
        local git_root
        git_root="$(git -C "$path" rev-parse --show-toplevel 2>/dev/null || true)"
        if [ -n "$git_root" ]; then
            echo "$(cd "$git_root" && pwd -P)"
            return
        fi
    fi

    echo "${abs_path:-$path}"
}

build_dashboard_spa() {
    local dashboard_dir="$SCRIPT_DIR/dashboard"
    local dashboard_index="$SCRIPT_DIR/assets/dashboard/index.html"
    local log_file=""
    local dashboard_pm=()
    local dashboard_pm_label=""

    if [ ! -f "$dashboard_dir/package.json" ]; then
        return 0
    fi

    if is_truthy "${MASC_SKIP_DASHBOARD_BUILD:-0}"; then
        echo "[dashboard] Skipping SPA build (MASC_SKIP_DASHBOARD_BUILD=1)." >&2
        return 0
    fi

    if ! is_truthy "${MASC_DASHBOARD_BUILD_ALWAYS:-0}"; then
        local stale=0
        if [ ! -f "$dashboard_index" ]; then
            stale=1
        fi
        for candidate in \
            "$dashboard_dir/package.json" \
            "$dashboard_dir/pnpm-lock.yaml" \
            "$dashboard_dir/tsconfig.json" \
            "$dashboard_dir/vite.config.ts"
        do
            if [ -f "$candidate" ] && [ "$candidate" -nt "$dashboard_index" ]; then
                stale=1
                break
            fi
        done
        if [ "$stale" -eq 0 ] && [ -d "$dashboard_dir/src" ] && find "$dashboard_dir/src" -type f -newer "$dashboard_index" | head -n 1 | grep -q .; then
            stale=1
        fi
        if [ "$stale" -eq 0 ] && [ -d "$dashboard_dir/public" ] && find "$dashboard_dir/public" -type f -newer "$dashboard_index" | head -n 1 | grep -q .; then
            stale=1
        fi
        if [ "$stale" -eq 0 ]; then
            echo "[dashboard] Build output is fresh; skipping SPA build." >&2
            return 0
        fi
    fi

    echo "[dashboard] Building SPA before server start..." >&2
    if command -v pnpm >/dev/null 2>&1; then
        dashboard_pm=(pnpm)
    elif command -v corepack >/dev/null 2>&1; then
        dashboard_pm=(corepack pnpm)
    else
        echo "[dashboard] pnpm/corepack not found, skipping dashboard build." >&2
        return 0
    fi
    dashboard_pm_label="${dashboard_pm[*]}"

    local temp_root="${TMPDIR:-/tmp}"
    temp_root="${temp_root%/}"
    if [ ! -d "$temp_root" ] || [ ! -w "$temp_root" ]; then
        temp_root="/tmp"
    fi
    if ! log_file="$(TMPDIR="$temp_root" mktemp "$temp_root/masc-dashboard-build.XXXXXX" 2>/dev/null)"; then
        echo "[dashboard] Unable to create temp log file; falling back to stderr-less logging." >&2
        log_file="/dev/null"
    fi
    if [ -d "$dashboard_dir/node_modules" ]; then
        if (cd "$dashboard_dir" && "${dashboard_pm[@]}" run build >"$log_file" 2>&1); then
            tail -n 3 "$log_file" >&2 || true
            if [ "$log_file" != "/dev/null" ]; then
                rm -f "$log_file"
            fi
            return 0
        fi
        echo "[dashboard] Existing deps build failed, retrying after ${dashboard_pm_label} install..." >&2
    fi

    if (cd "$dashboard_dir" && "${dashboard_pm[@]}" install --frozen-lockfile --prefer-offline >"$log_file" 2>&1 && "${dashboard_pm[@]}" run build >>"$log_file" 2>&1); then
        tail -n 6 "$log_file" >&2 || true
        if [ "$log_file" != "/dev/null" ]; then
            rm -f "$log_file"
        fi
        return 0
    fi

    tail -n 20 "$log_file" >&2 || true
    if [ "$log_file" != "/dev/null" ]; then
        rm -f "$log_file"
    fi
    echo "[dashboard] Build failed (non-fatal, server will show fallback page)." >&2
}

bootstrap_base_path_config() {
    local base_path="$1"
    local local_masc_dir="$base_path/.masc"
    local local_config_dir="$local_masc_dir/config"

    if [ -n "${MASC_CONFIG_DIR:-}" ]; then
        return 0
    fi
    if [ -d "$local_config_dir" ]; then
        return 0
    fi

    mkdir -p "$local_masc_dir"
    if [ -d "$SCRIPT_DIR/config" ]; then
        cp -R "$SCRIPT_DIR/config" "$local_config_dir"
        echo "[startup] Bootstrapped config into $local_config_dir" >&2
    else
        mkdir -p "$local_config_dir"
        echo "[startup] Repo config/ missing; created empty $local_config_dir" >&2
    fi
}

resolve_repo_env_root() {
    if command -v git >/dev/null 2>&1; then
        local common_dir
        common_dir="$(git -C "$SCRIPT_DIR" rev-parse --git-common-dir 2>/dev/null || true)"
        if [ -n "$common_dir" ]; then
            if [[ "$common_dir" != /* ]]; then
                common_dir="$SCRIPT_DIR/$common_dir"
            fi
            common_dir="$(cd "$(dirname "$common_dir")" && pwd)"
            echo "$common_dir"
            return
        fi
    fi
    echo "$SCRIPT_DIR"
}

is_worktree_checkout() {
    local path="$1"
    local git_dir common_dir

    if ! command -v git >/dev/null 2>&1; then
        return 1
    fi

    git_dir="$(git -C "$path" rev-parse --git-dir 2>/dev/null || true)"
    common_dir="$(git -C "$path" rev-parse --git-common-dir 2>/dev/null || true)"
    if [ -z "$git_dir" ] || [ -z "$common_dir" ]; then
        return 1
    fi

    case "$git_dir" in
        */worktrees/*) return 0 ;;
    esac

    if [ "$git_dir" != "$common_dir" ]; then
        return 0
    fi

    return 1
}

default_port_for_path() {
    local path="$1"
    local checksum port_range_start port_range_size

    if is_worktree_checkout "$path"; then
        checksum="$(printf '%s' "$path" | cksum | cut -d' ' -f1)"
        port_range_start=9100
        port_range_size=900
        echo $((port_range_start + (checksum % port_range_size)))
        return 0
    fi

    echo 8935
}

load_env_file() {
    local path="$1"
    if [ -f "$path" ]; then
        set -a; source "$path" 2>/dev/null || true; set +a
    fi
}

preserve_env_override() {
    local name="$1"
    local flag_var="__PRESERVE_${name}_SET"
    local value_var="__PRESERVE_${name}_VALUE"
    if [ "${!name+x}" = "x" ]; then
        printf -v "$flag_var" '%s' "1"
        printf -v "$value_var" '%s' "${!name}"
    fi
}

restore_env_override() {
    local name="$1"
    local flag_var="__PRESERVE_${name}_SET"
    local value_var="__PRESERVE_${name}_VALUE"
    if [ "${!flag_var:-}" = "1" ]; then
        export "$name=${!value_var}"
    fi
}

REPO_ENV_ROOT="$(resolve_repo_env_root)"

repo_local_config_dir_match() {
    local candidate="${1:-}"
    candidate="${candidate%/}"
    [ -n "$candidate" ] || return 1
    [ "$candidate" = "$REPO_ENV_ROOT/config" ] || [ "$candidate" = "$SCRIPT_DIR/config" ]
}

repo_local_personas_dir_match() {
    local candidate="${1:-}"
    candidate="${candidate%/}"
    [ -n "$candidate" ] || return 1
    [ "$candidate" = "$REPO_ENV_ROOT/config/personas" ] || [ "$candidate" = "$SCRIPT_DIR/config/personas" ]
}

clear_repo_local_config_for_explicit_base_path() {
    local resolved_base_path="$1"
    local resolved_repo_env_root="$REPO_ENV_ROOT"
    local resolved_script_dir="$SCRIPT_DIR"

    if [ "$BASE_PATH_EXPLICIT" != "1" ]; then
        return 0
    fi
    if [ -d "$resolved_repo_env_root" ]; then
        resolved_repo_env_root="$(cd "$resolved_repo_env_root" && pwd -P)"
    fi
    if [ -d "$resolved_script_dir" ]; then
        resolved_script_dir="$(cd "$resolved_script_dir" && pwd -P)"
    fi
    if [ "$resolved_base_path" = "$resolved_repo_env_root" ] || [ "$resolved_base_path" = "$resolved_script_dir" ]; then
        return 0
    fi

    if repo_local_config_dir_match "${MASC_CONFIG_DIR:-}"; then
        echo "[startup] Ignoring repo-local MASC_CONFIG_DIR=${MASC_CONFIG_DIR%/} because --base-path was supplied; defaulting to $resolved_base_path/.masc/config" >&2
        unset MASC_CONFIG_DIR
    fi

    if repo_local_personas_dir_match "${MASC_PERSONAS_DIR:-}"; then
        echo "[startup] Ignoring repo-local MASC_PERSONAS_DIR=${MASC_PERSONAS_DIR%/} because --base-path was supplied; personas will resolve from the active config root" >&2
        unset MASC_PERSONAS_DIR
    fi
}

# Caller-provided env must win over repo-local .env/.env.local files.
for env_name in \
    MASC_STORAGE_TYPE \
    MASC_KEEPER_BOOTSTRAP_ENABLED \
    MASC_MCP_PORT \
    MASC_HOST \
    MASC_BASE_PATH \
    MASC_CONFIG_DIR \
    MASC_PERSONAS_DIR \
    MASC_WS_ENABLED \
    MASC_WEBRTC_ENABLED
do
    preserve_env_override "$env_name"
done

# Load secrets from the user profile; tracked plist files must not embed them.
# NOTE: This intentionally sources ~/.zshenv which may set PATH and other vars.
# For isolated production deploys, use scripts/deploy.sh which loads only
# repo-local env files (config/*.env, .env) to avoid contamination.
load_env_file "$HOME/.zshenv"

# Load repo-local env for development overrides and secrets kept out of user shell.
load_env_file "$REPO_ENV_ROOT/.env"
load_env_file "$REPO_ENV_ROOT/.env.local"
if [ "$REPO_ENV_ROOT" != "$SCRIPT_DIR" ]; then
    load_env_file "$SCRIPT_DIR/.env"
    load_env_file "$SCRIPT_DIR/.env.local"
fi

for env_name in \
    MASC_STORAGE_TYPE \
    MASC_KEEPER_BOOTSTRAP_ENABLED \
    MASC_MCP_PORT \
    MASC_HOST \
    MASC_BASE_PATH \
    MASC_CONFIG_DIR \
    MASC_PERSONAS_DIR \
    MASC_WS_ENABLED \
    MASC_WEBRTC_ENABLED
do
    restore_env_override "$env_name"
done

# Did caller provide --base-path explicitly on CLI?
BASE_PATH_EXPLICIT=0

# Track whether MASC_BASE_PATH is set after shell/env-file restoration.
# This must include ~/.zshenv and repo-local env files, not only caller-provided
# exports, because both paths can accidentally inject a stale parent root.
MASC_BASE_PATH_WAS_SET=0
if [ -n "${MASC_BASE_PATH:-}" ]; then
    MASC_BASE_PATH_WAS_SET=1
fi

raise_open_file_limit() {
    local desired="${MASC_NOFILE_TARGET:-4096}"
    local current hard target

    if ! [[ "$desired" =~ ^[0-9]+$ ]]; then
        echo "Warning: ignoring invalid MASC_NOFILE_TARGET=$desired" >&2
        return 0
    fi

    current="$(ulimit -Sn 2>/dev/null || ulimit -n 2>/dev/null || echo "")"
    hard="$(ulimit -Hn 2>/dev/null || echo "")"
    if ! [[ "$current" =~ ^[0-9]+$ ]]; then
        return 0
    fi

    target="$desired"
    if [[ "$hard" =~ ^[0-9]+$ ]] && [ "$hard" -lt "$target" ]; then
        target="$hard"
    fi

    if [ "$current" -ge "$target" ]; then
        return 0
    fi

    if ulimit -Sn "$target" 2>/dev/null; then
        echo "Raised open-file soft limit: $current -> $target" >&2
    else
        echo "Warning: failed to raise open-file soft limit (current=$current target=$target)" >&2
    fi
}

# Default: enable realtime transports unless explicitly disabled.
if [ -z "${MASC_WS_ENABLED+x}" ]; then
    export MASC_WS_ENABLED=1
fi

if [ -z "${MASC_WEBRTC_ENABLED+x}" ]; then
    export MASC_WEBRTC_ENABLED=1
fi

# Default arguments
PORT="${MASC_MCP_PORT:-8935}"
PORT_EXPLICIT=0
PRINT_PORT_ONLY=0
WORKTREE_PORT_HINT=""
HTTP_MODE="${MASC_MCP_HTTP:-true}"
BASE_PATH="${MASC_BASE_PATH:-${HOME:-$SCRIPT_DIR}}"
HOST="${MASC_HOST:-127.0.0.1}"
# NOTE: Eio is now the default runtime (Lwt deprecated since 2026-01)
EIO_MODE="true"

if [ -n "${MASC_MCP_PORT:-}" ]; then
    PORT_EXPLICIT=1
fi

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --print-port)
            PRINT_PORT_ONLY=1
            shift
            ;;
        --http)
            HTTP_MODE="true"
            shift
            ;;
        --stdio)
            HTTP_MODE="false"
            shift
            ;;
        --eio)
            EIO_MODE="true"
            shift
            ;;
        --lwt)
            echo "Error: Lwt runtime is deprecated since 2026-01." >&2
            echo "Please use Eio (default). Lwt support has been removed." >&2
            exit 1
            ;;
        --port)
            PORT="$2"
            PORT_EXPLICIT=1
            shift 2
            ;;
        --host)
            HOST="$2"
            shift 2
            ;;
        --base-path|--path)
            BASE_PATH="$2"
            BASE_PATH_EXPLICIT=1
            shift 2
            ;;
        *)
            echo "Unknown option: $1" >&2
            echo "Usage: $0 [--print-port] [--stdio] [--http] [--eio] [--lwt] [--host HOST] [--port PORT] [--base-path PATH|--path PATH]" >&2
            echo "Dir-local local-dev launcher: scripts/run-local.sh" >&2
            echo "Note: Eio is the default runtime; --lwt exits with an error." >&2
            exit 1
            ;;
    esac
done

BASE_PATH_RESOLUTION_SOURCE="implicit_repo_root"
if [ "$BASE_PATH_EXPLICIT" = "1" ]; then
    BASE_PATH_RESOLUTION_SOURCE="explicit_cli"
elif [ "$MASC_BASE_PATH_WAS_SET" = "1" ] && is_absolute_path "$BASE_PATH"; then
    BASE_PATH_RESOLUTION_SOURCE="explicit_env"
elif [ -z "${MASC_BASE_PATH:-}" ] && [ -n "${HOME:-}" ] && [ "$BASE_PATH" = "$HOME" ]; then
    BASE_PATH_RESOLUTION_SOURCE="implicit_home"
fi

if [ "$PORT_EXPLICIT" != "1" ]; then
    PORT="$(default_port_for_path "$SCRIPT_DIR")"
    if [ "$PORT" != "8935" ]; then
        WORKTREE_PORT_HINT="Using worktree-derived default port $PORT for $(basename "$SCRIPT_DIR") (override with MASC_MCP_PORT or --port)."
    fi
fi

if [ -z "${MASC_GRPC_PORT:-}" ] && [ "$PORT" != "8935" ]; then
    export MASC_GRPC_PORT="$((PORT + 1))"
fi
if [ -z "${MASC_WS_PORT:-}" ] && [ "$PORT" != "8935" ]; then
    export MASC_WS_PORT="$((PORT + 2))"
fi
if [ -n "$WORKTREE_PORT_HINT" ] && [ "$PORT" != "8935" ]; then
    WORKTREE_PORT_HINT="$WORKTREE_PORT_HINT (gRPC=$MASC_GRPC_PORT, WS=$MASC_WS_PORT)"
fi

if [ "$PRINT_PORT_ONLY" = "1" ]; then
    echo "$PORT"
    exit 0
fi

if [ -n "$WORKTREE_PORT_HINT" ]; then
    echo "$WORKTREE_PORT_HINT" >&2
fi

raise_open_file_limit

# Fast preflight: fail before build/init if requested port is already occupied.
check_port_in_use() {
    local check_port="$1"
    local name="$2"
    if [ -n "$check_port" ] && lsof -iTCP:"$check_port" -sTCP:LISTEN -t >/dev/null 2>&1 && [ "${MASC_ALLOW_PORT_REUSE:-0}" != "1" ]; then
        local listener_pid="$(lsof -iTCP:"$check_port" -sTCP:LISTEN -t 2>/dev/null | head -n 1)"
        local listener_cmd=""
        if [ -n "$listener_pid" ]; then
            listener_cmd="$(ps -p "$listener_pid" -o command= 2>/dev/null || true)"
        fi
        echo "❌ $name Port $check_port already in use; refusing startup before build/init." >&2
        if [ -n "$listener_pid" ]; then
            echo "   Existing listener: pid=$listener_pid ${listener_cmd}" >&2
        fi
        echo "   Stop the existing server, choose another --port, or set MASC_ALLOW_PORT_REUSE=1." >&2
        exit 1
    fi
}

check_port_in_use "$PORT" "HTTP"
check_port_in_use "${MASC_GRPC_PORT:-8936}" "gRPC"
check_port_in_use "${MASC_WS_PORT:-8937}" "WebSocket"

# Dashboard SPA build (Vite) — assets/dashboard/ is no longer committed to git.
# Always attempt the build before server startup so the served bundle matches current sources.
build_dashboard_spa

# Resolve executable path
# Priority: 1. Release binary  2. Local build  3. Workspace build  4. Installed  5. Auto-download
RELEASE_BINARY="$SCRIPT_DIR/masc-mcp-macos-arm64"
WORKSPACE_EXE="$SCRIPT_DIR/../_build/default/masc-mcp/bin/main.exe"
LOCAL_EXE="$SCRIPT_DIR/_build/default/bin/main.exe"
INSTALLED_EXE="$(command -v masc-mcp || true)"
# Eio-based server (main_eio.exe)
WORKSPACE_EIO_EXE="$SCRIPT_DIR/../_build/default/masc-mcp/bin/main_eio.exe"
LOCAL_EIO_EXE="$SCRIPT_DIR/_build/default/bin/main_eio.exe"
WORKSPACE_STDIO_EIO_EXE="$SCRIPT_DIR/../_build/default/masc-mcp/bin/main_stdio_eio.exe"
LOCAL_STDIO_EIO_EXE="$SCRIPT_DIR/_build/default/bin/main_stdio_eio.exe"
MASC_EXE=""
MASC_EIO_EXE=""
MASC_STDIO_EIO_EXE=""

# 1. Pre-downloaded release binary (fastest, no build needed)
if [ -x "$RELEASE_BINARY" ]; then
    MASC_EXE="$RELEASE_BINARY"
# 2. Local build
elif [ -x "$LOCAL_EXE" ]; then
    MASC_EXE="$LOCAL_EXE"
# 3. Workspace build
elif [ -x "$WORKSPACE_EXE" ]; then
    MASC_EXE="$WORKSPACE_EXE"
# 4. System-installed
elif [ -n "$INSTALLED_EXE" ]; then
    MASC_EXE="$INSTALLED_EXE"
fi

if [ -x "$LOCAL_EIO_EXE" ]; then
    MASC_EIO_EXE="$LOCAL_EIO_EXE"
elif [ -x "$WORKSPACE_EIO_EXE" ]; then
    MASC_EIO_EXE="$WORKSPACE_EIO_EXE"
fi

if [ -x "$LOCAL_STDIO_EIO_EXE" ]; then
    MASC_STDIO_EIO_EXE="$LOCAL_STDIO_EIO_EXE"
elif [ -x "$WORKSPACE_STDIO_EIO_EXE" ]; then
    MASC_STDIO_EIO_EXE="$WORKSPACE_STDIO_EIO_EXE"
fi

# 5. Build Eio version if not found (Lwt deprecated, download disabled)
if [ -z "$MASC_EIO_EXE" ]; then
    echo "Building MASC MCP server from source..." >&2
    if ! command -v dune >/dev/null 2>&1; then
        echo "Error: dune not found. Install dune first." >&2
        exit 1
    fi
    if acquire_build_lock; then
        dune build -j "$DUNE_JOBS" --root "$SCRIPT_DIR" bin/main_eio.exe 1>&2
        release_build_lock
    fi
    if [ -x "$LOCAL_EIO_EXE" ]; then
        MASC_EIO_EXE="$LOCAL_EIO_EXE"
    else
        echo "Error: build failed." >&2
        exit 1
    fi
fi

if [ "$HTTP_MODE" = "false" ] && [ -z "$MASC_STDIO_EIO_EXE" ]; then
    echo "Building MASC MCP stdio server from source..." >&2
    if ! command -v dune >/dev/null 2>&1; then
        echo "Error: dune not found. Cannot build stdio server." >&2
        exit 1
    fi
    if acquire_build_lock; then
        dune build -j "$DUNE_JOBS" --root "$SCRIPT_DIR" bin/main_stdio_eio.exe 1>&2
        release_build_lock
    fi
    if [ -x "$LOCAL_STDIO_EIO_EXE" ]; then
        MASC_STDIO_EIO_EXE="$LOCAL_STDIO_EIO_EXE"
    elif [ -x "$WORKSPACE_STDIO_EIO_EXE" ]; then
        MASC_STDIO_EIO_EXE="$WORKSPACE_STDIO_EIO_EXE"
    else
        echo "Error: failed to build stdio server." >&2
        exit 1
    fi
fi

# Rebuild Eio version if sources are newer than the executable (avoids stale binary runs)
# NOTE: Lwt version (main.exe) is deprecated - Eio is now the default
if [ -n "$MASC_EIO_EXE" ] && command -v dune >/dev/null 2>&1; then
    if find "$SCRIPT_DIR/bin" "$SCRIPT_DIR/lib" \
        -type f \( -name '*.ml' -o -name '*.mli' -o -name 'dune' \) \
        -newer "$MASC_EIO_EXE" 2>/dev/null | head -n 1 | grep -q .; then
        if acquire_build_lock; then
            echo "Rebuilding MASC MCP server (stale executable detected)..." >&2
            dune build -j "$DUNE_JOBS" --root "$SCRIPT_DIR" bin/main_eio.exe 1>&2
            release_build_lock
        fi

        if [ -x "$LOCAL_EIO_EXE" ]; then
            MASC_EIO_EXE="$LOCAL_EIO_EXE"
        elif [ -x "$WORKSPACE_EIO_EXE" ]; then
            MASC_EIO_EXE="$WORKSPACE_EIO_EXE"
        fi
    fi
fi

RESOLVED_BASE_PATH="$(resolve_base_path "$BASE_PATH")"
clear_repo_local_config_for_explicit_base_path "$RESOLVED_BASE_PATH"
export MASC_BASE_PATH="$RESOLVED_BASE_PATH"
export MASC_BASE_PATH_RESOLUTION_SOURCE="$BASE_PATH_RESOLUTION_SOURCE"
bootstrap_base_path_config "$RESOLVED_BASE_PATH"
if [ -z "${MASC_CONFIG_DIR:-}" ]; then
    export MASC_CONFIG_DIR="$RESOLVED_BASE_PATH/.masc/config"
fi
# Leave MASC_PERSONAS_DIR unset unless the caller explicitly overrides it.
# The server-side config resolver will then use "$MASC_CONFIG_DIR/personas".

# Wait for port to become available.
# Default behavior is fail-fast on conflict to prevent duplicate server startup.
# To preserve legacy behavior, set MASC_ALLOW_PORT_REUSE=1.
wait_for_port() {
    local port="$1" max_wait="${MASC_PORT_WAIT_MAX_SEC:-10}" waited=0
    while lsof -iTCP:"$port" -sTCP:LISTEN -t >/dev/null 2>&1; do
        if [ "$waited" -ge "$max_wait" ]; then
            local listener_pid listener_cmd
            listener_pid="$(lsof -iTCP:"$port" -sTCP:LISTEN -t 2>/dev/null | head -n 1)"
            listener_cmd=""
            if [ -n "$listener_pid" ]; then
                listener_cmd="$(ps -p "$listener_pid" -o command= 2>/dev/null || true)"
            fi
            if [ "${MASC_ALLOW_PORT_REUSE:-0}" = "1" ]; then
                echo "⚠️ Port $port still in use after ${max_wait}s, but MASC_ALLOW_PORT_REUSE=1 so continuing." >&2
                if [ -n "$listener_pid" ]; then
                    echo "   Existing listener: pid=$listener_pid ${listener_cmd}" >&2
                fi
                return 0
            fi
            echo "❌ Port $port still in use after ${max_wait}s; refusing duplicate startup." >&2
            if [ -n "$listener_pid" ]; then
                echo "   Existing listener: pid=$listener_pid ${listener_cmd}" >&2
            fi
            echo "   Stop the existing server, choose another --port, or set MASC_ALLOW_PORT_REUSE=1." >&2
            return 1
        fi
        echo "⏳ Port $port in use, waiting... (${waited}s/${max_wait}s)" >&2
        sleep 1
        waited=$((waited + 1))
    done
}
if ! wait_for_port "$PORT"; then
    exit 1
fi

# Select executable based on EIO_MODE
SELECTED_EXE="$MASC_EXE"
RUNTIME_NAME="Lwt"

if [ "$EIO_MODE" = "true" ]; then
    RUNTIME_NAME="Eio"
    if [ "$HTTP_MODE" = "true" ] && [ -z "$MASC_EIO_EXE" ]; then
        echo "Building MASC MCP server (Eio mode)..." >&2
        if ! command -v dune >/dev/null 2>&1; then
            echo "Error: dune not found. Cannot build Eio server." >&2
            exit 1
        fi
        if acquire_build_lock; then
            dune build -j "$DUNE_JOBS" --root "$SCRIPT_DIR" bin/main_eio.exe 1>&2
            release_build_lock
        fi
        if [ -x "$WORKSPACE_EIO_EXE" ]; then
            MASC_EIO_EXE="$WORKSPACE_EIO_EXE"
        elif [ -x "$LOCAL_EIO_EXE" ]; then
            MASC_EIO_EXE="$LOCAL_EIO_EXE"
        else
            echo "Error: Failed to build Eio server (main_eio.exe)." >&2
            exit 1
        fi
    fi
    if [ "$HTTP_MODE" = "true" ]; then
        SELECTED_EXE="$MASC_EIO_EXE"
    else
        SELECTED_EXE="$MASC_STDIO_EIO_EXE"
    fi
fi

# Port guard: abort if another process already holds the port.
if [ "$HTTP_MODE" = "true" ]; then
    existing_pid=$(lsof -ti "tcp:$PORT" -sTCP:LISTEN 2>/dev/null | head -1)
    if [ -n "$existing_pid" ]; then
        existing_cmd=$(ps -p "$existing_pid" -o comm= 2>/dev/null || echo "unknown")
        echo "Error: port $PORT already in use by PID $existing_pid ($existing_cmd)." >&2
        echo "  Kill it first:  kill $existing_pid" >&2
        echo "  Or use another port:  MASC_MCP_PORT=8936 $0" >&2
        exit 1
    fi
fi

launch_from_base_path() {
    if ! cd "$RESOLVED_BASE_PATH"; then
        echo "Error: failed to chdir to base path: $RESOLVED_BASE_PATH" >&2
        exit 1
    fi
    if [ -n "${MASC_LOG_FILE:-}" ]; then
        mkdir -p "$(dirname "$MASC_LOG_FILE")"
        echo "  Log file: $MASC_LOG_FILE (stdout+stderr tee'd)" >&2
        set -o pipefail
        exec "$@" 2>&1 | tee -a "$MASC_LOG_FILE"
    else
        exec "$@"
    fi
}

# Eio server has different CLI format and is HTTP-only
if [ "$EIO_MODE" = "true" ] && [ "$HTTP_MODE" = "true" ]; then
    echo "Starting MASC MCP server (HTTP mode, $RUNTIME_NAME)..." >&2
    echo "  Host: $HOST" >&2
    echo "  Port: $PORT" >&2
    echo "  Base path: $RESOLVED_BASE_PATH" >&2
    if [ "$RESOLVED_BASE_PATH" != "$BASE_PATH" ]; then
        echo "  Base path (input): $BASE_PATH" >&2
    fi
    echo "  MASC dir: $RESOLVED_BASE_PATH/.masc" >&2
    if [ -n "${MASC_HTTP_BASE_URL:-}" ]; then
        echo "  MCP endpoint: ${MASC_HTTP_BASE_URL%/}/mcp" >&2
    else
        echo "  MCP endpoint: /mcp (set MASC_HTTP_BASE_URL for an absolute origin)" >&2
    fi
    echo "  MCP Accept: application/json, text/event-stream" >&2
    echo "  Legacy Accept fallback: MASC_ALLOW_LEGACY_ACCEPT=1" >&2
    launch_from_base_path "$SELECTED_EXE" --host="$HOST" --port="$PORT" --base-path="$RESOLVED_BASE_PATH"
elif [ "$HTTP_MODE" = "true" ]; then
    echo "Starting MASC MCP server (HTTP mode, $RUNTIME_NAME)..." >&2
    echo "  Host: $HOST" >&2
    echo "  Port: $PORT" >&2
    echo "  Base path: $RESOLVED_BASE_PATH" >&2
    if [ "$RESOLVED_BASE_PATH" != "$BASE_PATH" ]; then
        echo "  Base path (input): $BASE_PATH" >&2
    fi
    echo "  MASC dir: $RESOLVED_BASE_PATH/.masc" >&2
    if [ -n "${MASC_HTTP_BASE_URL:-}" ]; then
        echo "  MCP endpoint: ${MASC_HTTP_BASE_URL%/}/mcp" >&2
    else
        echo "  MCP endpoint: /mcp (set MASC_HTTP_BASE_URL for an absolute origin)" >&2
    fi
    echo "  MCP Accept: application/json, text/event-stream" >&2
    echo "  Legacy Accept fallback: MASC_ALLOW_LEGACY_ACCEPT=1" >&2
    launch_from_base_path "$SELECTED_EXE" --http --port "$PORT" --path "$RESOLVED_BASE_PATH"
else
    echo "Starting MASC MCP server (stdio mode, $RUNTIME_NAME)..." >&2
    echo "  Base path: $RESOLVED_BASE_PATH" >&2
    if [ "$RESOLVED_BASE_PATH" != "$BASE_PATH" ]; then
        echo "  Base path (input): $BASE_PATH" >&2
    fi
    echo "  MASC dir: $RESOLVED_BASE_PATH/.masc" >&2
    if [ "$EIO_MODE" = "true" ]; then
        launch_from_base_path "$SELECTED_EXE" --base-path "$RESOLVED_BASE_PATH"
    else
        launch_from_base_path "$SELECTED_EXE" --stdio --path "$RESOLVED_BASE_PATH"
    fi
fi
