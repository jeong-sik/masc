#!/usr/bin/env bash
# Build this checkout's masc, masc-tui and masc-browser-host, install them into
# a prefix, and bring every registered Firefox browser lane host up to the same
# build. The deployment preflight helper and gate are installed into the prefix
# too, so the preflight an operator runs there is the one this build produced
# (#39224).
#
# masc browser-lane-setup copies the host executable into
# <workspace>/.masc/browser-lane/host so a moved checkout cannot break it, and
# writes the extension beside it. That copy is what Firefox starts, and
# nothing else replaces it, so a local install that only refreshed the prefix
# left the lane on whatever build was copied first. Every native messaging
# manifest whose launcher lives under a workspace's browser-lane/host is
# reinstalled from the new prefix binary under its own host name, and the host
# processes started from that workspace are stopped; the extension reconnects
# after five seconds and starts the new copy. The host holding the workspace's
# BiDi host lock (a BiDi host) is left running on its old copy, because
# nothing would start it again.
#
# A lane set up with `masc browser-lane-setup --mode bidi` or `--mode host`
# registers no manifest, so the manifests cannot lead to it. The workspace this
# install works with (--base-path, or the one masc would use) is brought up as
# well when its lane is installed (a launcher and its declaration) and no
# manifest already covers it, through
# `masc browser-lane-setup --mode host`, which writes the host and the launcher
# and leaves runtime.toml alone. A lane that has an extension and no manifest
# here is named on stderr and left as it is: a host replaced beside an old
# extension would put the two on different builds. Other workspaces with such a
# lane are not found; run that command for them.
#
# Before anything is replaced, the new build judges the runtime.toml of the
# workspace its server runs on (#39311) and reads every durable store there,
# as the deploy preflight does (#43483). A refusal leaves every binary and
# process as it was. An install that cannot run the check stops the same way,
# with exit status 2: no workspace found, no helper in --build-dir, or a helper
# that predates the check. A workspace that does not exist yet has no
# runtime.toml to judge (the server creates it on its first start), so the
# install says so and goes on. A non-directory path, a broken symlink or an
# unobservable path is not a new workspace and stops the install.
#
# The guest exec shim of a microVM workspace goes with the server too. The
# release installer places it (RFC-0427 B-2); a workspace deployed from local
# builds has only this script, and its shim stayed three releases behind the
# server until a keeper log said so (#42726). When the workspace already holds
# a release shim (masc-exec-shim with its sha256 sidecar), it is replaced by
# the same asset of the release this build names, checked against that
# release's SHA256SUMS. Which asset is read from the sidecar, which records
# the one that was installed; nothing is guessed from this shell. A workspace
# with no shim is given none, and a shim without a sidecar was built by hand
# and is left alone. A release that cannot be read leaves the shim as it is
# and says so; an asset that does not match its checksum installs nothing.
# MASC_RELEASE_BASE_URL and MASC_REPO name the release the way
# scripts/install.sh does; --no-guest-shim skips the step.
#
# Usage: scripts/install-local-build.sh [--prefix DIR] [--manifest-dir DIR]
#                                       [--skip-build] [--build-dir DIR] [--base-path DIR]
#                                       [--keep-build] [--no-guest-shim]
#   --prefix        where masc, masc-tui, masc-browser-host and the deployment
#                   preflight pair go (default ~/.local/bin)
#   --manifest-dir  Firefox native messaging manifests (default: the per-user directory)
#   --skip-build    install what --build-dir already holds
#   --build-dir     directory holding main_eio.exe, masc_tui.exe, masc_browser_host.exe
#                   and deployment_preflight_helper.exe (default <repo>/_build/default/bin)
#   --base-path     workspace whose runtime.toml the new build must accept, and
#                   whose browser lane host is brought up to this build when no
#                   manifest covers it
#                   (default: the one masc would use -- MASC_BASE_PATH, a current
#                   directory holding .masc/config, then the recorded default)
#   --keep-build    retain build artifacts after a successful default build/install
#   --no-guest-shim leave the workspace's guest exec shim as it is
set -euo pipefail

