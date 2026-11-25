#!/usr/bin/env bash
# Build this checkout's masc and masc-tui and install them into a prefix. The
# deployment preflight helper and gate are installed into the prefix too, so
# the preflight an operator runs there is the one this build produced
# (#39224).
#
# Before anything is replaced, the new build judges the runtime.toml of the
# workspace its server runs on (#39311). Stored-history audits are a separate
# deployment operation; local binary replacement does not read every store.
# A runtime.toml refusal leaves every binary and
# process as it was. An install that cannot run the check stops the same way,
# with exit status 2: no workspace found, no helper in --build-dir, or a helper
# that predates the check. A workspace that does not exist yet has no
# runtime.toml to judge (the server creates it on its first start), so the
# install says so and goes on. A non-directory path, a broken symlink or an
# unobservable path is not a new workspace and stops the install.
#
# The server runs only a guest exec shim built from its own source (#52968,
# RFC host-and-shim-share-one-build-identity), so the shim goes with the
# server (#53164). A workspace shim without a sha256 sidecar was built from
# source. When it declares another source identity than this build's
# main_eio.exe, scripts/remote-ssh/build-shim.sh builds a new one from this
# checkout for the guest architecture the old shim's ELF header names. The
# new shim must declare this build's identity. It replaces the old one in
# one rename, and the old one stays beside it as masc-exec-shim.previous,
# which holds only the shim the latest rebuild replaced. All of this happens
# before any binary is replaced. A failed build (build-shim.sh needs Docker), an architecture
# this cannot build or a built shim of another source stops the install with
# exit status 1. The shim and the binaries are then as they were, and the
# error gives the command that builds the shim by hand; only a rename that
# fails after masc-exec-shim.previous was written leaves that file holding a
# copy of the shim still in place. A shim that already declares this build's
# identity is kept. A workspace with no shim is given none.
#
# The server still running refuses the new shim from this install until
# masc restart, as the restarted server refused the old one before (#53164):
# its readiness check reads the shim again for every guest it has not
# verified. So restart right after installing. To go back before a restart,
# rename masc-exec-shim.previous to masc-exec-shim.
#
# A release shim (masc-exec-shim with its sha256 sidecar) is left alone, and
# no release is asked for, unless --refresh-guest-shim is given. That option
# updates an existing release shim when deploying a server/shim change to
# microVM Keepers. The release installer places it initially.
# With this option, an existing release shim is replaced by
# the same asset of the release this build names, checked against that
# release's SHA256SUMS. Which asset is read from the sidecar, which records
# the one that was installed; nothing is guessed from this shell. A workspace
# with no shim is given none, and a shim without a sidecar is the source
# build above. A release that cannot be read leaves the shim as it is
# and says so; an asset that does not match its checksum installs nothing.
# The server refuses a shim built from another source (#52968, RFC
# host-and-shim-share-one-build-identity), so a release shim that does not
# declare this build's source identity installs nothing either, and the
# install stops with the source build to use instead
# (scripts/remote-ssh/build-shim.sh). A checkout build is never a release's
# source, so for it this option always ends there.
# MASC_RELEASE_BASE_URL and MASC_REPO name the release the way
# scripts/install.sh does.
#
# The dashboard bundle goes the same way (scripts/lib/install-workspace-dashboard.sh,
# #49980). A workspace that holds <workspace>/assets/dashboard gets this
# checkout's assets/dashboard when its .build-stamp is newer, and keeps the old
# bundle as dashboard-backup-<UTC time>. The checkout's bundle is the one
# build-dashboard-if-needed.sh (make build) last built; this script does not
# build it.
#
# Pele, the TUI's Mermaid and SVG renderer, goes with masc-tui (#47301). A
# prefix that holds masc-pele gets this checkout's tools/pele through
# scripts/install-pele.sh. A prefix with none is given none, because Pele needs
# Node.js 22 and pnpm. A failed Pele install is a warning, not a failed install.
#
# Usage: scripts/install-local-build.sh [--prefix DIR]
#                                       [--skip-build] [--build-dir DIR] [--base-path DIR]
#                                       [--refresh-guest-shim]
#                                       [--no-browser-addon]
#                                       [--print-build-targets]
#   --prefix        where masc, masc-tui, the browser Add-on programs, SSH
#                   bootstrap and deployment preflight pair go (default
#                   ~/.local/bin)
#   --skip-build    install what --build-dir already holds
#   --build-dir     directory holding main_eio.exe, masc_tui.exe,
#                   masc_native_addon_launcher.exe, masc_browser_addon_worker.exe,
#                   deployment_preflight_helper.exe,
#                   and masc_exec_ssh_bootstrap.exe
#                   (default <repo>/_build/default/bin)
#   --base-path     workspace whose runtime.toml the new build must accept, and
#                   whose browser Add-on is declared
#                   (default: the one masc would use -- MASC_BASE_PATH, a current
#                   directory holding .masc/config, then the recorded default)
#   --no-browser-addon do not build or install the browser Add-on programs, and
#                   leave the workspace's browser Add-on package and declaration
#                   as they are. Without the Add-on no browser route works.
#   --refresh-guest-shim fetch release checksums and refresh an existing release
#                   guest exec shim (one with a sha256 sidecar); default
#                   installation leaves a release shim as it is
#   --print-build-targets print the exact Dune inputs for this install and exit
#                   without locking, building, checking or changing a workspace
#
#   By default a workspace guest exec shim without a sha256 sidecar is rebuilt
#   from this checkout (scripts/remote-ssh/build-shim.sh, which needs Docker)
#   when it declares another source than this build. A failed rebuild installs
#   nothing.
set -euo pipefail

