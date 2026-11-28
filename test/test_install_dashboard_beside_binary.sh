#!/usr/bin/env bash
# The dashboard step of scripts/install-local-build.sh (#49980, #55405), one
# case per way it ends. Every case must return 0: the binaries are installed
# before it.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FIXTURE_DIR="$(mktemp -d)"

cleanup() {
    chmod -R u+rwx "$FIXTURE_DIR" 2>/dev/null || true
    rm -rf "$FIXTURE_DIR"
}
trap cleanup EXIT

# shellcheck source=../scripts/lib/install-dashboard-beside-binary.sh
. "$ROOT_DIR/scripts/lib/install-dashboard-beside-binary.sh"

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

# run_step CHECKOUT_BUNDLE PREFIX: output on $OUT (stdout) and $ERR (stderr).
OUT="$FIXTURE_DIR/out"
ERR="$FIXTURE_DIR/err"
run_step() {
    install_dashboard_beside_binary "$1" "$2" >"$OUT" 2>"$ERR" || fail "the step returned a nonzero status"
}

# 1. An older bundle beside the binaries is replaced and kept as a backup.
checkout="$FIXTURE_DIR/c1/assets/dashboard"
prefix="$FIXTURE_DIR/p1"
make_bundle "$checkout" new 202611071722
make_bundle "$prefix/assets/dashboard" old 202610271229
run_step "$checkout" "$prefix"
grep -q '^new$' "$prefix/assets/dashboard/index.html" || fail "case 1: the new index.html is not in place"
[ -f "$prefix/assets/dashboard/assets/app.js" ] || fail "case 1: a nested file was not copied"
[ -f "$prefix/assets/dashboard/.build-stamp" ] || fail "case 1: .build-stamp was not copied"
[ ! "$prefix/assets/dashboard/.build-stamp" -nt "$checkout/.build-stamp" ] \
    && [ ! "$prefix/assets/dashboard/.build-stamp" -ot "$checkout/.build-stamp" ] \
    || fail "case 1: .build-stamp lost its mtime, so the next install would see a newer copy"
[ "$(backups "$prefix")" = 1 ] || fail "case 1: expected one backup, found $(backups "$prefix")"
backup=$(find "$prefix/assets" -maxdepth 1 -type d -name 'dashboard-backup-*')
grep -q '^old$' "$backup/index.html" || fail "case 1: the backup does not hold the old bundle"
grep -q 'previous one is kept' "$OUT" || fail "case 1: no installed line naming the backup"
[ -z "$(find "$prefix/assets" -maxdepth 1 -name '.dashboard.partial.*')" ] || fail "case 1: a staging directory was left"

# 2. The same install again changes nothing.
run_step "$checkout" "$prefix"
[ "$(backups "$prefix")" = 1 ] || fail "case 2: a second install made another backup"
grep -q 'already as new' "$OUT" || fail "case 2: no already-as-new line"

# 3. A bundle beside the binaries newer than the checkout's is left alone.
checkout="$FIXTURE_DIR/c3/assets/dashboard"
prefix="$FIXTURE_DIR/p3"
make_bundle "$checkout" older 202611010000
make_bundle "$prefix/assets/dashboard" newer 202611080000
run_step "$checkout" "$prefix"
grep -q '^newer$' "$prefix/assets/dashboard/index.html" || fail "case 3: a newer bundle was replaced"
[ "$(backups "$prefix")" = 0 ] || fail "case 3: a backup was made"
grep -q 'already as new' "$OUT" || fail "case 3: no already-as-new line"

# 4. A prefix with no bundle is given one, and there is nothing to back up.
checkout="$FIXTURE_DIR/c4/assets/dashboard"
prefix="$FIXTURE_DIR/p4"
make_bundle "$checkout" new 202611071722
mkdir -p "$prefix"
run_step "$checkout" "$prefix"
grep -q '^new$' "$prefix/assets/dashboard/index.html" || fail "case 4: no bundle was installed into a prefix that had none"
[ -f "$prefix/assets/dashboard/assets/app.js" ] || fail "case 4: a nested file was not copied"
[ "$(backups "$prefix")" = 0 ] || fail "case 4: a backup was made of nothing"
grep -q 'installed the dashboard bundle' "$OUT" || fail "case 4: no installed line"
! grep -q 'previous one is kept' "$OUT" || fail "case 4: the installed line names a backup that is not there"
[ -z "$(find "$prefix/assets" -maxdepth 1 -name '.dashboard.partial.*')" ] || fail "case 4: a staging directory was left"

# 5. A checkout with no built bundle leaves the prefix as it is and says so.
checkout="$FIXTURE_DIR/c5/assets/dashboard"
prefix="$FIXTURE_DIR/p5"
mkdir -p "$checkout"
make_bundle "$prefix/assets/dashboard" old 202610271229
run_step "$checkout" "$prefix"
grep -q '^old$' "$prefix/assets/dashboard/index.html" || fail "case 5: the bundle beside the binaries changed"
grep -q 'WARN' "$ERR" || fail "case 5: no warning"