repo=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
prefix="$HOME/.local/bin"
build_dir="$repo/_build/default/bin"
skip_build=false
keep_build=false
guest_shim=true
custom_build_dir=false
base_path=""
workspace_root=""
install_args=("$@")
case "$(uname -s)" in
  Darwin) manifest_dir="$HOME/Library/Application Support/Mozilla/NativeMessagingHosts" ;;
  Linux) manifest_dir="$HOME/.mozilla/native-messaging-hosts" ;;
  *) echo "install-local-build: macOS and Linux only" >&2; exit 2 ;;
esac

while [ $# -gt 0 ]; do
  case "$1" in
    --prefix) prefix=${2:?--prefix needs a directory}; shift 2 ;;
    --manifest-dir) manifest_dir=${2:?--manifest-dir needs a directory}; shift 2 ;;
    --build-dir) build_dir=${2:?--build-dir needs a directory}; custom_build_dir=true; shift 2 ;;
    --keep-build) keep_build=true; shift ;;
    --no-guest-shim) guest_shim=false; shift ;;
    --skip-build) skip_build=true; shift ;;
    --base-path) base_path=${2:?--base-path needs a directory}; shift 2 ;;
    -h|--help) sed -n '/^# Usage:/,/^set -euo pipefail/p' "$0" | sed '$d'; exit 0 ;;
    *) echo "install-local-build: unknown option: $1" >&2; exit 2 ;;
  esac
done

# Use the same lock as dune-local.sh for the complete installation transaction.
# Releasing it after build permits another install's clean to remove our input
# while preflight, binary copies or browser refresh are still using it.
if [ "${MASC_DUNE_LOCK_HELD:-0}" != 1 ] && [ "${MASC_DUNE_DRY_RUN:-0}" != 1 ]; then
  repo_lock_key=$(printf '%s' "$repo" | cksum | awk '{print $1}')
  install_lock="${DUNE_LOCAL_LOCK:-${TMPDIR:-/tmp}/masc-dune-${UID:-$(id -u)}-${repo_lock_key}.lock}"
  # ${install_args[@]+...} guard: bash 3.2 (macOS /bin/bash) treats
  # "${empty_array[@]}" as unbound under set -u, and an argument-less
  # invocation re-execs with zero args.
  if command -v lockf >/dev/null 2>&1; then
    exec lockf -k "$install_lock" env MASC_DUNE_LOCK_HELD=1 bash "$repo/scripts/install-local-build.sh" ${install_args[@]+"${install_args[@]}"}
  elif command -v flock >/dev/null 2>&1; then
    exec flock "$install_lock" env MASC_DUNE_LOCK_HELD=1 bash "$repo/scripts/install-local-build.sh" ${install_args[@]+"${install_args[@]}"}
  else
    echo "install-local-build: a shared build lock requires lockf or flock" >&2
    exit 1
  fi
fi

if [ "$skip_build" = false ]; then
  # Built through dune-local.sh, which stops before Dune runs when the active
  # switch's OCaml is not the one dune-project names, when an external pin
  # differs from scripts/opam-pin-external-deps.sh, or when a findlib library
  # is missing. A plain `dune build` linked whatever the switch held: installs
  # went out on OCaml 5.5.0 after the repo moved to 5.5.1, and with an ocaml-dos
  # older than the pin. --root: a worktree under .worktrees sits inside the
  # parent checkout's dune project, which excludes that directory.
  (cd "$repo" && scripts/dune-local.sh build --root "$repo" \
    ./bin/main_eio.exe ./bin/masc_tui.exe ./bin/masc_browser_host.exe \
    ./bin/deployment_preflight_helper.exe)
fi

# Nothing is replaced or restarted yet, so the running server's editor can
# still change a value this build refuses. The helper names the workspace the
# way masc does; this script only reads its answer.
preflight_helper="$build_dir/deployment_preflight_helper.exe"
if [ "$skip_build" = true ]; then
  build_hint="Build it, or drop --skip-build."