repo=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
prefix="$HOME/.local/bin"
build_dir="$repo/_build/default/bin"
skip_build=false
guest_shim=false
# Every browser route runs in the browser Add-on, so its programs are installed with masc, from the same build, unless
# --no-browser-addon says the workspace needs no browser.
browser_addon=true
browser_addon_programs=(masc_native_addon_launcher masc_browser_addon_worker)
print_build_targets=false
base_path=""
workspace_root=""
workspace_kind=""
install_args=("$@")
case "$(uname -s)" in
  Darwin)
    if [ "$(sysctl -n hw.optional.arm64 2>/dev/null || true)" != 1 ]; then
      echo "install-local-build: Intel Macs are not supported." >&2
      exit 2
    fi
    os_version=$(sw_vers -productVersion 2>/dev/null || true)
    major=${os_version%%.*}
    case "$major" in
      ''|*[!0-9]*) echo "install-local-build: cannot read macOS version" >&2; exit 2 ;;
    esac
    if [ "$major" -lt 15 ]; then
      echo "install-local-build: macOS 15.0 or later is required (found $os_version)." >&2
      exit 2
    fi
    ;;
  Linux) ;;
  *) echo "install-local-build: Apple Silicon Macs and Linux only" >&2; exit 2 ;;
esac

while [ $# -gt 0 ]; do
  case "$1" in
    --prefix) prefix=${2:?--prefix needs a directory}; shift 2 ;;
    --build-dir) build_dir=${2:?--build-dir needs a directory}; shift 2 ;;
    --refresh-guest-shim) guest_shim=true; shift ;;
    --no-browser-addon) browser_addon=false; shift ;;
    --skip-build) skip_build=true; shift ;;
    --print-build-targets) print_build_targets=true; shift ;;
    --base-path) base_path=${2:?--base-path needs a directory}; shift 2 ;;
    -h|--help) sed -n '/^# Usage:/,/^set -euo pipefail/p' "$0" | sed '$d'; exit 0 ;;
    *) echo "install-local-build: unknown option: $1" >&2; exit 2 ;;
  esac
done

# CI artifacts use the same target list as a default local install. Keep this
# read-only query before the transaction lock and every workspace operation.
build_targets=(./bin/main_eio.exe ./bin/masc_tui.exe
  ./bin/deployment_preflight_helper.exe ./bin/masc_exec_ssh_bootstrap.exe
  ./bin/masc_antigravity_path_hook.exe)
