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
    "$FIXTURE_DIR/repo/_build/default/bin/deployment_preflight_helper.exe"
chmod +x \
    "$FIXTURE_DIR/repo/scripts/deploy.sh" \
    "$FIXTURE_DIR/repo/_build/default/bin/main_eio.exe" \
    "$FIXTURE_DIR/repo/_build/default/bin/deployment_preflight_helper.exe"
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

# The new build refuses the live runtime.toml before the stop step, so the
# serving process keeps running and its editor can still change the value
# (#39311). The helper here stands in for one that refuses the file.
printf '' > "$FIXTURE_DIR/repo/config/keeper.env"
cp "$ROOT_DIR/scripts/check-runtime-deployment-preflight.sh" \
    "$FIXTURE_DIR/repo/scripts/check-runtime-deployment-preflight.sh"
chmod +x "$FIXTURE_DIR/repo/scripts/check-runtime-deployment-preflight.sh"
cat > "$FIXTURE_DIR/repo/_build/default/bin/deployment_preflight_helper.exe" <<'HELPER'
#!/usr/bin/env bash
case "$1" in
    build-commit) echo fixture-commit ;;
    durable-filenames) printf 'snapshot=fixture-snapshot.json\nwal=fixture-wal.jsonl\n' ;;
    validate-runtime-config)
        echo "runtime.toml refused path=fixture/runtime.toml: fixture refusal"
        exit 1
        ;;
    *) echo "unexpected helper call: $*" >&2; exit 2 ;;
esac
HELPER
chmod +x "$FIXTURE_DIR/repo/_build/default/bin/deployment_preflight_helper.exe"

RUNTIME_CONFIG_ERR="$FIXTURE_DIR/deploy-runtime-config.err"
if MASC_BASE_PATH="$FIXTURE_DIR/runtime" \
    bash "$FIXTURE_DIR/repo/scripts/deploy.sh" --skip-build \
    >"$FIXTURE_DIR/deploy-runtime-config.out" 2>"$RUNTIME_CONFIG_ERR"
then
    echo "expected a refused runtime.toml to reject deployment" >&2
    exit 1
fi

if ! grep -q "nothing was stopped or installed" "$RUNTIME_CONFIG_ERR"; then
    echo "deployment failed for a reason other than the runtime.toml check" >&2
    cat "$RUNTIME_CONFIG_ERR" >&2
    exit 1
fi

if ! kill -0 "$SLEEP_PID" 2>/dev/null; then
    echo "deployment stopped the serving process before the runtime.toml check" >&2
    exit 1
fi

echo "deploy preflight refuses runtime.toml before stopping prod"

# scripts/install-local-build.sh runs the same check before it replaces any
# binary, with the same refusing helper.
cp "$ROOT_DIR/scripts/install-local-build.sh" \
    "$FIXTURE_DIR/repo/scripts/install-local-build.sh"
touch \
    "$FIXTURE_DIR/repo/_build/default/bin/masc_tui.exe" \
    "$FIXTURE_DIR/repo/_build/default/bin/masc_browser_host.exe"
chmod +x \
    "$FIXTURE_DIR/repo/_build/default/bin/masc_tui.exe" \
    "$FIXTURE_DIR/repo/_build/default/bin/masc_browser_host.exe"

INSTALL_ERR="$FIXTURE_DIR/install-local-build.err"
if bash "$FIXTURE_DIR/repo/scripts/install-local-build.sh" \
    --skip-build \
    --prefix "$FIXTURE_DIR/prefix" \
    --manifest-dir "$FIXTURE_DIR/manifests" \
    --base-path "$FIXTURE_DIR/runtime" \
    >/dev/null 2>"$INSTALL_ERR"
then
    echo "expected a refused runtime.toml to reject the local install" >&2
    exit 1
fi

if ! grep -q "nothing was stopped or installed" "$INSTALL_ERR"; then
    echo "local install failed for a reason other than the runtime.toml check" >&2
    cat "$INSTALL_ERR" >&2
    exit 1
fi

if [ -e "$FIXTURE_DIR/prefix" ]; then
    echo "local install replaced binaries before the runtime.toml check" >&2
    exit 1
fi

echo "local install refuses runtime.toml before replacing binaries"