else
  build_hint="Build it into $build_dir."
fi
if [ ! -x "$preflight_helper" ]; then
  echo "install-local-build: runtime.toml not checked: $preflight_helper is missing; nothing installed. $build_hint" >&2
  exit 2
else
  resolve_args=(resolve-workspace)
  if [ -n "$base_path" ]; then
    resolve_args+=(--base-path "$base_path")
  fi
  # The helper's stderr is kept apart from its key=value answer and shown only
  # when the lookup fails or its answer is refused. An old helper's "unknown
  # command" is expected noise, but a helper that dies at start is not a
  # missing workspace: every main build exited at start on an undecodable tool
  # TOML (#44049), and this branch reported only that the workspace was not
  # resolved. The file exists only while the helper runs: the trap removes it
  # when a signal ends the script in that window, and the text moves into
  # resolve_errors afterwards. A signal that lands after mktemp created the
  # file and before the assignment below, or SIGKILL, still leaves it.
  resolve_stderr=""
  trap 'rm -f "$resolve_stderr"' EXIT
  resolve_stderr=$(mktemp "${TMPDIR:-/tmp}/masc-resolve-workspace.XXXXXX")
  resolve_status=0
  resolution=$("$preflight_helper" "${resolve_args[@]}" 2>"$resolve_stderr") || resolve_status=$?
  resolve_errors=$(cat "$resolve_stderr")
  rm -f "$resolve_stderr"
  trap - EXIT
  if [ "$resolve_status" -eq 0 ]; then
    :
  elif "$preflight_helper" build-commit >/dev/null 2>&1 \
       && ! "$preflight_helper" resolve-workspace --help >/dev/null 2>&1; then
    # A runnable helper without the validation command predates this check.
    # A newer helper that fails to resolve must not silently skip validation.
    resolution="workspace=old_helper"
  else
    echo "install-local-build: runtime.toml not checked: $preflight_helper resolve-workspace exited with status $resolve_status; nothing installed. Its error output:" >&2
    printf '%s\n' "${resolve_errors:-(none)}" >&2
    exit 1
  fi
  workspace_state=""
  workspace_source=""
  while IFS='=' read -r key value; do
    case "$key" in
      workspace) workspace_state=$value ;;
      root) workspace_root=$value ;;
      source) workspace_source=$value ;;
    esac
  done <<< "$resolution"
  case "$workspace_state" in
    resolved)
      if [ -z "$workspace_root" ]; then
        echo "install-local-build: runtime.toml not checked: $preflight_helper resolved the workspace but returned no root; nothing installed. Its error output:" >&2
        printf '%s\n' "${resolve_errors:-(none)}" >&2
        exit 1
      fi
      # A failed shell directory test also means ENOTDIR, EACCES or a broken
      # symlink. Only actual absence below an existing directory permits a
      # new workspace; every other failed observation stops before replacement.
      if ! workspace_kind=$(python3 - "$workspace_root" <<'PY'
import errno
import os
import stat
import sys

def classify(path):
    try:
        status = os.stat(path)
    except FileNotFoundError:
        ancestor = path
        while True:
            try:
                os.lstat(ancestor)
            except FileNotFoundError:
                parent = os.path.dirname(ancestor)
                if parent == ancestor:
                    raise
                ancestor = parent
                continue
            # Follow a discovered symlink only after lstat established it is
            # present: a dangling link must not become permission to install.
            status = os.stat(ancestor)
            if not stat.S_ISDIR(status.st_mode):
                raise NotADirectoryError(errno.ENOTDIR, "workspace ancestor is not a directory", ancestor)
            return "absent"
    if not stat.S_ISDIR(status.st_mode):
        raise NotADirectoryError(errno.ENOTDIR, "workspace is not a directory", path)
    return "directory"

try:
    print(classify(sys.argv[1]))
except OSError as error:
    print(f"install-local-build: cannot observe workspace: {error}", file=sys.stderr)
    sys.exit(2)
PY
      ); then
        echo "install-local-build: workspace $workspace_root could not be checked; nothing installed." >&2
        exit 2
      fi
      if [ "$workspace_kind" = directory ]; then
        echo "install-local-build: checking runtime.toml of $workspace_root (workspace from $workspace_source)"
        MASC_DEPLOYMENT_PREFLIGHT_HELPER="$preflight_helper" \
          "$repo/scripts/check-runtime-deployment-preflight.sh" \
          --base-path "$workspace_root" \
          --runtime-config-only
        # Boot reads only the stores it refuses on; a Preflight_only store is
        # read before a start by the deploy preflight alone (RFC
        # every-durable-store-has-one-boot-policy). This install read
        # runtime.toml alone, so the Memory admission queues #42020 hard-cut
        # stayed unreadable from 2026-10-10 to 10-17 while every server ran
        # (#43483). The scan reads with this build's decoders and writes
        # nothing, so the running server is left as it is.
        echo "install-local-build: checking stored state of $workspace_root"
        if ! "$preflight_helper" validate-stores --base-path "$workspace_root"; then
          echo "install-local-build: this build cannot read the stored state listed above; nothing installed. Stop every server on $workspace_root, fix each listed store as its \"Fresh state required\" entry says (CHANGELOG.md, or changelog.d/ before a release), run this install again, then start the server." >&2
          exit 1
        fi
      else
        echo "install-local-build: runtime.toml not checked: workspace $workspace_root (from $workspace_source) does not exist yet"
      fi
      ;;
    none)
      if [ -n "$base_path" ]; then
        echo "install-local-build: runtime.toml not checked: $preflight_helper could not resolve --base-path $base_path to a workspace; nothing installed." >&2
      else
        echo "install-local-build: runtime.toml not checked: no workspace found; nothing installed. Pass --base-path DIR or set MASC_BASE_PATH." >&2
      fi
      exit 2
      ;;
    old_helper)
      echo "install-local-build: runtime.toml not checked: $preflight_helper predates the check (no resolve-workspace); nothing installed. $build_hint" >&2
      exit 2
      ;;
    *)
      echo "install-local-build: runtime.toml not checked: $preflight_helper returned an invalid workspace answer; nothing installed. Its error output:" >&2
      printf '%s\n' "${resolve_errors:-(none)}" >&2
      exit 1
      ;;
  esac