if [ "$browser_addon" = true ]; then
  for program in "${browser_addon_programs[@]}"; do
    build_targets+=("./bin/$program.exe")
  done
fi
if [ "$print_build_targets" = true ]; then
  printf '%s\n' "${build_targets[@]}"
  exit 0
fi

# Use the same lock as dune-local.sh for the complete installation transaction.
# Releasing it after build permits a concurrent wrapper clean to remove our input
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
  (cd "$repo" && scripts/dune-local.sh build --root "$repo" "${build_targets[@]}")
fi

# Validate the browser Add-on programs before preflight, guest-shim replacement
# or any installed binary changes. --skip-build needs the same complete inputs.
if [ "$browser_addon" = true ]; then
  for program in "${browser_addon_programs[@]}"; do
    if [ ! -f "$build_dir/$program.exe" ] || [ ! -x "$build_dir/$program.exe" ]; then
      echo "install-local-build: the browser Add-on needs executable $build_dir/$program.exe; nothing installed (--no-browser-addon skips it)" >&2
      exit 1
    fi
  done
fi

# Nothing is replaced or restarted yet, so the running server's editor can
# still change a value this build refuses. The helper names the workspace the
# way masc does; this script only reads its answer.
preflight_helper="$build_dir/deployment_preflight_helper.exe"
if [ ! -x "$build_dir/masc_exec_ssh_bootstrap.exe" ]; then
  echo "install-local-build: missing executable $build_dir/masc_exec_ssh_bootstrap.exe; nothing installed" >&2
  exit 1
fi
if [ ! -x "$build_dir/masc_antigravity_path_hook.exe" ]; then
  echo "install-local-build: missing executable $build_dir/masc_antigravity_path_hook.exe; nothing installed" >&2
  exit 1
fi
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
  # A signal trap replaces the default "terminate" action, so each signal
  # trap must exit itself (128+n); that exit then runs the EXIT trap.
  trap 'rm -f "$resolve_stderr"' EXIT HUP INT TERM
  trap 'exit 129' HUP
  trap 'exit 130' INT
  trap 'exit 143' TERM
  resolve_stderr=$(mktemp "${TMPDIR:-/tmp}/masc-resolve-workspace.XXXXXX")
  resolve_status=0
  resolution=$("$preflight_helper" "${resolve_args[@]}" 2>"$resolve_stderr") || resolve_status=$?
  resolve_errors=$(cat "$resolve_stderr")
  rm -f "$resolve_stderr"
  trap - EXIT HUP INT TERM HUP INT TERM
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
# probe (release, capabilities) until it restarts. A release that cannot be
# read is a line here and not a refusal: the shim already in place stays, and
# the server checks its source identity before any guest boots with it.
# Server and shim are never one release apart: the server refuses a shim of
# another source (#52968), so this step never installs one.

# python3 already classifies the workspace above, so hashing through it adds
# no tool this script has to look for.
sha256_of() {
  python3 -c 'import hashlib, sys; print(hashlib.sha256(open(sys.argv[1], "rb").read()).hexdigest())' "$1"
}

# The assets a release ships for the guest shim (scripts/install.sh,
# guest_shim_asset).
guest_shim_assets="masc-exec-shim-linux-arm64 masc-exec-shim-linux-amd64"

# The source identity a binary declares, read with the grammar the server
# reads the mounted shim with (Source_identity.scan): the literal
# lib/build_commit/probe-commit.sh generates, <commit>/clean or
# <commit>/modified:<digest>, then ';'. Prints the one identity, or "none" or
# "several (a, b)", and exits non-zero unless there is exactly one.
source_identity_of() {
  python3 -I - "$1" <<'PY'
import re, sys
object_id = rb"(?:[0-9a-f]{64}|[0-9a-f]{40})"
grammar = rb"MASC_SOURCE_IDENTITY=(" + object_id + rb"/(?:clean|modified:" + object_id + rb"));"
found = []
for match in re.findall(grammar, open(sys.argv[1], "rb").read()):
    identity = match.decode()
    if identity not in found:
        found.append(identity)
if len(found) == 1:
    print(found[0])
    sys.exit(0)
print("none" if not found else "several (" + ", ".join(found) + ")")
sys.exit(1)
PY
}

