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
sleep 30 &
SLEEP_PID=$!
printf '%s\n' "$SLEEP_PID" > "$FIXTURE_DIR/runtime/.masc/masc-prod.pid"

# The new build refuses the live runtime.toml before the stop step, so the
# serving process keeps running and its editor can still change the value
# (#39311). The helper here stands in for one that refuses the file.
cp "$ROOT_DIR/scripts/check-runtime-deployment-preflight.sh" \
    "$FIXTURE_DIR/repo/scripts/check-runtime-deployment-preflight.sh"
chmod +x "$FIXTURE_DIR/repo/scripts/check-runtime-deployment-preflight.sh"
cat > "$FIXTURE_DIR/repo/_build/default/bin/deployment_preflight_helper.exe" <<'HELPER'
#!/usr/bin/env bash
case "$1" in
    build-commit) echo fixture-commit ;;
    durable-filenames) printf 'snapshot=fixture-snapshot.json\nwal=fixture-wal.jsonl\n' ;;
    resolve-workspace)
        printf 'workspace=resolved\nroot=%s\nsource=explicit_cli\n' "$3"
        ;;
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
# The install asks for the three browser Add-on programs unless it is told
# --no-browser-addon, and this case means to reach the runtime.toml check.
INSTALL_BINARIES=(
    "$FIXTURE_DIR/repo/_build/default/bin/masc_tui.exe"
    "$FIXTURE_DIR/repo/_build/default/bin/masc_browser_host.exe"
    "$FIXTURE_DIR/repo/_build/default/bin/masc_native_addon_launcher.exe"
    "$FIXTURE_DIR/repo/_build/default/bin/masc_browser_addon_worker.exe"
    "$FIXTURE_DIR/repo/_build/default/bin/masc_browser_process_owner.exe"
)
touch "${INSTALL_BINARIES[@]}"
chmod +x "${INSTALL_BINARIES[@]}"

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

# A workspace with a browser lane host and no browser Add-on declaration is
# refused in the same before-the-stop pass, with the helper standing in for one
# that accepts runtime.toml and refuses the missing declaration. A helper that
# accepts both passes the pass.
echo "deploy preflight refuses a browser host with no Add-on declaration before stopping prod"

write_helper() {
    cat > "$FIXTURE_DIR/repo/_build/default/bin/deployment_preflight_helper.exe" <<HELPER
#!/usr/bin/env bash
case "\$1" in
    build-commit) echo fixture-commit ;;
    durable-filenames) printf 'snapshot=fixture-snapshot.json\\nwal=fixture-wal.jsonl\\n' ;;
    validate-runtime-config) echo "runtime.toml ok" ;;
    validate-browser-addon)
        if [ "\$2" = --help ]; then exit 0; fi
        if [ "$1" = refuse ]; then
            echo "a browser lane host is installed and no browser Add-on declaration is saved" >&2
            exit 1
        fi
        echo "browser Add-on declared id=fixture"
        ;;
    *) echo "unexpected helper call: \$*" >&2; exit 2 ;;
esac
HELPER
    chmod +x "$FIXTURE_DIR/repo/_build/default/bin/deployment_preflight_helper.exe"
}

GATE="$FIXTURE_DIR/repo/scripts/check-runtime-deployment-preflight.sh"
BROWSER_ERR="$FIXTURE_DIR/browser-addon.err"

write_helper refuse
if MASC_DEPLOYMENT_PREFLIGHT_HELPER="$FIXTURE_DIR/repo/_build/default/bin/deployment_preflight_helper.exe" \
    bash "$GATE" --base-path "$FIXTURE_DIR/runtime" --runtime-config-only \
    >/dev/null 2>"$BROWSER_ERR"
then
    echo "expected a browser host with no Add-on declaration to be refused" >&2
    exit 1
fi
if ! grep -q "no browser Add-on declaration" "$BROWSER_ERR" \
    || ! grep -q "nothing was stopped or installed" "$BROWSER_ERR"; then
    echo "the refusal does not say what is missing and that nothing was stopped" >&2
    cat "$BROWSER_ERR" >&2
    exit 1
fi

write_helper accept
if ! MASC_DEPLOYMENT_PREFLIGHT_HELPER="$FIXTURE_DIR/repo/_build/default/bin/deployment_preflight_helper.exe" \
    bash "$GATE" --base-path "$FIXTURE_DIR/runtime" --runtime-config-only \
    >/dev/null 2>"$BROWSER_ERR"
then
    echo "expected a declared browser Add-on to pass the before-the-stop pass" >&2
    cat "$BROWSER_ERR" >&2
    exit 1
fi

echo "deploy preflight accepts a declared browser Add-on"

# A caller that writes the declaration itself after this check (the local
# install) names that, and the check does not refuse the declaration the caller
# is about to write.
write_helper refuse
if ! MASC_DEPLOYMENT_PREFLIGHT_HELPER="$FIXTURE_DIR/repo/_build/default/bin/deployment_preflight_helper.exe" \
    bash "$GATE" --base-path "$FIXTURE_DIR/runtime" --runtime-config-only --browser-addon-declared-by-caller \
    >/dev/null 2>"$BROWSER_ERR"
then
    echo "expected a caller that declares the Add-on itself to pass the before-the-stop pass" >&2
    cat "$BROWSER_ERR" >&2
    exit 1
fi

echo "deploy preflight leaves the declaration to a caller that writes it"

# A helper built before the check has no such command. The gate says so rather
# than reading cmdliner's usage error as a refusal of the workspace.
cat > "$FIXTURE_DIR/repo/_build/default/bin/deployment_preflight_helper.exe" <<'HELPER'
#!/usr/bin/env bash
case "$1" in
    build-commit) echo fixture-commit ;;
    durable-filenames) printf 'snapshot=fixture-snapshot.json\nwal=fixture-wal.jsonl\n' ;;
    validate-runtime-config) echo "runtime.toml ok" ;;
    *) echo "unknown command: $1" >&2; exit 124 ;;
esac
HELPER
chmod +x "$FIXTURE_DIR/repo/_build/default/bin/deployment_preflight_helper.exe"
if MASC_DEPLOYMENT_PREFLIGHT_HELPER="$FIXTURE_DIR/repo/_build/default/bin/deployment_preflight_helper.exe" \
    bash "$GATE" --base-path "$FIXTURE_DIR/runtime" --runtime-config-only \
    >/dev/null 2>"$BROWSER_ERR"
then
    echo "expected a helper without the browser Add-on check to be refused" >&2
    exit 1
fi
if ! grep -q "predates the browser Add-on check" "$BROWSER_ERR"; then
    echo "an old helper is not named as the reason" >&2
    cat "$BROWSER_ERR" >&2
    exit 1
fi
echo "deploy preflight names a helper that predates the browser Add-on check"