fi

# The deployment preflight pair goes with the server, not behind it. The gate
# resolves its helper beside itself first (check-runtime-deployment-preflight.sh
# L95), so a prefix that holds only the server leaves the operator running
# whatever helper was installed last: on 2026-09-26 the installed helper was
# from 09-07 and its older decoder refused 23,767 rows the running server read
# fine (#39224). Release install.sh already ships both (L1083, L1415-L1416);
# this keeps a local build install on the same footing. The pair is installed
# together or not at all: a gate without its helper would fall back to whatever
# it finds next, which is the mismatch this fixes. The helper is required above,
# so every install replaces the pair together with the server.

# The guest shim is staged before any binary is replaced, so an asset that
# fails its checksum leaves the prefix and the workspace as they were. The
# guests read the shim directory through a read-only mount and the server
# execs the shim anew for each request, so a running guest runs the new shim
# on its next request. The server keeps what the old shim answered to its
# probe (release, capabilities) until it restarts. Server and shim keep
# working one release apart (#33425), which is why a release that cannot be
# read is a line here and not a refusal.

# python3 already refreshes the browser lane hosts below, so hashing through
# it adds no tool this script has to look for.
sha256_of() {
  python3 -c 'import hashlib, sys; print(hashlib.sha256(open(sys.argv[1], "rb").read()).hexdigest())' "$1"
}

# The assets a release ships for the guest shim (scripts/install.sh,
# guest_shim_asset).
guest_shim_assets="masc-exec-shim-linux-arm64 masc-exec-shim-linux-amd64"

# One attempt each, because the build lock is held while this waits and the
# next install tries again: SHA256SUMS is a few kilobytes, the shim about five
# megabytes.
guest_shim_sums_timeout_s=20
guest_shim_asset_timeout_s=120