# 6. A symlink to the bundle is not replaced, and what it points at stays.
checkout="$FIXTURE_DIR/c6/assets/dashboard"
target="$FIXTURE_DIR/other-checkout"
prefix="$FIXTURE_DIR/p6"
make_bundle "$checkout" new 202611071722
make_bundle "$target/assets/dashboard" other 202610271229
mkdir -p "$prefix"
ln -s "$target/assets" "$prefix/assets"
run_step "$checkout" "$prefix"
grep -q '^other$' "$target/assets/dashboard/index.html" || fail "case 6: the bundle behind the symlink changed"
[ "$(backups "$target")" = 0 ] || fail "case 6: a backup was made behind the symlink"
grep -q 'symlink' "$OUT" || fail "case 6: no symlink line"

if [ "$(id -u)" != 0 ]; then
    # 7. An assets directory that cannot be written is left as it is.
    checkout="$FIXTURE_DIR/c7/assets/dashboard"
    prefix="$FIXTURE_DIR/p7"
    make_bundle "$checkout" new 202611071722
    make_bundle "$prefix/assets/dashboard" old 202610271229
    chmod 555 "$prefix/assets"
    run_step "$checkout" "$prefix"
    chmod 755 "$prefix/assets"
    grep -q '^old$' "$prefix/assets/dashboard/index.html" || fail "case 7: the bundle beside the binaries changed"
    grep -q 'WARN' "$ERR" || fail "case 7: no warning"

    # 8. A prefix where no assets directory can be made gets none and says so.
    checkout="$FIXTURE_DIR/c8/assets/dashboard"
    prefix="$FIXTURE_DIR/p8"
    make_bundle "$checkout" new 202611071722
    mkdir -p "$prefix"
    chmod 555 "$prefix"
    run_step "$checkout" "$prefix"
    chmod 755 "$prefix"
    [ ! -e "$prefix/assets" ] || fail "case 8: an assets directory appeared in a prefix that cannot be written"
    grep -q 'could not be made' "$ERR" || fail "case 8: no warning naming the directory"
fi

# A failed copy leaves no fresh assets directory to hide a workspace bundle.
checkout="$FIXTURE_DIR/copy-failure/assets/dashboard"
prefix="$FIXTURE_DIR/copy-failure-prefix"
make_bundle "$checkout" new 202611071722
mkdir -p "$prefix"
(cp() { return 1; }; run_step "$checkout" "$prefix")
[ ! -e "$prefix/assets" ] || fail "copy failure hid the original workspace assets"
grep -q 'could not be copied' "$ERR" || fail "copy failure produced no warning"

# The call site: the real installer, run from a fixture checkout whose helper
# approves everything, reaches the step after the binaries are installed.
# run_installer DIR: DIR/repo is the checkout, DIR/runtime the workspace.
run_installer() {
    local dir=$1 exe
    mkdir -p "$dir/repo/scripts/lib" "$dir/repo/config" "$dir/repo/_build/default/bin" "$dir/runtime/.masc/logs"
    cp "$ROOT_DIR/scripts/check-runtime-deployment-preflight.sh" "$ROOT_DIR/scripts/install-local-build.sh" "$dir/repo/scripts/"
    cp "$ROOT_DIR/scripts/lib/install-dashboard-beside-binary.sh" "$dir/repo/scripts/lib/"
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
    ( cd "$dir/repo" && bash scripts/install-local-build.sh --skip-build \
        --prefix "$dir/prefix" --base-path "$dir/runtime" >"$OUT" 2>"$ERR" ) \
        || { cat "$ERR" >&2; fail "the installer failed"; }
}

# 9. The installer puts the bundle beside the binaries it installs, and leaves
# the bundle a workspace holds as it is: a server from the prefix reads the one
# beside its binary first.
dir="$FIXTURE_DIR/e9"
make_bundle "$dir/repo/assets/dashboard" new 202611071722
make_bundle "$dir/runtime/assets/dashboard" old 202610271229
run_installer "$dir"
[ -x "$dir/prefix/masc" ] || fail "case 9: masc was not installed"
grep -q '^new$' "$dir/prefix/assets/dashboard/index.html" || fail "case 9: the bundle is not beside the binaries"
grep -q '^old$' "$dir/runtime/assets/dashboard/index.html" || fail "case 9: the installer changed the bundle of the workspace"
grep -q 'installed the dashboard bundle' "$OUT" || fail "case 9: no installed line"

# 10. A checkout with no built bundle does not stop the install. With no
# bundle beside the binaries either, nothing is left behind, so it says so on
# stdout and warns of nothing.
dir="$FIXTURE_DIR/e10"
mkdir -p "$dir/repo/assets/dashboard"
run_installer "$dir"
[ -x "$dir/prefix/masc" ] || fail "case 10: masc was not installed"
[ ! -e "$dir/prefix/assets/dashboard" ] || fail "case 10: a bundle appeared with none built"
grep -q 'none installed' "$OUT" || fail "case 10: no none-installed line"
! grep -q 'dashboard' "$ERR" || fail "case 10: a dashboard warning with nothing left behind"

echo "install-local-build puts the dashboard bundle beside the binaries, and replaces it only with a newer one"