# The guest architecture a shim was built for, as build-shim.sh names it,
# read from the shim's ELF header. This shell cannot tell it: a Rosetta shell
# on Apple Silicon says x86_64. e_machine is the half-word at offset 18, read
# little-endian, as both guest architectures are. Prints arm64 or amd64, or
# what the header holds instead and exits non-zero.
guest_arch_of() {
  python3 -I - "$1" <<'PY'
import sys
ELF_MAGIC = b"\x7fELF"
EI_DATA = 5
ELFDATA2LSB = 1
E_MACHINE = 18
HEADER_BYTES = E_MACHINE + 2
GUEST_ARCHES = {0xB7: "arm64", 0x3E: "amd64"}  # EM_AARCH64, EM_X86_64
try:
    with open(sys.argv[1], "rb") as shim:
        header = shim.read(HEADER_BYTES)
except OSError as error:
    print(f"unreadable: {error.strerror}")
    sys.exit(1)
if len(header) < HEADER_BYTES or header[:len(ELF_MAGIC)] != ELF_MAGIC:
    print("not an ELF file")
    sys.exit(1)
if header[EI_DATA] != ELFDATA2LSB:
    print("not a little-endian ELF file")
    sys.exit(1)
machine = int.from_bytes(header[E_MACHINE:HEADER_BYTES], "little")
if machine not in GUEST_ARCHES:
    print(f"ELF machine 0x{machine:x}")
    sys.exit(1)
print(GUEST_ARCHES[machine])
PY
}

