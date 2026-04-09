#!/bin/bash
# MASC MCP — Deploy to Prod (:8945)
# Builds, stops existing, copies binary to releases/, starts prod, verifies health.
#
# Usage: ./scripts/deploy.sh [--skip-build] [--restart-tunnel]
#
# Ports:
#   Dev:  8935 (launchd, live development)
#   Prod: 8945 (this script, Cloudflare tunnel target)
#
# Management modes:
#   manual: preferred default, uses nohup + PID file
#   launchd: optional legacy mode if com.jeong-sik.masc-mcp-prod is already loaded

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
RELEASE_DIR="$REPO_DIR/releases"
PID_FILE="$REPO_DIR/masc-prod.pid"
PROD_PORT=8945
HEALTH_URL="http://127.0.0.1:$PROD_PORT/health"
BASE_PATH="${MASC_BASE_PATH:-${HOME}/me}"
LOG_DIR="${BASE_PATH}/logs"
LAUNCHD_LABEL="com.jeong-sik.masc-mcp-prod"
LAUNCHD_PLIST="$HOME/Library/LaunchAgents/${LAUNCHD_LABEL}.plist"

SKIP_BUILD=false
RESTART_TUNNEL=false

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

while [[ $# -gt 0 ]]; do
    case $1 in
        --skip-build) SKIP_BUILD=true; shift ;;
        --restart-tunnel) RESTART_TUNNEL=true; shift ;;
        *) echo "Unknown option: $1" >&2; exit 1 ;;
    esac
done

wait_port_free() {
    for _ in $(seq 1 10); do
        lsof -iTCP:"$PROD_PORT" -sTCP:LISTEN -t >/dev/null 2>&1 || return 0
        sleep 0.5
    done
}

# --- 1. Build ---
if [ "$SKIP_BUILD" = false ]; then
    echo "==> Building MASC MCP..." >&2
    cd "$REPO_DIR"
    dune build --root "$REPO_DIR" bin/main_eio.exe 2>&1
    echo "    Build complete." >&2
fi

BUILD_EXE="$REPO_DIR/_build/default/bin/main_eio.exe"
if [ ! -x "$BUILD_EXE" ]; then
    echo "Error: Build artifact not found at $BUILD_EXE" >&2
    exit 1
fi

# --- 2. Detect management mode ---
USE_LAUNCHD=false
if launchctl list "$LAUNCHD_LABEL" >/dev/null 2>&1; then
    USE_LAUNCHD=true
fi

# --- 3. Stop existing prod (must stop before overwriting binary on macOS) ---
mkdir -p "$RELEASE_DIR"
RELEASE_EXE="$RELEASE_DIR/main_eio.exe"
BACKUP_EXE="$RELEASE_DIR/main_eio.exe.prev"

if [ "$USE_LAUNCHD" = true ]; then
    echo "==> Stopping launchd service..." >&2
    launchctl unload "$LAUNCHD_PLIST" 2>/dev/null || true
    wait_port_free
    echo "    Service stopped." >&2
elif [ -f "$PID_FILE" ]; then
    OLD_PID="$(cat "$PID_FILE")"
    if kill -0 "$OLD_PID" 2>/dev/null; then
        echo "==> Stopping previous prod (PID $OLD_PID)..." >&2
        kill "$OLD_PID"
        for _ in $(seq 1 10); do
            kill -0 "$OLD_PID" 2>/dev/null || break
            sleep 0.5
        done
        if kill -0 "$OLD_PID" 2>/dev/null; then
            kill -9 "$OLD_PID" 2>/dev/null || true
        fi
    fi
    rm -f "$PID_FILE"
    wait_port_free
fi

# --- 4. Copy binary to releases/ ---
# Note: dune produces read-only executables. Use install(1) which handles
# permission replacement, or rm-before-cp to avoid "Permission denied".
if [ -f "$RELEASE_EXE" ]; then
    rm -f "$BACKUP_EXE"
    mv "$RELEASE_EXE" "$BACKUP_EXE"
    echo "    Previous binary backed up." >&2
fi

install -m 755 "$BUILD_EXE" "$RELEASE_EXE"
echo "    Binary installed to releases/main_eio.exe" >&2

# --- 5. Start prod ---
if [ "$USE_LAUNCHD" = true ]; then
    echo "==> Starting via launchd..." >&2
    launchctl load "$LAUNCHD_PLIST"
    echo "    Service loaded." >&2
