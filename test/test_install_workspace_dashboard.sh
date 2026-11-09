#!/usr/bin/env bash
# The dashboard step of scripts/install-local-build.sh (#49980), one case per
# way it ends. Every case must return 0: the binaries are installed before it.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FIXTURE_DIR="$(mktemp -d)"

cleanup() {
    chmod -R u+rwx "$FIXTURE_DIR" 2>/dev/null || true
    rm -rf "$FIXTURE_DIR"
}
trap cleanup EXIT

# shellcheck source=../scripts/lib/install-workspace-dashboard.sh
. "$ROOT_DIR/scripts/lib/install-workspace-dashboard.sh"

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

# make_bundle DIR MARKER STAMP: an index.html naming MARKER, one nested file,
# and a .build-stamp whose mtime is STAMP (touch -t form).
make_bundle() {
    mkdir -p "$1/assets"
    echo "$2" > "$1/index.html"
    echo "console.log('$2')" > "$1/assets/app.js"
    : > "$1/.build-stamp"
    touch -t "$3" "$1/.build-stamp"
}

backups() {
    find "$1/assets" -maxdepth 1 -type d -name 'dashboard-backup-*' | wc -l | tr -d ' '
}

# run_step CHECKOUT_BUNDLE WORKSPACE: output on $OUT (stdout) and $ERR (stderr).
OUT="$FIXTURE_DIR/out"
ERR="$FIXTURE_DIR/err"
run_step() {
    install_workspace_dashboard "$1" "$2" >"$OUT" 2>"$ERR" || fail "the step returned a nonzero status"
}

# 1. An older workspace bundle is replaced and kept as a backup.
checkout="$FIXTURE_DIR/c1/assets/dashboard"
ws="$FIXTURE_DIR/w1"
make_bundle "$checkout" new 202611071722
make_bundle "$ws/assets/dashboard" old 202610271229
run_step "$checkout" "$ws"
grep -q '^new$' "$ws/assets/dashboard/index.html" || fail "case 1: the new index.html is not in place"
[ -f "$ws/assets/dashboard/assets/app.js" ] || fail "case 1: a nested file was not copied"
[ -f "$ws/assets/dashboard/.build-stamp" ] || fail "case 1: .build-stamp was not copied"
[ ! "$ws/assets/dashboard/.build-stamp" -nt "$checkout/.build-stamp" ] \
    && [ ! "$ws/assets/dashboard/.build-stamp" -ot "$checkout/.build-stamp" ] \
    || fail "case 1: .build-stamp lost its mtime, so the next install would see a newer copy"
[ "$(backups "$ws")" = 1 ] || fail "case 1: expected one backup, found $(backups "$ws")"
backup=$(find "$ws/assets" -maxdepth 1 -type d -name 'dashboard-backup-*')
grep -q '^old$' "$backup/index.html" || fail "case 1: the backup does not hold the old bundle"
grep -q 'installed the dashboard bundle' "$OUT" || fail "case 1: no installed line"
[ -z "$(find "$ws/assets" -maxdepth 1 -name '.dashboard.partial.*')" ] || fail "case 1: a staging directory was left"

# 2. The same install again changes nothing.
run_step "$checkout" "$ws"
[ "$(backups "$ws")" = 1 ] || fail "case 2: a second install made another backup"
grep -q 'already as new' "$OUT" || fail "case 2: no already-as-new line"

# 3. A workspace bundle newer than the checkout's is left alone.
checkout="$FIXTURE_DIR/c3/assets/dashboard"
ws="$FIXTURE_DIR/w3"
make_bundle "$checkout" older 202611010000
make_bundle "$ws/assets/dashboard" newer 202611080000
run_step "$checkout" "$ws"
grep -q '^newer$' "$ws/assets/dashboard/index.html" || fail "case 3: a newer workspace bundle was replaced"
[ "$(backups "$ws")" = 0 ] || fail "case 3: a backup was made"
grep -q 'already as new' "$OUT" || fail "case 3: no already-as-new line"

# 4. A workspace with no bundle is given none.
checkout="$FIXTURE_DIR/c4/assets/dashboard"
ws="$FIXTURE_DIR/w4"
make_bundle "$checkout" new 202611071722
mkdir -p "$ws"
run_step "$checkout" "$ws"
[ ! -e "$ws/assets" ] || fail "case 4: a bundle was installed into a workspace that had none"
grep -q 'none installed' "$OUT" || fail "case 4: no none-installed line"

# 5. A checkout with no built bundle leaves the workspace as it is and says so.
checkout="$FIXTURE_DIR/c5/assets/dashboard"
ws="$FIXTURE_DIR/w5"
mkdir -p "$checkout"
make_bundle "$ws/assets/dashboard" old 202610271229
run_step "$checkout" "$ws"
grep -q '^old$' "$ws/assets/dashboard/index.html" || fail "case 5: the workspace bundle changed"
grep -q 'WARN' "$ERR" || fail "case 5: no warning"