# Runs in a subshell: its EXIT trap removes whatever was staged on every way
# out, and [exit] here ends the step, with a non-zero status ending the
# install under set -e.
refresh_guest_shim() (
  [ "$guest_shim" = true ] || exit 0
  shim_dir="$workspace_root/.masc/microvm/shim"
  shim="$shim_dir/masc-exec-shim"
  sidecar="$shim.sha256"
  [ -e "$shim" ] || exit 0
  if [ ! -f "$sidecar" ]; then
    echo "install-local-build: guest exec shim $shim has no sha256 sidecar (built by hand); left as it is"
    exit 0
  fi
  # The sidecar is the release's SHA256SUMS line for the asset that was
  # installed: "<sha256>  <asset>". The asset names the guest architecture,
  # which this shell cannot tell: a Rosetta shell on Apple Silicon says x86_64.
  recorded=""
  asset=""
  read -r recorded asset 2>/dev/null < "$sidecar" || true
  case " $guest_shim_assets " in
    *" $asset "*) ;;
    *)
      echo "install-local-build: WARN guest exec shim left as it is: $sidecar does not name a release shim asset (it names '$asset')" >&2
      exit 0
      ;;
  esac
  version=$(MASC_RUNTIME_EVENTS=0 "$build_dir/main_eio.exe" --version 2>/dev/null | tail -n 1) || version=""
  if ! printf '%s' "$version" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$'; then
    echo "install-local-build: WARN guest exec shim left as it is: $build_dir/main_eio.exe names no release version (--version said '$version')" >&2
    exit 0
  fi
  release_base="${MASC_RELEASE_BASE_URL:-https://github.com/${MASC_REPO:-jeong-sik/masc}/releases/download}"
  tag="v$version"
  sums=""
  staged_shim=""
  staged_sidecar=""
  remove_staged() {
    for staged in "$sums" "$staged_shim" "$staged_sidecar"; do
      [ -z "$staged" ] || rm -f "$staged"
    done
  }
  trap remove_staged EXIT
  sums=$(mktemp "${TMPDIR:-/tmp}/masc-guest-shim-sums.XXXXXX")
  if ! refused=$(curl -fsSL --max-time "$guest_shim_sums_timeout_s" -o "$sums" "$release_base/$tag/SHA256SUMS" 2>&1); then
    echo "install-local-build: WARN guest exec shim left as it is: $release_base/$tag/SHA256SUMS could not be read ($(printf '%s' "$refused" | tr '\n' ' ')); the next install tries again" >&2
    exit 0
  fi
  expected=$(awk -v asset="$asset" '$2 == asset { print $1; exit }' "$sums")
  if [ -z "$expected" ]; then
    echo "install-local-build: WARN guest exec shim left as it is: release $tag lists no $asset in its SHA256SUMS" >&2
    exit 0
  fi
  if ! installed=$(sha256_of "$shim"); then
    echo "install-local-build: the sha256 of $shim could not be computed; nothing installed" >&2
    exit 1
  fi
  if [ "$recorded" = "$expected" ] && [ "$installed" = "$expected" ]; then
    echo "guest exec shim in $shim_dir is already the $tag asset"
    exit 0
  fi
  staged_shim=$(mktemp "$shim_dir/masc-exec-shim.partial.XXXXXX")
  if ! refused=$(curl -fsSL --max-time "$guest_shim_asset_timeout_s" -o "$staged_shim" "$release_base/$tag/$asset" 2>&1); then
    echo "install-local-build: WARN guest exec shim left as it is: $release_base/$tag/$asset could not be downloaded ($(printf '%s' "$refused" | tr '\n' ' ')); the next install tries again" >&2
    exit 0
  fi
  if ! downloaded=$(sha256_of "$staged_shim"); then
    echo "install-local-build: the sha256 of the downloaded $asset could not be computed; nothing installed" >&2
    exit 1
  fi
  if [ "$downloaded" != "$expected" ]; then
    echo "install-local-build: $asset of $tag does not match its SHA256SUMS line ($expected); nothing installed" >&2
    exit 1
  fi
  chmod 755 "$staged_shim"
  staged_sidecar=$(mktemp "$shim_dir/masc-exec-shim.sha256.partial.XXXXXX")
  printf '%s  %s\n' "$expected" "$asset" > "$staged_sidecar"
  chmod 644 "$staged_sidecar"
  # Two files cannot change in one step: a guest that boots between the two
  # renames is refused once (microvm_shim_hash_mismatch) and boots the next
  # time.
  mv "$staged_shim" "$shim"
  staged_shim=""
  mv "$staged_sidecar" "$sidecar"
  staged_sidecar=""
  echo "installed the $tag guest exec shim into $shim_dir (replacing sha256 $recorded)"
)
refresh_guest_shim

