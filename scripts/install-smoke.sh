#!/usr/bin/env bash
# install-smoke.sh — offline end-to-end check of scripts/install.sh.
#
# Stages the release binaries as a local file:// release, installs them
# through the real installer (detect_asset + SHA256SUMS verification +
# placement), then boots the installed server and asserts /health. This
# guards the installer's asset-name and checksum contract that a release
# depends on -- the contract that broke silently when nothing exercised the
# download path end to end -- without any network access.
#
# Config seeding runs for real. It used to fetch from raw.githubusercontent, so
# this smoke passed --no-seed and copied the repo's own config/runtime.toml into
# place afterwards -- which meant the seeding path was the one part of the
# installer nothing exercised, and a release binary that could not seed itself
# reached a fresh host and died on "no runtime config path". The seed now comes
# out of the binary, so the smoke drives it and asserts what landed.
#
# Usage: install-smoke.sh <binaries_dir> <arch> [keeper_image]
#   binaries_dir holds the release-named files:
#     masc-<arch>, masc-tui-<arch>,
#     masc-deployment-preflight-helper-<arch>,
#     masc-check-runtime-deployment-preflight-<arch>
#   arch is the release arch label (e.g. linux-x64, linux-arm64, macos-arm64)
#   and must match the host so install.sh's detect_asset resolves to it.
set -euo pipefail

BIN_DIR="${1:?usage: install-smoke.sh <binaries_dir> <arch>}"
ARCH="${2:?usage: install-smoke.sh <binaries_dir> <arch>}"
KEEPER_IMAGE="${3:-}"
BIN_DIR="$(cd "$BIN_DIR" && pwd)"

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
INSTALL_SH="$REPO_ROOT/scripts/install.sh"
[ -x "$INSTALL_SH" ] || { echo "install-smoke: $INSTALL_SH not executable" >&2; exit 2; }
# No precondition on the repo's config/ tree: the config the installer seeds now
# comes out of the binary under test, which is the thing this smoke is for.

ASSETS=(
  "masc-$ARCH"
  "masc-tui-$ARCH"
  "masc-browser-host-$ARCH"
  "masc-deployment-preflight-helper-$ARCH"
  "masc-check-runtime-deployment-preflight-$ARCH"
  "masc-dashboard-$ARCH.tar.gz"
  "masc-release-dashboard-bundle-$ARCH.py"
  "masc-runtime-$ARCH.tar.gz"
)
for a in "${ASSETS[@]}"; do
  [ -f "$BIN_DIR/$a" ] || { echo "install-smoke: missing release asset $BIN_DIR/$a" >&2; exit 2; }
done

# The guest exec shim (RFC-0427 B-2) is built by the Linux release jobs on
# their own architecture, so it is in dist/ there and absent on the macOS job.
# When it is here the smoke stages it and checks the installer placed it with
# its sha256 sidecar; when it is not, the smoke asks the installer to skip it,
# which is the flag a host without microvm keepers uses.
case "$ARCH" in
  macos-arm64|linux-arm64) SHIM_ASSET="masc-exec-shim-linux-arm64" ;;
  macos-x64|linux-x64) SHIM_ASSET="masc-exec-shim-linux-amd64" ;;
  *) SHIM_ASSET="" ;;
esac
SHIM_FLAG="--no-guest-shim"
if [ -n "$SHIM_ASSET" ] && [ -f "$BIN_DIR/$SHIM_ASSET" ]; then
  ASSETS+=("$SHIM_ASSET")
  SHIM_FLAG=""
fi

# SMOKE_VERSION is a label, not a real tag: it only names the file:// release
# directory and the SHA256SUMS the installer verifies against.
VERSION="v0.0.0-install-smoke"
work="$(mktemp -d)"
PID=""
cleanup() {
  [ -n "$PID" ] && kill "$PID" 2>/dev/null || true
  # Let the killed server finish exiting before removing its tree, so a
  # background tool-asset write does not race the rm.
  [ -n "$PID" ] && wait "$PID" 2>/dev/null || true
  # WORKAROUND (#33157): best-effort. Even after the wait a late write can
  # leave $work/.masc/config/tools non-empty as rm walks it. A teardown race
  # must not fail a smoke that already answered /health. Root fix: the server
  # joins its writer fibers on shutdown, so nothing writes once the process
  # has exited; when that lands, drop the "2>/dev/null || true" and let an rm
  # failure fail.
  rm -rf "$work" 2>/dev/null || true
}
trap cleanup EXIT

