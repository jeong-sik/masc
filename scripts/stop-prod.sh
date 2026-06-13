#!/bin/bash
# MASC MCP — Stop Prod Instance
# Stops the prod MASC running on :8945.
# Handles both launchd and manual (PID file) management modes.
#
# Usage: ./scripts/stop-prod.sh [--force]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
PID_FILE="$REPO_DIR/masc-prod.pid"
PROD_PORT=8945
LAUNCHD_LABEL="com.jeong-sik.masc-prod"
LAUNCHD_PLIST="$HOME/Library/LaunchAgents/${LAUNCHD_LABEL}.plist"
FORCE=false

[[ "${1:-}" == "--force" ]] && FORCE=true

# --- 1. Try launchd first ---
if launchctl list "$LAUNCHD_LABEL" >/dev/null 2>&1; then
    echo "Stopping launchd service ($LAUNCHD_LABEL)..." >&2
    launchctl unload "$LAUNCHD_PLIST" 2>/dev/null || true
    # Wait for port to free
    for _ in $(seq 1 10); do
        lsof -iTCP:"$PROD_PORT" -sTCP:LISTEN -t >/dev/null 2>&1 || break
        sleep 0.5
    done
    echo "Stopped (launchd unloaded)." >&2
    echo "To restart: launchctl load $LAUNCHD_PLIST" >&2
    exit 0
fi

# --- 2. Try PID file ---
if [ -f "$PID_FILE" ]; then
    PID="$(cat "$PID_FILE")"
    if kill -0 "$PID" 2>/dev/null; then
        echo "Stopping prod MASC (PID $PID, port :$PROD_PORT)..." >&2
        if [ "$FORCE" = true ]; then
            kill -9 "$PID"
        else
            kill "$PID"
            for _ in $(seq 1 10); do
                kill -0 "$PID" 2>/dev/null || break
                sleep 0.5
            done
            if kill -0 "$PID" 2>/dev/null; then
                echo "Process did not exit cleanly, force killing..." >&2
                kill -9 "$PID" 2>/dev/null || true
            fi
        fi
        rm -f "$PID_FILE"
        echo "Stopped." >&2
        exit 0
    else
        echo "PID $PID is not running. Cleaning up PID file." >&2
        rm -f "$PID_FILE"
    fi
fi

# --- 3. Fallback: check port ---
PORT_PID="$(lsof -iTCP:$PROD_PORT -sTCP:LISTEN -t 2>/dev/null || true)"
if [ -n "$PORT_PID" ]; then
    echo "Process $PORT_PID is listening on :$PROD_PORT." >&2
    if [ "$FORCE" = true ]; then
        echo "Killing PID $PORT_PID (--force)..." >&2
        kill "$PORT_PID"
        echo "Stopped." >&2
    else
        echo "Use --force to kill it." >&2
    fi
else
    echo "Nothing running on :$PROD_PORT." >&2
fi
