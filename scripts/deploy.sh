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
# Management mode: manual, using nohup + PID file. A loaded launchd service is
# rejected because it cannot participate in the atomic BasePath lease handoff.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
RELEASE_DIR="$REPO_DIR/releases"
PROD_PORT=8945
HEALTH_URL="http://127.0.0.1:$PROD_PORT/health"
default_base_path() {
    if [ -n "${MASC_BASE_PATH:-}" ]; then
        printf '%s\n' "$MASC_BASE_PATH"
    else
        printf '%s\n' "$REPO_DIR"
    fi
}
BASE_PATH="$(default_base_path)"
RUNTIME_ROOT="${BASE_PATH}/.masc"
PID_FILE="${RUNTIME_ROOT}/masc-prod.pid"
LOG_DIR="${RUNTIME_ROOT}/logs"
LAUNCHD_LABEL="com.jeong-sik.masc-prod"

SKIP_BUILD=false
RESTART_TUNNEL=false
PREPARE_UNDER_CUTOVER_LEASE=false

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
        --prepare-under-cutover-lease) PREPARE_UNDER_CUTOVER_LEASE=true; shift ;;
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
    "$REPO_DIR/scripts/dune-local.sh" build \
        bin/main_eio.exe \
        bin/keeper_event_queue_v15_cutover_helper.exe \
        2>&1
    echo "    Build complete." >&2
fi

BUILD_EXE="$REPO_DIR/_build/default/bin/main_eio.exe"
BUILD_CUTOVER_HELPER="$REPO_DIR/_build/default/bin/keeper_event_queue_v15_cutover_helper.exe"
if [ ! -x "$BUILD_EXE" ]; then
    echo "Error: Build artifact not found at $BUILD_EXE" >&2
    exit 1
fi
if [ ! -x "$BUILD_CUTOVER_HELPER" ]; then
    echo "Error: Event-queue cutover helper not found at $BUILD_CUTOVER_HELPER" >&2
    exit 1
fi

prepare_release_under_cutover_lease() {
    MASC_EVENT_QUEUE_V15_CUTOVER_HELPER="$BUILD_CUTOVER_HELPER" \
        "$SCRIPT_DIR/check-keeper-event-queue-v15-cutover.sh" \
        --base-path "$BASE_PATH"

    mkdir -p "$RELEASE_DIR"
    if [ -f "$RELEASE_EXE" ]; then
        rm -f "$BACKUP_EXE"
        mv "$RELEASE_EXE" "$BACKUP_EXE"
        echo "    Previous binary backed up." >&2
    fi
    install -m 755 "$BUILD_EXE" "$RELEASE_EXE"
    echo "    Binary installed to releases/main_eio.exe" >&2
}

mkdir -p "$RELEASE_DIR"
RELEASE_EXE="$RELEASE_DIR/main_eio.exe"
BACKUP_EXE="$RELEASE_DIR/main_eio.exe.prev"

if [ "$PREPARE_UNDER_CUTOVER_LEASE" = true ]; then
    prepare_release_under_cutover_lease
    exit 0
fi

# --- 2. Detect management mode ---
if launchctl list "$LAUNCHD_LABEL" >/dev/null 2>&1; then
    echo "Error: loaded launchd service cannot receive the atomic BasePath lease handoff" >&2
    echo "       Unload $LAUNCHD_LABEL and deploy in manual mode." >&2
    exit 1
fi

# --- 3. Stop existing prod (must stop before overwriting binary on macOS) ---
if [ -f "$PID_FILE" ]; then
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

# --- 4. Prepare release and atomically hand the lease to the new runtime ---
# The helper keeps the POSIX process lock while its preparation child validates
# and installs the release, then execs the new runtime in that same process.
# There is no unlock/reacquire window in which an older writer can enter.
echo "==> Starting prod on :$PROD_PORT with atomic cutover lease handoff..." >&2

# Load secrets needed at runtime (GRAPHQL_API_KEY, SSL_CERT_FILE, etc.)
# Only repo-local env files are loaded; ~/.zshenv is intentionally skipped
# to avoid environment contamination from user shell configuration.
preserve_env_override MASC_CONFIG_DIR
preserve_env_override MASC_PERSONAS_DIR
KEEPER_ENV="$REPO_DIR/config/keeper.env"
if [ -f "$KEEPER_ENV" ]; then
    set -a
    # shellcheck disable=SC1090
    source "$KEEPER_ENV"
    set +a
