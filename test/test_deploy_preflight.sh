#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FIXTURE_DIR="$(mktemp -d)"

cleanup() {
    rm -rf "$FIXTURE_DIR"
}
trap cleanup EXIT

mkdir -p \
    "$FIXTURE_DIR/repo/scripts" \
    "$FIXTURE_DIR/repo/config" \
    "$FIXTURE_DIR/repo/_build/default/bin" \
    "$FIXTURE_DIR/runtime/.masc/logs"
touch \
    "$FIXTURE_DIR/repo/_build/default/bin/main_eio.exe" \
    "$FIXTURE_DIR/repo/_build/default/bin/deployment_preflight_helper.exe"
chmod +x \
    "$FIXTURE_DIR/repo/_build/default/bin/main_eio.exe" \
    "$FIXTURE_DIR/repo/_build/default/bin/deployment_preflight_helper.exe"

# The new build refuses the live runtime.toml before anything is replaced,
# so the serving process keeps running and its editor can still change the
# value (#39311). The helper here stands in for one that refuses the file.
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

# scripts/install-local-build.sh runs this check before it replaces any
# binary.
cp "$ROOT_DIR/scripts/install-local-build.sh" \
    "$FIXTURE_DIR/repo/scripts/install-local-build.sh"
# Provide every required executable so this case reaches the runtime.toml check.
INSTALL_BINARIES=(
    "$FIXTURE_DIR/repo/_build/default/bin/masc_tui.exe"
    "$FIXTURE_DIR/repo/_build/default/bin/masc_native_addon_launcher.exe"
    "$FIXTURE_DIR/repo/_build/default/bin/masc_browser_addon_worker.exe"
    "$FIXTURE_DIR/repo/_build/default/bin/masc_exec_ssh_bootstrap.exe"
    "$FIXTURE_DIR/repo/_build/default/bin/masc_antigravity_path_hook.exe"
)
touch "${INSTALL_BINARIES[@]}"
chmod +x "${INSTALL_BINARIES[@]}"

INSTALL_ERR="$FIXTURE_DIR/install-local-build.err"
if bash "$FIXTURE_DIR/repo/scripts/install-local-build.sh" \
    --skip-build \
    --prefix "$FIXTURE_DIR/prefix" \
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
