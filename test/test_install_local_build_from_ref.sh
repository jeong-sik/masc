#!/usr/bin/env bash
# scripts/install-local-build.sh --from REF builds and installs REF from the
# deploy worktree <main checkout>/.worktrees/deploy. Each commit of the fixture
# repository carries a stand-in install script that prints where it runs, the
# commit checked out there, whether it inherited the install lock and the
# arguments it was given; the script under test sits uncommitted in the
# checkout it is run from.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FIXTURE_DIR="$(cd "$(mktemp -d)" && pwd -P)"
cleanup() { rm -rf "$FIXTURE_DIR"; }
trap cleanup EXIT
export TMPDIR="$FIXTURE_DIR/tmp"
mkdir -p "$TMPDIR"

fail() { echo "FAIL: $*" >&2; exit 1; }

REPO="$FIXTURE_DIR/repo"
DEPLOY="$REPO/.worktrees/deploy"
# A branch other than main and no hooks: the fixture's commits are not the
# operator's, so their hooks do not judge them.
git init -q -b fixture "$REPO"
mkdir -p "$FIXTURE_DIR/no-hooks" "$REPO/.git/info"
git -C "$REPO" config core.hooksPath "$FIXTURE_DIR/no-hooks"
git -C "$REPO" config user.email fixture@example.invalid
git -C "$REPO" config user.name fixture
printf '.worktrees/\n' >"$REPO/.gitignore"
mkdir -p "$REPO/scripts"

commit_stub() {
    cat >"$REPO/scripts/install-local-build.sh" <<'STUB'
#!/usr/bin/env bash
here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
echo "stub repo=$here head=$(git -C "$here" rev-parse HEAD) held=${MASC_DUNE_LOCK_HELD:-0} args=$*"
STUB
    echo "$1" >"$REPO/marker"
    git -C "$REPO" add .gitignore marker scripts/install-local-build.sh
    git -C "$REPO" commit -q -m "$1"
    git -C "$REPO" rev-parse HEAD
}

A=$(commit_stub first)
B=$(commit_stub second)
cp "$ROOT_DIR/scripts/install-local-build.sh" "$REPO/scripts/install-local-build.sh"

run() { bash "$REPO/scripts/install-local-build.sh" "$@" 2>&1; }

# A first --from creates the deploy worktree, detached at the commit, and the
# commit's own script runs the install under the inherited lock without --from.
out=$(run --from "$A" --prefix "$FIXTURE_DIR/prefix") || fail "--from $A exited non-zero: $out"
grep -qF "stub repo=$DEPLOY head=$A held=1 args=--prefix $FIXTURE_DIR/prefix" <<<"$out" ||
    fail "the deploy worktree's script did not run commit $A: $out"
[ "$(git -C "$DEPLOY" rev-parse --abbrev-ref HEAD)" = HEAD ] || fail "the deploy worktree is on a branch"
# The lock taken is the deploy worktree's, the one its own install and
# dune-local.sh take, not the lock of the checkout --from was run from.
deploy_lock="$TMPDIR/masc-dune-${UID:-$(id -u)}-$(printf '%s' "$DEPLOY" | cksum | awk '{print $1}').lock"
[ -e "$deploy_lock" ] || fail "--from did not take the deploy worktree's lock $deploy_lock"

# A later --from moves the same worktree; the build output it holds stays.
mkdir -p "$DEPLOY/_build" && touch "$DEPLOY/_build/kept"
printf '_build/\n' >>"$REPO/.git/info/exclude"
out=$(run --from "$B") || fail "--from $B exited non-zero: $out"
grep -qF "stub repo=$DEPLOY head=$B held=1 args=" <<<"$out" || fail "the deploy worktree did not move to $B: $out"
[ -f "$DEPLOY/_build/kept" ] || fail "moving the deploy worktree removed its build output"

# A deploy worktree with changes is refused and left where it was.
echo edit >>"$DEPLOY/marker"
if out=$(run --from "$A"); then fail "a changed deploy worktree was moved: $out"; fi
grep -qF "has changes" <<<"$out" || fail "a changed deploy worktree was refused for another reason: $out"
[ "$(git -C "$DEPLOY" rev-parse HEAD)" = "$B" ] || fail "a refused install moved the deploy worktree"
git -C "$DEPLOY" checkout -q -- marker

# --from builds the commit it names, so it does not take another build.
for other in --skip-build "--build-dir $FIXTURE_DIR/elsewhere"; do
    # shellcheck disable=SC2086
    if out=$(run --from "$A" $other); then fail "--from with $other installed: $out"; fi
    grep -qF "install another build" <<<"$out" || fail "--from with $other was refused for another reason: $out"
done

# A ref that names no commit installs nothing.
if out=$(run --from no-such-ref); then fail "an unknown ref installed: $out"; fi
grep -qF "names no commit" <<<"$out" || fail "an unknown ref was refused for another reason: $out"

# Run from another worktree, --from still uses the main checkout's deploy
# worktree rather than making one inside the worktree it was run from.
git -C "$REPO" worktree add -q --detach "$REPO/.worktrees/other" "$A"
cp "$ROOT_DIR/scripts/install-local-build.sh" "$REPO/.worktrees/other/scripts/install-local-build.sh"
out=$(bash "$REPO/.worktrees/other/scripts/install-local-build.sh" --from "$A" 2>&1) ||
    fail "--from from another worktree exited non-zero: $out"
grep -qF "stub repo=$DEPLOY head=$A held=1" <<<"$out" || fail "--from from another worktree did not use $DEPLOY: $out"
[ ! -e "$REPO/.worktrees/other/.worktrees/deploy" ] || fail "a deploy worktree was made inside another worktree"

# A directory at the deploy path that is not a worktree of this repository is
# not overwritten.
git -C "$REPO" worktree remove --force "$DEPLOY"
mkdir -p "$DEPLOY"
if out=$(run --from "$A"); then fail "a plain directory at the deploy path was used: $out"; fi
grep -qF "is not a worktree" <<<"$out" || fail "a plain directory was refused for another reason: $out"

echo "install-local-build --from: all cases passed"