stage="$work/release/$VERSION"
prefix="$work/bin"
base="$work/base"
mkdir -p "$stage" "$prefix" "$base"

# Stage the file:// release: the release assets plus a SHA256SUMS with exactly
# the format install.sh's verify_checksum parses ("<hash>  <name>").
for a in "${ASSETS[@]}"; do
  cp "$BIN_DIR/$a" "$stage/$a"
done
# The installer uses this helper for workspace preflight even with --no-wizard.
# Release assembly adds it from the checkout, rather than from platform dist/.
cp "$REPO_ROOT/scripts/install-runtime-setup.py" "$stage/install-runtime-setup.py"
ASSETS+=("install-runtime-setup.py")
sha_tool() { if command -v sha256sum >/dev/null 2>&1; then sha256sum "$@"; else shasum -a 256 "$@"; fi; }
( cd "$stage" && sha_tool "${ASSETS[@]}" > SHA256SUMS )

echo "install-smoke: installing $VERSION ($ARCH) from file://$stage"
# shellcheck disable=SC2086  # SHIM_FLAG is one optional word, or empty
MASC_RELEASE_BASE_URL="file://$work/release" \
  bash "$INSTALL_SH" \
    --version "$VERSION" \
    --prefix "$prefix" \
    --base-path "$base" \
    --no-wizard $SHIM_FLAG

case "$ARCH" in
  macos-*) PATH="$(dirname "$(readlink "$prefix/masc")")/python/bin:$PATH"; export PATH ;;
esac

for a in masc masc-tui masc-browser-host masc-deployment-preflight-helper masc-check-runtime-deployment-preflight; do
  [ -x "$prefix/$a" ] || { echo "install-smoke: installer did not place $a" >&2; exit 1; }
done
echo "install-smoke: installer placed all five executables"
"$prefix/masc-tui" --help > "$work/tui-help.txt"
"$prefix/masc-browser-host" --help > "$work/browser-host-help.txt"


shim_dest="$base/.masc/microvm/shim/masc-exec-shim"
if [ -z "$SHIM_FLAG" ]; then
  [ -x "$shim_dest" ] || { echo "install-smoke: installer did not place the guest shim at $shim_dest" >&2; exit 1; }
  [ -f "$shim_dest.sha256" ] || { echo "install-smoke: installer left no sha256 sidecar beside the guest shim" >&2; exit 1; }
  want="$(awk -v f="$SHIM_ASSET" '$2 == f {print $1; exit}' "$stage/SHA256SUMS")"
  got="$(awk '{print $1; exit}' "$shim_dest.sha256")"
  [ "$want" = "$got" ] || { echo "install-smoke: sidecar digest $got differs from the release's $want" >&2; exit 1; }
  echo "install-smoke: installer placed the guest shim with the release's sha256 beside it"
else
  [ ! -e "$shim_dest" ] || { echo "install-smoke: --no-guest-shim still placed $shim_dest" >&2; exit 1; }
  echo "install-smoke: no guest shim in this release dir; installer skipped it as asked"
fi

# What the installer's own seed had to produce. runtime.toml AND the
# model-catalog overlay both matter: without the overlay the exact-output lanes
# (e.g. hitl_auto_judge) reference glm slots the ambient catalog does not admit,
# and the server exits FATAL before /health.
for f in runtime.toml agent-core-models-overlay.toml; do
  [ -f "$base/.masc/config/$f" ] || {
    echo "install-smoke: installer seeded no $f" >&2; exit 1; }
done
# A fresh workspace ships one Keeper, but must not start it before the
# operator configures a model and sandbox. Parse the installed manifest so
# an absent, misplaced, or non-boolean opt-out cannot pass this check.
python3 - "$base/.masc/config/keepers" <<'PY_ROSTER'
from pathlib import Path
import sys
import tomllib