mkdir -p "$prefix"
install -m 755 "$build_dir/main_eio.exe" "$prefix/masc"
install -m 755 "$build_dir/masc_tui.exe" "$prefix/masc-tui"
install -m 755 "$build_dir/masc_browser_host.exe" "$prefix/masc-browser-host"
install -m 755 "$build_dir/deployment_preflight_helper.exe" "$prefix/masc-deployment-preflight-helper"
install -m 755 "$repo/scripts/check-runtime-deployment-preflight.sh" "$prefix/masc-check-runtime-deployment-preflight"
echo "installed masc, masc-tui, masc-browser-host, masc-deployment-preflight-helper, masc-check-runtime-deployment-preflight into $prefix"

python3 - "$prefix/masc" "$prefix/masc-browser-host" "$manifest_dir" "$workspace_root" <<'PY'
import fcntl
import filecmp
import json
import os
from pathlib import Path
import signal
import struct
import subprocess
import sys

masc, binary, manifest_dir = sys.argv[1], sys.argv[2], Path(sys.argv[3])
# The answer of masc's own lookup (the deployment preflight helper), which trims
# and normalizes the path as every masc command does; a path this shell was
# merely given is not the one masc would write to.
workspace = Path(sys.argv[4])
launcher_suffix = Path(".masc/browser-lane/host/launch")

registered = []
if manifest_dir.is_dir():
    for manifest in sorted(manifest_dir.glob("*.json")):
        try:
            declared = json.loads(manifest.read_text())
        except (OSError, ValueError):
            continue
        name, launcher = declared.get("name"), declared.get("path")
        if not isinstance(name, str) or not isinstance(launcher, str):
            continue
        if "\0" in name or "\0" in launcher:
            # Neither can be a host name or a path, and a process cannot be
            # started with one.
            continue
        launcher = Path(launcher)
        if launcher.parts[-len(launcher_suffix.parts):] != launcher_suffix.parts:
            continue
        base = Path(*launcher.parts[:-len(launcher_suffix.parts)])
        registered.append((name, base, declared["path"]))

# A lane set up with `masc browser-lane-setup --mode bidi` or `--mode host`
# registers no manifest, so the manifests above cannot lead to it. The one
# workspace this install works with is looked at as well: when its lane is
# installed and no registration already covers it, its host is brought up too.
def same_directory(a, b):
    try:
        return os.path.realpath(a) == os.path.realpath(b)
    except (OSError, ValueError):
        return False

# Installed as masc reads it (lib/browser_lane_launcher.ml): the launcher and
# the declaration beside it, both written by one installation. A directory that
# cannot be read holds no lane this script can refresh.
def lane_installed(base):
    host_directory = base / ".masc/browser-lane/host"
    try:
        return (host_directory / "launch").is_file() and (host_directory / "launch.json").is_file()
    except OSError:
        return False

def lane_has_extension(base):
    try:
        return (base / ".masc/browser-lane/extension/manifest.json").is_file()
    except OSError:
        return False