# 6. A symlink to the bundle is not replaced, and what it points at stays.
checkout="$FIXTURE_DIR/c6/assets/dashboard"
target="$FIXTURE_DIR/other-checkout"
ws="$FIXTURE_DIR/w6"
make_bundle "$checkout" new 202611071722
make_bundle "$target/assets/dashboard" other 202610271229
mkdir -p "$ws"
ln -s "$target/assets" "$ws/assets"
run_step "$checkout" "$ws"
grep -q '^other$' "$target/assets/dashboard/index.html" || fail "case 6: the bundle behind the symlink changed"
[ "$(backups "$target")" = 0 ] || fail "case 6: a backup was made behind the symlink"
grep -q 'symlink' "$OUT" || fail "case 6: no symlink line"

# 7. A workspace whose assets directory cannot be written is left as it is.
if [ "$(id -u)" != 0 ]; then
    checkout="$FIXTURE_DIR/c7/assets/dashboard"
    ws="$FIXTURE_DIR/w7"
    make_bundle "$checkout" new 202611071722
    make_bundle "$ws/assets/dashboard" old 202610271229
    chmod 555 "$ws/assets"
    run_step "$checkout" "$ws"
    chmod 755 "$ws/assets"
    grep -q '^old$' "$ws/assets/dashboard/index.html" || fail "case 7: the workspace bundle changed"
    grep -q 'WARN' "$ERR" || fail "case 7: no warning"
fi

# The call site: the real installer, run from a fixture checkout whose helper
# approves everything, reaches the step after the binaries are installed.
# run_installer DIR: DIR/repo is the checkout, DIR/runtime the workspace.
run_installer() {
    local dir=$1 exe
    mkdir -p "$dir/repo/scripts/lib" "$dir/repo/config" "$dir/repo/_build/default/bin" "$dir/runtime/.masc/logs"
    cp "$ROOT_DIR/scripts/check-runtime-deployment-preflight.sh" "$ROOT_DIR/scripts/install-local-build.sh" "$dir/repo/scripts/"
    cp "$ROOT_DIR/scripts/lib/install-workspace-dashboard.sh" "$dir/repo/scripts/lib/"
    for exe in main_eio masc_tui masc_native_addon_launcher masc_browser_addon_worker masc_exec_ssh_bootstrap masc_antigravity_path_hook; do
        printf '#!/usr/bin/env bash\nexit 0\n' > "$dir/repo/_build/default/bin/$exe.exe"
        chmod +x "$dir/repo/_build/default/bin/$exe.exe"
    done
    cat > "$dir/repo/_build/default/bin/deployment_preflight_helper.exe" <<'HELPER'
#!/usr/bin/env bash
case "$1" in
    build-commit) echo fixture-commit ;;
    durable-filenames) printf 'snapshot=fixture-snapshot.json\nwal=fixture-wal.jsonl\n' ;;
    resolve-workspace) printf 'workspace=resolved\nroot=%s\nsource=explicit_cli\n' "$3" ;;
    validate-runtime-config | validate-stores) exit 0 ;;
    *) echo "unexpected helper call: $*" >&2; exit 2 ;;
esac
HELPER
    chmod +x "$dir/repo/_build/default/bin/deployment_preflight_helper.exe"
    ( cd "$dir/repo" && bash scripts/install-local-build.sh --skip-build --no-guest-shim \
        --prefix "$dir/prefix" --base-path "$dir/runtime" >"$OUT" 2>"$ERR" ) \
        || { cat "$ERR" >&2; fail "the installer failed"; }
}

# 8. The installer replaces the workspace bundle and installs the binaries.
dir="$FIXTURE_DIR/e8"
make_bundle "$dir/repo/assets/dashboard" new 202611071722
make_bundle "$dir/runtime/assets/dashboard" old 202610271229
run_installer "$dir"
[ -x "$dir/prefix/masc" ] || fail "case 8: masc was not installed"
grep -q '^new$' "$dir/runtime/assets/dashboard/index.html" || fail "case 8: the installer left the old bundle"
grep -q 'installed the dashboard bundle' "$OUT" || fail "case 8: no installed line"

# 9. A checkout with no built bundle does not stop the install.
dir="$FIXTURE_DIR/e9"
mkdir -p "$dir/repo/assets/dashboard"
make_bundle "$dir/runtime/assets/dashboard" old 202610271229
run_installer "$dir"
[ -x "$dir/prefix/masc" ] || fail "case 9: masc was not installed"
grep -q '^old$' "$dir/runtime/assets/dashboard/index.html" || fail "case 9: the workspace bundle changed"
grep -q 'WARN' "$ERR" || fail "case 9: no warning"

echo "install-local-build refreshes the workspace dashboard bundle only when the checkout's is newer"