# One attempt each, because the build lock is held while this waits and the
# next explicit refresh tries again: SHA256SUMS is a few kilobytes, the shim about five
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
  # A shim without a sidecar is a source build, and checkout_guest_shim has
  # already said what it did with it.
  [ -f "$sidecar" ] || exit 0
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
  if ! grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$' <<<"$version"; then
    echo "install-local-build: WARN guest exec shim left as it is: $build_dir/main_eio.exe names no release version (--version said '$version')" >&2
    exit 0
  fi
  # The server binary carries the declaration its shim must match, because
  # it links the same generated Source_identity.
  if ! required_source=$(source_identity_of "$build_dir/main_eio.exe"); then
    echo "install-local-build: $build_dir/main_eio.exe does not declare exactly one source identity (found: $required_source), so no release shim can be matched to it; nothing installed" >&2
    exit 1
  fi
  guest_arch=${asset##*-}
  source_build_hint="build the shim from this checkout instead: scripts/remote-ssh/build-shim.sh --arch $guest_arch, copy dist/remote-ssh/$asset to $shim and remove $sidecar (docs/MICROVM-REMOTE-RUNBOOK.md)"
  # Fails the install when [file] does not declare [required_source]: the
  # server would refuse a guest booted with it.
  refuse_other_source() {
    local file="$1" what="$2" declared
    if declared=$(source_identity_of "$file") && [ "$declared" = "$required_source" ]; then
      return 0
    fi
    echo "install-local-build: $what declares source identity $declared, but this build is $required_source and its server refuses that shim; nothing installed. No release shim fits this build: $source_build_hint" >&2
    exit 1
  }
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
    echo "install-local-build: WARN guest exec shim left as it is: $release_base/$tag/SHA256SUMS could not be read ($(printf '%s' "$refused" | tr '\n' ' ')); rerun with --refresh-guest-shim to retry" >&2
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
    refuse_other_source "$shim" "the installed $tag guest exec shim $shim"
    echo "guest exec shim in $shim_dir is already the $tag asset"
    exit 0
  fi
  staged_shim=$(mktemp "$shim_dir/masc-exec-shim.partial.XXXXXX")
  if ! refused=$(curl -fsSL --max-time "$guest_shim_asset_timeout_s" -o "$staged_shim" "$release_base/$tag/$asset" 2>&1); then
    echo "install-local-build: WARN guest exec shim left as it is: $release_base/$tag/$asset could not be downloaded ($(printf '%s' "$refused" | tr '\n' ' ')); rerun with --refresh-guest-shim to retry" >&2
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
  refuse_other_source "$staged_shim" "$asset of $tag"
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

# The source-built shim this build's server accepts, built from this checkout
# (#53164). Before this step, every checkout install followed by masc restart
# failed each microVM Keeper's Execute with microvm_shim_other_source until
# somebody rebuilt the shim by hand. It runs before any binary is replaced
# and in a subshell like refresh_guest_shim: its EXIT trap removes the build
# directory and the staged copy on every way out, and a non-zero status ends
# the install under set -e. One rename puts the new shim in place, so a guest
# never finds the name missing. The server does not remember a refused shim
# (keeper_microvm_shim_readiness.ml), so the next request boots with it.
checkout_guest_shim() (
  shim_dir="$workspace_root/.masc/microvm/shim"
  shim="$shim_dir/masc-exec-shim"
  [ -e "$shim" ] || exit 0
  # The opposite of refresh_guest_shim's test, so each shim goes to exactly
  # one of the two steps.
  [ ! -f "$shim.sha256" ] || exit 0
  if ! required_source=$(source_identity_of "$build_dir/main_eio.exe"); then
    echo "install-local-build: $build_dir/main_eio.exe does not declare exactly one source identity (found: $required_source), so its server refuses every guest exec shim, $shim too; nothing installed" >&2
    exit 1
  fi
  if installed_source=$(source_identity_of "$shim") && [ "$installed_source" = "$required_source" ]; then
    echo "guest exec shim in $shim_dir already declares this build's source identity $required_source"
    exit 0
  fi
  guest_arch_status=0
  guest_arch=$(guest_arch_of "$shim") || guest_arch_status=$?
  if [ "$guest_arch_status" -eq 0 ]; then
    arch_arg=$guest_arch
  else
    arch_arg=ARCH
  fi
  # The command puts the shim in place with one rename, as this step does,
  # so a guest that boots meanwhile never reads a partial file.
  by_hand=$(printf 'cd %q && scripts/remote-ssh/build-shim.sh --arch %s && install -m 755 dist/remote-ssh/masc-exec-shim-linux-%s %q && mv %q %q' \
    "$repo" "$arch_arg" "$arch_arg" "$shim.partial" "$shim.partial" "$shim")
  refuse() {
    echo "install-local-build: guest exec shim $shim declares source identity $installed_source, but this build is $required_source and its server refuses that shim. $1; nothing installed. Build the shim by hand, then install again: $by_hand" >&2
    exit 1
  }
  [ "$guest_arch_status" -eq 0 ] ||
    refuse "Its ELF header names no guest architecture this install can build ($guest_arch); in the command below ARCH is arm64 or amd64"
  previous="$shim.previous"
  out=""
  staged=""
  staged_previous=""
  # Cleanup that fails says so and does not change how the step ended: under
  # errexit a failing last command here would turn a finished swap into a
  # failed install after the shim was already replaced.
  remove_staged() {
    if [ -n "$out" ]; then rm -rf "$out" || echo "install-local-build: could not remove $out" >&2; fi
    if [ -n "$staged" ]; then rm -f "$staged" || echo "install-local-build: could not remove $staged" >&2; fi
    if [ -n "$staged_previous" ]; then
      rm -f "$staged_previous" || echo "install-local-build: could not remove $staged_previous" >&2
    fi
  }
  trap remove_staged EXIT
  # build-shim.sh takes --out relative to the top of the checkout it runs in.
  # Git ignores dist/, so the build directory does not change the source
  # identity the shim is built with.
  if ! mkdir -p "$repo/dist/remote-ssh" ||
     ! out=$(mktemp -d "$repo/dist/remote-ssh/install-local-build.XXXXXX"); then
    out=""
    refuse "No build directory could be made in $repo/dist/remote-ssh"
  fi
  echo "install-local-build: building the $guest_arch guest exec shim from $repo, because the one in $shim_dir declares $installed_source"
  if ! (cd "$repo" && scripts/remote-ssh/build-shim.sh --arch "$guest_arch" --out "${out#"$repo"/}"); then
    refuse "scripts/remote-ssh/build-shim.sh --arch $guest_arch failed (the lines above say why; it needs Docker), so no shim was built for $shim"
  fi
  built="$out/masc-exec-shim-linux-$guest_arch"
  [ -f "$built" ] || refuse "scripts/remote-ssh/build-shim.sh left no $built"
  if ! staged=$(mktemp "$shim_dir/masc-exec-shim.partial.XXXXXX") ||
     ! cp "$built" "$staged" || ! chmod 755 "$staged"; then
    refuse "The built shim could not be staged in $shim_dir"
  fi
  # The identity is read from the staged copy, the bytes that are renamed
  # into place, not from the build directory, which build-shim.sh leaves
  # writable by everyone.
  if ! built_source=$(source_identity_of "$staged") || [ "$built_source" != "$required_source" ]; then
    refuse "The shim built from $repo declares $built_source instead: the checkout changed after $build_dir/main_eio.exe was built, or that build comes from another checkout. Build again without --skip-build"
  fi
  # One copy of the shim being replaced, so installs do not pile up copies.
  # Files that other hands left here are not this step's to remove.
  if ! staged_previous=$(mktemp "$shim_dir/masc-exec-shim.previous.partial.XXXXXX") ||
     ! cp -p "$shim" "$staged_previous" || ! mv "$staged_previous" "$previous"; then
    refuse "The shim in place could not be kept as $previous"
  fi
  staged_previous=""
  # A failure here leaves the shim in place and $previous holding a copy of it.
  if ! mv "$staged" "$shim"; then
    refuse "The built shim could not be renamed to $shim"
  fi
  staged=""
  echo "installed the $guest_arch guest exec shim built from $repo into $shim_dir (source identity $required_source; the previous one is kept as $previous). The running server refuses it until masc restart."
)
checkout_guest_shim
refresh_guest_shim

mkdir -p "$prefix"
install -m 755 "$build_dir/main_eio.exe" "$prefix/masc"
install -m 755 "$build_dir/masc_tui.exe" "$prefix/masc-tui"
install -m 755 "$build_dir/masc_antigravity_path_hook.exe" "$prefix/masc-antigravity-path-hook"
if [ "$browser_addon" = true ]; then
  for program in "${browser_addon_programs[@]}"; do
    install -m 755 "$build_dir/$program.exe" "$prefix/${program//_/-}"
  done
else
  # Programs an earlier install left would now run beside a masc of another
  # build. They are named, not removed: removing installed files is the
  # operator's call.
  for program in "${browser_addon_programs[@]}"; do
    if [ -e "$prefix/${program//_/-}" ]; then
      echo "install-local-build: WARN $prefix/${program//_/-} is from an earlier install, not from this build; remove it, or install without --no-browser-addon" >&2
    fi
  done
fi
install -m 755 "$build_dir/deployment_preflight_helper.exe" "$prefix/masc-deployment-preflight-helper"
install -m 755 "$build_dir/masc_exec_ssh_bootstrap.exe" "$prefix/masc-exec-ssh-bootstrap"
install -m 755 "$repo/scripts/check-runtime-deployment-preflight.sh" "$prefix/masc-check-runtime-deployment-preflight"
if [ "$browser_addon" = true ]; then
  echo "installed masc, masc-tui, masc-native-addon-launcher, masc-browser-addon-worker, masc-deployment-preflight-helper, masc-check-runtime-deployment-preflight, masc-exec-ssh-bootstrap into $prefix"
else
  echo "installed masc, masc-tui, masc-deployment-preflight-helper, masc-check-runtime-deployment-preflight, masc-exec-ssh-bootstrap into $prefix (no browser Add-on)"
fi
echo "install-local-build: a running server keeps its old build; masc restart replaces it with this one"
echo "install-local-build: stored history was not audited; for storage-format changes, follow docs/guides/DURABLE-STORE-HARD-CUT.md before restarting"

# The TUI draws graphs and charts with the masc-pele that PATH finds, and drops
# an answer without the protocol receipt it expects. An install that replaced
# masc-tui and kept an older helper broke every graph and chart until somebody
# ran scripts/install-pele.sh by hand (#47301). The step never fails the
# install: the binaries are in place by now.
if [ -e "$prefix/masc-pele" ]; then
  pele_status=0
  sh "$repo/scripts/install-pele.sh" --prefix "$prefix" || pele_status=$?
  if [ "$pele_status" -eq 0 ]; then
    echo "install-local-build: refreshed Pele in $prefix from $repo/tools/pele"
  else
    echo "install-local-build: WARN Pele in $prefix was not refreshed: scripts/install-pele.sh exited with status $pele_status; run it again once the cause above is fixed" >&2
  fi
else
  echo "install-local-build: no Pele in $prefix; none installed (scripts/install-pele.sh installs it)"
fi

# The dashboard bundle the workspace serves is not part of the binaries, and
# the server picks it up on the next request without a restart (#49980). The
# step never fails the install.
if [ "$workspace_kind" = directory ]; then
  # shellcheck source=lib/install-workspace-dashboard.sh
  . "$repo/scripts/lib/install-workspace-dashboard.sh"
  install_workspace_dashboard "$repo/assets/dashboard" "$workspace_root"
fi

# The masc just installed writes the browser Add-on package it carries into
# the workspace and declares it when the workspace has none, so the server
# attaches a package of this build. An existing declaration is left as it is
# and reported. A workspace that does not exist yet is not created here, and
# one without a config root yet (setup exits 3) is left for the first server
# start to create it.
addon_failed=false
addon_no_config_root_status=3
if [ "$browser_addon" = false ]; then
  echo "install-local-build: the browser Add-on is left as it is (--no-browser-addon)"
elif [ "$workspace_kind" = directory ]; then
  addon_status=0
  "$prefix/masc" browser-lane-setup --mode addon --base-path "$workspace_root" || addon_status=$?
  if [ "$addon_status" -eq "$addon_no_config_root_status" ]; then
    echo "install-local-build: the browser Add-on is not declared yet: $workspace_root has no config root; the first server start writes one, then run masc browser-lane-setup --mode addon --base-path $workspace_root"
  elif [ "$addon_status" -ne 0 ]; then
    addon_failed=true
  fi
else
  echo "install-local-build: the browser Add-on is not declared: workspace $workspace_root does not exist yet; run masc browser-lane-setup --mode addon --base-path $workspace_root once it does"
fi

# The masc just installed writes the Exact worker packages it carries into
# the workspace and builds their images, so a declaration that names one with
# package = "<name>" finds this build's copy. It writes no declaration. A
# package it cannot install, for one when Docker is absent, is reported and
# does not fail the install: the server reports that package as not installed.
if [ "$workspace_kind" = directory ]; then
  "$prefix/masc" exact-addon-setup --base-path "$workspace_root" ||
    echo "install-local-build: an Exact worker package of $workspace_root is not installed; the lines above say which, and masc exact-addon-setup --base-path $workspace_root tries again" >&2
else
  echo "install-local-build: the Exact worker packages are not installed: workspace $workspace_root does not exist yet; run masc exact-addon-setup --base-path $workspace_root once it does"
fi

if [ "$addon_failed" = true ]; then
  echo "install-local-build: the browser Add-on of $workspace_root is not set up; the programs above are installed" >&2
  exit 1
fi

# Keep this checkout's incremental output for the next build. Installation
# already copied its executables; reclaiming build storage is an explicit
# operator action (docs/guides/LOCAL-BUILD-STORAGE.md).