unregistered = []
if lane_installed(workspace) and not any(same_directory(workspace, base) for _, base, _ in registered):
    if lane_has_extension(workspace):
        # Its manifest is in another directory than this one. A host replaced
        # beside an extension that is not would put the two on different
        # builds, and the extension is written for the host that comes with it.
        print(f"install-local-build: WARN the browser lane of {workspace} has an extension and no "
              f"manifest in {manifest_dir}, so neither its host nor its extension is refreshed; run "
              "masc browser-lane-setup --mode extension with that lane's --manifest-dir",
              file=sys.stderr)
    else:
        unregistered.append(workspace)

if not registered and not unregistered:
    print(f"no browser lane host is registered in {manifest_dir}")
    sys.exit(0)

def bidi_host_pid(base):
    # Firefox starts an extension host again once it stops; nothing starts a
    # stopped BiDi host again. A BiDi host holds a lockf lock on
    # bidi-host.lock while it runs (lib/browser_bidi_host_record.ml), and
    # F_GETLK names the holder without taking the lock, so a host starting
    # meanwhile is not refused. Its record's pid can outlive it, and ps joins
    # arguments with spaces that a path may hold, so neither names it.
    try:
        fd = os.open(base / ".masc/browser-lane/bidi-host.lock", os.O_RDONLY)
    except FileNotFoundError:
        return None
    try:
        # struct flock orders its fields differently on the two platforms.
        if sys.platform == "darwin":
            layout = "@qqihh"
            asked = struct.pack(layout, 0, 0, 0, fcntl.F_WRLCK, os.SEEK_SET)
            _, _, holder, kind, _ = struct.unpack(layout, fcntl.fcntl(fd, fcntl.F_GETLK, asked))
        elif sys.platform.startswith("linux"):
            layout = "@hhqqi4x"
            asked = struct.pack(layout, fcntl.F_WRLCK, os.SEEK_SET, 0, 0, 0)
            kind, _, _, _, holder = struct.unpack(layout, fcntl.fcntl(fd, fcntl.F_GETLK, asked))
        else:
            sys.exit(f"cannot read the BiDi host lock's holder on {sys.platform}")
    finally:
        os.close(fd)
    return None if kind == fcntl.F_UNLCK else str(holder)

# -ww: whole commands, so a long host path is matched in full.
running = subprocess.run(["ps", "-ww", "-axo", "pid=,command="], capture_output=True, text=True, check=True).stdout
stopped_pids = set()
# The masc just installed brings a workspace's lane to the build it was built
# from, and this says what is left wrong when it did not. masc resolves
# --base-path as it does for every command (it trims the value and drops a
# trailing .masc), so a registration whose workspace path does not survive that
# would be written somewhere else and still look refreshed: the manifest it
# rewrites is compared with the one it replaced, and the host copy with the
# binary just installed.
def refresh(name, base, declared_path):
    registration = manifest_dir / f"{name}.json"
    previous = registration.read_text() if registration.is_file() else None
    result = subprocess.run(
        [masc, "browser-lane-setup", "--mode", "extension", "--binary", binary,
         "--base-path", str(base), "--host-name", name, "--manifest-dir", str(manifest_dir)],
        stdout=subprocess.DEVNULL)
    if result.returncode != 0:
        return f"masc browser-lane-setup exited {result.returncode}"
    try:
        now = json.loads(registration.read_text()).get("path")
    except (OSError, ValueError):
        now = None
    if not isinstance(now, str) or os.path.realpath(now) != os.path.realpath(declared_path):
        if previous is None:
            registration.unlink(missing_ok=True)
        else:
            registration.write_text(previous)
        return (f"masc resolved {base} to another workspace (it wrote {now}); "
                "the registration is as it was")
    copy = base / ".masc/browser-lane/host/masc-browser-host"
    if not copy.is_file() or not filecmp.cmp(binary, copy, shallow=False):
        return f"{copy} is not the host just installed"
    return None