fi
if [ -f "$REPO_DIR/.env" ]; then
    set -a
    # shellcheck disable=SC1091
    source "$REPO_DIR/.env"
    set +a
fi
restore_env_override MASC_CONFIG_DIR
restore_env_override MASC_PERSONAS_DIR

if [ ! -d "$RUNTIME_ROOT" ] || [ -L "$RUNTIME_ROOT" ]; then
    echo "Error: deployment requires an existing exact runtime directory at $RUNTIME_ROOT" >&2
    exit 1
fi
mkdir -p "$LOG_DIR"

HANDOFF_DIR="$(mktemp -d "$RUNTIME_ROOT/deploy-handoff.XXXXXX")"
PREPARED_FILE="$HANDOFF_DIR/prepared"
HANDOFF_ACTIVE=true

cleanup_incomplete_handoff() {
    if [ "$HANDOFF_ACTIVE" = true ] && [ -n "${PROD_PID:-}" ]; then
        kill "$PROD_PID" 2>/dev/null || true
        wait "$PROD_PID" 2>/dev/null || true
        if [ -f "$PID_FILE" ] && [ "$(cat "$PID_FILE")" = "$PROD_PID" ]; then
            rm -f "$PID_FILE"
        fi
    fi
    rm -f "$PREPARED_FILE"
    rmdir "$HANDOFF_DIR" 2>/dev/null || true
}

trap cleanup_incomplete_handoff EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

MASC_BASE_PATH="$BASE_PATH" \
MASC_ORCHESTRATOR_ENABLED=0 \
MASC_CONFIG_DIR="${MASC_CONFIG_DIR:-$BASE_PATH/.masc/config}" \
MASC_EVENT_QUEUE_V15_CUTOVER_HELPER="$BUILD_CUTOVER_HELPER" \
    nohup "$BUILD_CUTOVER_HELPER" \
        lease-handoff \
        --base-path "$BASE_PATH" \
        --next-executable "$RELEASE_EXE" \
        --next-argument="--port=$PROD_PORT" \
        --next-argument="--base-path=$BASE_PATH" \
        --prepared-file "$PREPARED_FILE" \
        -- \
        "$SCRIPT_DIR/deploy.sh" \
        --skip-build \
        --prepare-under-cutover-lease \
    >> "$LOG_DIR/masc-prod.out.log" \
    2>> "$LOG_DIR/masc-prod.err.log" &

PROD_PID=$!
echo "$PROD_PID" > "$PID_FILE"
echo "    Handoff started with PID $PROD_PID" >&2

# Validation and installation are intentionally unbounded: the health deadline
# starts only after the helper proves preparation completed. A failed helper is
# reaped here, and the EXIT trap terminates its preparation child if interrupted.
echo "==> Waiting for cutover preparation..." >&2
while [ ! -f "$PREPARED_FILE" ]; do
    if ! kill -0 "$PROD_PID" 2>/dev/null; then
        if wait "$PROD_PID"; then
            HANDOFF_STATUS=0
        else
            HANDOFF_STATUS=$?
        fi
        echo "Error: Cutover preparation exited with status $HANDOFF_STATUS" >&2
        exit 1
    fi
    sleep 0.1
done
rm -f "$PREPARED_FILE"
rmdir "$HANDOFF_DIR"

# --- 5. Health check ---
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
    HANDOFF_ACTIVE=false
    trap - EXIT INT TERM
    echo "    Prod healthy on :$PROD_PORT" >&2
else
    echo "Error: Prod failed health check on :$PROD_PORT" >&2
    echo "    Logs: $LOG_DIR/masc-prod.err.log" >&2

    echo "    Previous binary remains at $BACKUP_EXE; it was not restarted across the hard cut." >&2
    exit 1
fi

# --- 6. Restart Cloudflare tunnel (optional) ---
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
echo "  PID: ${PROD_PID:-?} ($PID_FILE)" >&2
echo "  Logs: $LOG_DIR/masc-prod.{out,err}.log" >&2