roster = Path(sys.argv[1])
if sorted(path.name for path in roster.iterdir()) != ["imp.toml"]:
    raise SystemExit("install-smoke: expected exactly the first Keeper manifest imp.toml")
with (roster / "imp.toml").open("rb") as source:
    manifest = tomllib.load(source)
if manifest.get("keeper", {}).get("activation_mode") != "manual":
    raise SystemExit("install-smoke: first Keeper must wait for manual start (activation_mode must be manual)")
PY_ROSTER
for f in SKILL.md references/connection.md references/advanced.md references/verification.md; do
  [ -f "$base/.masc/skills/browser-lanes/$f" ] || {
    echo "install-smoke: missing builtin browser Skill file $f" >&2; exit 1; }
done
echo "install-smoke: installer seeded config and builtin Skills, and one Keeper waiting for manual start"

# Built-in skill packages come from the verified binary, not a source checkout.
for file in SKILL.md references/advanced.md references/connection.md references/verification.md; do
  [ -f "$base/.masc/skills/browser-lanes/$file" ] || {
    echo "install-smoke: browser-lanes package missing $file" >&2; exit 1;
  }
done
echo "install-smoke: installer seeded the complete browser-lanes Skill package"

[ -f "$base/.masc/skills/evidence-review/SKILL.md" ] || {
  echo "install-smoke: evidence-review Skill missing" >&2; exit 1;
}

# Reinstall the actual compiled artifact through the upgrade branch. This
# proves init --skills-only against real embedded assets, not a fixture CLI.
# Same-version --force is deliberate: this checks preservation, not migration
# from an older release's configuration schema.
runtime_config="$base/.masc/config/runtime.toml"
operator_file="$base/.masc/config/operator-install-smoke.txt"
optional_config="$base/.masc/config/themes/tomorrow-night.toml"
[ -f "$optional_config" ] || { echo "install-smoke: optional theme was not seeded" >&2; exit 1; }
printf '\n# install-smoke operator setting must survive reinstall\n' >> "$runtime_config"
printf 'operator-owned install-smoke bytes\n' > "$operator_file"
cp "$runtime_config" "$work/runtime-before-upgrade.toml"
cp "$operator_file" "$work/operator-before-upgrade.txt"
cp -R "$base/.masc/skills/browser-lanes" "$work/browser-skill-bundled"
printf '\nOperator install-smoke instruction.\n' >> "$base/.masc/skills/browser-lanes/SKILL.md"
rm "$base/.masc/skills/browser-lanes/references/advanced.md"
cp -R "$base/.masc/skills/browser-lanes" "$work/browser-skill-before-upgrade"
rm "$optional_config"
commit_before="$("$prefix/masc" build-commit)"
# shellcheck disable=SC2086  # SHIM_FLAG is one optional word, or empty
MASC_RELEASE_BASE_URL="file://$work/release" \
  bash "$INSTALL_SH" --version "$VERSION" --prefix "$prefix" \
    --base-path "$base" --force --no-wizard $SHIM_FLAG
[ "$("$prefix/masc" build-commit)" = "$commit_before" ] || {
  echo "install-smoke: reinstall changed the packaged build commit" >&2; exit 1;
}
python3 - "$base" "$work" <<'PYUPGRADE'
import pathlib
import sys
base, work = map(pathlib.Path, sys.argv[1:])
config = base / '.masc/config'
assert (config / 'runtime.toml').read_bytes() == (work / 'runtime-before-upgrade.toml').read_bytes(), 'operator runtime bytes changed'
assert (config / 'operator-install-smoke.txt').read_bytes() == (work / 'operator-before-upgrade.txt').read_bytes(), 'operator file changed'
assert not (config / 'themes/tomorrow-night.toml').exists(), 'upgrade restored deliberately removed optional config'
def files(root):
    return {str(p.relative_to(root)): p.read_bytes() for p in root.rglob('*') if p.is_file()}
assert files(base / '.masc/skills/browser-lanes') == files(work / 'browser-skill-before-upgrade'), 'installed builtin Skill package changed'
PYUPGRADE
echo "install-smoke: actual-artifact force reinstall preserved config, removed optional theme, and builtin Skills"