# A lane with no registration is brought up the same way, without a manifest
# to compare: the host copy beside its launcher must be the one just installed.
# masc writes the copy where it resolves --base-path, so a path it would resolve
# elsewhere leaves this copy as it was and is reported.
def refresh_host(base):
    result = subprocess.run(
        [masc, "browser-lane-setup", "--mode", "host", "--binary", binary, "--base-path", str(base)],
        stdout=subprocess.DEVNULL)
    if result.returncode != 0:
        return f"masc browser-lane-setup exited {result.returncode}"
    copy = base / ".masc/browser-lane/host/masc-browser-host"
    if not copy.is_file() or not filecmp.cmp(binary, copy, shallow=False):
        return f"{copy} is not the host just installed"
    return None

def stop_running_hosts(base):
    host = str(base / ".masc/browser-lane/host/masc-browser-host")
    bidi_host = bidi_host_pid(base)
    stopped, kept = [], []
    for line in running.splitlines():
        pid, _, command = line.strip().partition(" ")
        if (command == host or command.startswith(host + " ")) and pid not in stopped_pids:
            if pid == bidi_host:
                kept.append(pid)
                continue
            try:
                os.kill(int(pid), signal.SIGTERM)
                stopped.append(pid)
                stopped_pids.add(pid)
            except ProcessLookupError:
                pass
    said = []
    if stopped:
        said.append(f"stopped host pid {', '.join(stopped)}; Firefox starts the new copy")
    if kept:
        # The installer replaced the file, so the running host keeps the copy
        # it started with.
        said.append(f"kept BiDi host pid {', '.join(kept)}, which nothing would start again; "
                    "it runs its old copy until it is restarted")
    return "; ".join(said) or "no host running"

failures = []
# The workspaces after a failed one are still brought up to date, and the failed
# one's running host is left alone: it still runs the copy it has.
for name, base, declared_path in registered:
    problem = refresh(name, base, declared_path)
    if problem:
        failures.append(f"browser lane host {name} for {base}: {problem}")
        continue
    print(f"refreshed browser lane host {name} for {base} ({stop_running_hosts(base)})")
for base in unregistered:
    problem = refresh_host(base)
    if problem:
        failures.append(f"browser lane host for {base}: {problem}")
        continue
    print(f"refreshed browser lane host for {base} ({stop_running_hosts(base)})")
if failures:
    for failure in failures:
        print(f"install-local-build: could not refresh {failure}", file=sys.stderr)
    sys.exit(1)
PY

# Installed binaries and browser hosts now hold their own copies. Clean only
# the default output this invocation built, never externally supplied input.
# Installed destinations and the selected workspace must survive Dune's clean.
if [ "$skip_build" = false ] && [ "$keep_build" = false ] \
    && [ "$custom_build_dir" = false ] && [ -z "${DUNE_BUILD_DIR:-}" ] \
    && [ ! -L "$repo/_build" ] \
    && [ "${MASC_DUNE_DRY_RUN:-0}" != 1 ]; then
  if python3 - "$repo/_build" "$prefix" "$manifest_dir" "$workspace_root" <<'PY'
import json
from pathlib import Path
import sys

build, prefix, manifests = (Path(arg).resolve() for arg in sys.argv[1:4])
destinations = [prefix, manifests]
if sys.argv[4]:
    destinations.append(Path(sys.argv[4]).resolve())
if manifests.is_dir():
    for manifest in manifests.glob("*.json"):
        try:
            declared = json.loads(manifest.read_text())
        except (OSError, ValueError):
            print("install-local-build: retaining output: manifest destination is unreadable", file=sys.stderr)
            sys.exit(1)
        if isinstance(declared, dict) and isinstance(declared.get("path"), str):
            destinations.append(Path(declared["path"]).resolve())
if any(path == build or build in path.parents for path in destinations):
    print("install-local-build: retaining output: an installed destination or selected workspace is inside _build")
    sys.exit(1)
PY
  then
      if (cd "$repo" && scripts/dune-local.sh clean --root "$repo"); then
        echo "install-local-build: removed default build artifacts after successful installation"
      else
        echo "install-local-build: WARN installation succeeded, but build cleanup failed" >&2
      fi
  fi
fi
