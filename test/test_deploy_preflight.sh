#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FIXTURE_DIR="$(mktemp -d)"
SLEEP_PID=""

cleanup() {
    if [ -n "$SLEEP_PID" ]; then
        kill "$SLEEP_PID" 2>/dev/null || true
        wait "$SLEEP_PID" 2>/dev/null || true
    fi
    rm -rf "$FIXTURE_DIR"
}
trap cleanup EXIT

mkdir -p \
    "$FIXTURE_DIR/repo/scripts" \
    "$FIXTURE_DIR/repo/config" \
    "$FIXTURE_DIR/repo/_build/default/bin" \
    "$FIXTURE_DIR/runtime/.masc/logs"
cp "$ROOT_DIR/scripts/deploy.sh" "$FIXTURE_DIR/repo/scripts/deploy.sh"
touch \
    "$FIXTURE_DIR/repo/_build/default/bin/main_eio.exe" \
    "$FIXTURE_DIR/repo/_build/default/bin/keeper_event_queue_v15_cutover_helper.exe"
chmod +x \
    "$FIXTURE_DIR/repo/scripts/deploy.sh" \
    "$FIXTURE_DIR/repo/_build/default/bin/main_eio.exe" \
    "$FIXTURE_DIR/repo/_build/default/bin/keeper_event_queue_v15_cutover_helper.exe"
printf '%s\n' 'false' > "$FIXTURE_DIR/repo/config/keeper.env"

sleep 30 &
SLEEP_PID=$!
printf '%s\n' "$SLEEP_PID" > "$FIXTURE_DIR/runtime/.masc/masc-prod.pid"

if MASC_BASE_PATH="$FIXTURE_DIR/runtime" \
    bash "$FIXTURE_DIR/repo/scripts/deploy.sh" --skip-build
then
    echo "expected invalid keeper.env to reject deployment" >&2
    exit 1
fi

if ! kill -0 "$SLEEP_PID" 2>/dev/null; then
    echo "deployment stopped the serving process before env validation" >&2
    exit 1
fi

echo "deploy preflight preserves the serving process on env failure"

# An env file entry reusing a deployment control name must abort the deploy
# before the stop step instead of redirecting which PID gets killed.
printf 'PID_FILE=%s\n' "$FIXTURE_DIR/hijack.pid" \
    > "$FIXTURE_DIR/repo/config/keeper.env"

OVERRIDE_ERR="$FIXTURE_DIR/deploy-override.err"
if MASC_BASE_PATH="$FIXTURE_DIR/runtime" \
    bash "$FIXTURE_DIR/repo/scripts/deploy.sh" --skip-build 2>"$OVERRIDE_ERR"
then
    echo "expected control-variable override in keeper.env to reject deployment" >&2
    exit 1
fi

if ! grep -q "readonly variable" "$OVERRIDE_ERR"; then
    echo "deployment failed for a reason other than the control-variable freeze" >&2
    cat "$OVERRIDE_ERR" >&2
    exit 1
fi

if ! kill -0 "$SLEEP_PID" 2>/dev/null; then
    echo "deployment stopped the serving process on control-variable override" >&2
    exit 1
fi

echo "deploy preflight rejects control-variable overrides before touching prod"