# Explicit reviewed package replacement uses the actual native CLI. The whole
# package can be diffed even when the installed binary has no source checkout.
python3 - "$prefix/masc" "$base" "$work" <<'PYSKILL'
from pathlib import Path
import subprocess
import sys
binary, base_arg, work_arg = sys.argv[1:]
base, work = Path(base_arg), Path(work_arg)
args = [binary, 'skills-refresh', 'browser-lanes', '--base-path', base_arg]
def cli(*extra):
    return subprocess.run([*args, *extra], capture_output=True, text=True)
def inspect_revisions():
    result = cli()
    assert result.returncode == 0, result.stderr
    fields = dict(line.split(': ', 1) for line in result.stdout.splitlines() if ': ' in line)
    return fields['installed revision'], fields['bundled revision']
reviewed, reviewed_bundle = inspect_revisions()
exported = work / 'browser-skill-export'
result = cli('--export-to', str(exported))
assert result.returncode == 0, result.stderr
export_fields = dict(line.split(': ', 1) for line in result.stdout.splitlines() if ': ' in line)
reviewed_bundle = export_fields['bundled revision']
def files(root):
    return {str(p.relative_to(root)): p.read_bytes() for p in root.rglob('*') if p.is_file()}
assert files(exported) == files(work / 'browser-skill-bundled'), 'export differs from binary seed'
active = base / '.masc/skills/browser-lanes'
(active / 'operator-race.txt').write_text('resource edited after review')
result = cli('--apply', '--expected-revision', reviewed, '--expected-bundle-revision', reviewed_bundle)
assert result.returncode != 0, 'stale package revision accepted'
assert (active / 'operator-race.txt').read_text() == 'resource edited after review'
previous = files(active)
reviewed, reviewed_bundle = inspect_revisions()
wrong_bundle = '0' * len(reviewed_bundle)
assert reviewed_bundle != wrong_bundle
result = cli('--apply', '--expected-revision', reviewed, '--expected-bundle-revision', wrong_bundle)
assert result.returncode != 0, 'unreviewed bundle accepted'
assert files(active) == previous, 'bundle rejection changed active package'
result = cli('--apply', '--expected-revision', reviewed, '--expected-bundle-revision', reviewed_bundle)
assert result.returncode == 0, result.stderr
assert files(active) == files(exported), 'explicit update did not publish the whole package'
backups = [p for p in (base / '.masc/skill-packages').iterdir() if p.is_dir()]
assert any(files(p) == previous for p in backups), 'operator package backup missing'
print('install-smoke: reviewed native package update, stale resource rejection, and backup verified')
PYSKILL


PORT="${INSTALL_SMOKE_PORT:-18946}"
log="$work/server.log"
mkdir -p "$work/outside-checkout"
cd "$work/outside-checkout"
env -u MASC_ASSETS_DIR MASC_BASE_PATH="$base" MASC_BASE_PATH_INPUT="$base" MASC_OTEL_ENABLED=0 \
  "$prefix/masc" --base-path "$base" --host 127.0.0.1 --port "$PORT" >"$log" 2>&1 &
PID=$!

health=""
for _ in $(seq 1 30); do
  if health="$(curl -fsS "http://127.0.0.1:$PORT/health" 2>/dev/null)"; then
    break
  fi
  kill -0 "$PID" 2>/dev/null || { echo "install-smoke: server exited before answering" >&2; cat "$log" >&2; exit 1; }
  sleep 1
done

case "$health" in
  *'"status":"ok"'*) echo "install-smoke: installed server answered /health ok" ;;
  *) echo "install-smoke: /health did not report ok: ${health:-<no response>}" >&2; cat "$log" >&2; exit 1 ;;
esac

python3 "$REPO_ROOT/scripts/check-installed-dashboard.py" \
  --binary "$prefix/masc" --base-url "http://127.0.0.1:$PORT"
if [ -n "$KEEPER_IMAGE" ]; then
  python3 "$REPO_ROOT/scripts/keeper-first-turn-smoke.py" \
    --binary "$prefix/masc" --image "$KEEPER_IMAGE" \
    --output-dir "$BIN_DIR/first-keeper-turn-$ARCH"
fi
echo "install-smoke: PASS"