else
    echo "==> Starting prod on :$PROD_PORT..." >&2

    # Load secrets needed at runtime (GRAPHQL_API_KEY, SSL_CERT_FILE, etc.)
    # Only repo-local env files are loaded; ~/.zshenv is intentionally skipped
    # to avoid environment contamination from user shell configuration.
    # Required env vars should be set in config/keeper.env or the repo .env files.
    preserve_env_override MASC_CONFIG_DIR
    preserve_env_override MASC_PERSONAS_DIR
    KEEPER_ENV="$REPO_DIR/config/keeper.env"
    if [ -f "$KEEPER_ENV" ]; then
        set -a; source "$KEEPER_ENV" 2>/dev/null || true; set +a
    fi
    if [ -f "$REPO_DIR/.env" ]; then
        set -a; source "$REPO_DIR/.env" 2>/dev/null || true; set +a
    fi
    restore_env_override MASC_CONFIG_DIR
    restore_env_override MASC_PERSONAS_DIR

    mkdir -p "$LOG_DIR"

    MASC_ORCHESTRATOR_ENABLED=0 \
    MASC_AUTO_RESPOND=true \
    MASC_CONFIG_DIR="${MASC_CONFIG_DIR:-$REPO_DIR/config}" \
        nohup "$RELEASE_EXE" \
            --port="$PROD_PORT" \
            --base-path="$BASE_PATH" \
        >> "$LOG_DIR/masc-prod.out.log" \
        2>> "$LOG_DIR/masc-prod.err.log" &

    PROD_PID=$!
    echo "$PROD_PID" > "$PID_FILE"
    echo "    Started with PID $PROD_PID" >&2
fi

# --- 6. Health check ---
echo "==> Health check..." >&2
HEALTH_OK=false
for _ in $(seq 1 15); do
    sleep 0.5
    if curl -sf "$HEALTH_URL" >/dev/null 2>&1; then
        HEALTH_OK=true
        break
    fi
done

if [ "$HEALTH_OK" = true ]; then
    echo "    Prod healthy on :$PROD_PORT" >&2
else
    echo "Error: Prod failed health check on :$PROD_PORT" >&2
    echo "    Logs: $LOG_DIR/masc-prod.err.log" >&2

    # Rollback
    if [ "$USE_LAUNCHD" = true ]; then
        launchctl unload "$LAUNCHD_PLIST" 2>/dev/null || true
    else
        kill "${PROD_PID:-0}" 2>/dev/null || true
        rm -f "$PID_FILE"
    fi

    if [ -f "$BACKUP_EXE" ]; then
        echo "    Rolling back to previous binary..." >&2
        mv "$BACKUP_EXE" "$RELEASE_EXE"
        # Restart with previous binary
        if [ "$USE_LAUNCHD" = true ]; then
            launchctl load "$LAUNCHD_PLIST"
        else
            echo "    Restarting previous binary on :$PROD_PORT..." >&2
            if [ -f "$HOME/.zshenv" ]; then
                set -a; source "$HOME/.zshenv" 2>/dev/null || true; set +a
            fi
            MASC_ORCHESTRATOR_ENABLED=0 \
            MASC_AUTO_RESPOND=true \
            MASC_CONFIG_DIR="${MASC_CONFIG_DIR:-$REPO_DIR/config}" \
                nohup "$RELEASE_EXE" \
                    --port="$PROD_PORT" \
                    --base-path="$BASE_PATH" \
                >> "$LOG_DIR/masc-prod.out.log" \
                2>> "$LOG_DIR/masc-prod.err.log" &
            ROLLBACK_PID=$!
            echo "$ROLLBACK_PID" > "$PID_FILE"
            echo "    Rollback started with PID $ROLLBACK_PID" >&2
        fi
    fi
    exit 1
fi

# --- 7. Restart Cloudflare tunnel (optional) ---
if [ "$RESTART_TUNNEL" = true ]; then
    echo "==> Restarting Cloudflare tunnel..." >&2
    launchctl kickstart -k "gui/$(id -u)/com.jeongsik.masc-cloudflared" 2>/dev/null || true
    echo "    Tunnel restarted." >&2
fi

# --- Done ---
echo "" >&2
echo "Deploy complete." >&2
echo "  Prod: http://127.0.0.1:$PROD_PORT" >&2
echo "  Tunnel: https://masc.crying.pictures" >&2
if [ "$USE_LAUNCHD" = true ]; then
    echo "  Managed by: launchd ($LAUNCHD_LABEL)" >&2
else
    echo "  PID: ${PROD_PID:-?} ($PID_FILE)" >&2
fi
echo "  Logs: $LOG_DIR/masc-prod.{out,err}.log" >&2
