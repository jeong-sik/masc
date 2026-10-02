#!/usr/bin/env bash
# Build this checkout's masc, masc-tui and masc-browser-host, install them into
# a prefix, and bring every registered Firefox browser lane host up to the same
# build. The deployment preflight helper and gate are installed into the prefix
# too, so the preflight an operator runs there is the one this build produced
# (#39224).
#
# install-host.sh copies the host executable into <workspace>/.masc/browser-lane/host
# so a moved checkout cannot break it. That copy is what Firefox starts, and
# nothing else replaces it, so a local install that only refreshed the prefix
# left the lane on whatever build was copied first. Every native messaging
# manifest whose launcher lives under a workspace's browser-lane/host is
# reinstalled from the new prefix binary under its own host name, and the host
# processes started from that workspace are stopped; the extension reconnects
# after five seconds and starts the new copy.
#
# Before anything is replaced, the new build judges the runtime.toml of the
# workspace its server runs on (#39311). A refusal leaves every binary and
# process as it was. Until #39431 makes the check required, an install that
# cannot run it (no workspace found, no helper in --build-dir) says so on one
# WARN line and installs as before.
#
# Usage: scripts/install-local-build.sh [--prefix DIR] [--manifest-dir DIR]
#                                       [--skip-build] [--build-dir DIR] [--base-path DIR]
#                                       [--keep-build]
#   --prefix        where masc, masc-tui, masc-browser-host and the deployment
#                   preflight pair go (default ~/.local/bin)
#   --manifest-dir  Firefox native messaging manifests (default: the per-user directory)
#   --skip-build    install what --build-dir already holds
#   --build-dir     directory holding main_eio.exe, masc_tui.exe, masc_browser_host.exe
#                   and deployment_preflight_helper.exe (default <repo>/_build/default/bin)
#   --base-path     workspace whose runtime.toml the new build must accept
#                   (default: the one masc would use -- MASC_BASE_PATH, a current
#                   directory holding .masc/config, then the recorded default)
#   --keep-build    retain build artifacts after a successful default build/install
set -euo pipefail

repo=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
prefix="$HOME/.local/bin"
build_dir="$repo/_build/default/bin"
skip_build=false
keep_build=false
custom_build_dir=false
base_path=""
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
    --skip-build) skip_build=true; shift ;;
    --base-path) base_path=${2:?--base-path needs a directory}; shift 2 ;;
    -h|--help) sed -n '21,30p' "$0"; exit 0 ;;
    *) echo "install-local-build: unknown option: $1" >&2; exit 2 ;;
  esac
done

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
required_from="required from the next version: https://github.com/jeong-sik/masc/issues/39431"
if [ ! -x "$preflight_helper" ]; then
  echo "install-local-build: WARN runtime.toml not checked: $preflight_helper is missing; build it or drop --skip-build ($required_from)" >&2
else
  resolve_args=(resolve-workspace)
  if [ -n "$base_path" ]; then
    resolve_args+=(--base-path "$base_path")
  fi
  if resolution=$("$preflight_helper" "${resolve_args[@]}" 2>/dev/null); then
    :
  elif "$preflight_helper" build-commit >/dev/null 2>&1 \
       && ! "$preflight_helper" resolve-workspace --help >/dev/null 2>&1; then
    # A runnable helper without the validation command predates this check.
    # A newer helper that fails to resolve must not silently skip validation.
    resolution="workspace=old_helper"
  else
    echo "install-local-build: runtime.toml not checked: helper failed to resolve the workspace; nothing installed" >&2
    exit 1
  fi
  workspace_state=""
  workspace_root=""
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
        echo "install-local-build: runtime.toml not checked: $preflight_helper resolved the workspace but returned no root; nothing installed" >&2
        exit 1
      fi
      if [ -d "$workspace_root" ]; then
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
      echo "install-local-build: WARN runtime.toml not checked: no workspace found; pass --base-path DIR or set MASC_BASE_PATH ($required_from)" >&2
      ;;
    old_helper)
      echo "install-local-build: WARN runtime.toml not checked: $preflight_helper predates the check (no resolve-workspace); build it or drop --skip-build ($required_from)" >&2
      ;;
    *)
      echo "install-local-build: runtime.toml not checked: $preflight_helper returned an invalid workspace answer; nothing installed" >&2
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
# it finds next, which is the mismatch this fixes.
#
# --skip-build without a helper is not just "no pair to add": if the prefix
# already holds an older pair from a previous install, upgrading the server
# alone would leave that old gate callable, still reporting the old build's
# verdict against the new server -- the exact stale state #39224 describes.
# Refuse the whole install rather than leave that half-upgraded, the same way
# a refused runtime.toml above leaves nothing installed.
if [ ! -x "$build_dir/deployment_preflight_helper.exe" ] \
   && { [ -e "$prefix/masc-check-runtime-deployment-preflight" ] || [ -e "$prefix/masc-deployment-preflight-helper" ]; }; then
  echo "install-local-build: $prefix already holds a deployment preflight pair, but $build_dir/deployment_preflight_helper.exe is missing to replace it; nothing installed. Build the helper (drop --skip-build) or remove the stale pair yourself first." >&2
  exit 1
fi

mkdir -p "$prefix"
install -m 755 "$build_dir/main_eio.exe" "$prefix/masc"
install -m 755 "$build_dir/masc_tui.exe" "$prefix/masc-tui"
install -m 755 "$build_dir/masc_browser_host.exe" "$prefix/masc-browser-host"
if [ -x "$build_dir/deployment_preflight_helper.exe" ]; then
  install -m 755 "$build_dir/deployment_preflight_helper.exe" "$prefix/masc-deployment-preflight-helper"
  install -m 755 "$repo/scripts/check-runtime-deployment-preflight.sh" "$prefix/masc-check-runtime-deployment-preflight"
  echo "installed masc, masc-tui, masc-browser-host, masc-deployment-preflight-helper, masc-check-runtime-deployment-preflight into $prefix"
else
  echo "installed masc, masc-tui, masc-browser-host into $prefix (no deployment preflight pair: $build_dir/deployment_preflight_helper.exe is missing)"
fi

python3 - "$repo/connectors/browser/install-host.sh" "$prefix/masc-browser-host" "$manifest_dir" <<'PY'
import json
import os
from pathlib import Path
import signal
import subprocess
import sys

installer, binary, manifest_dir = sys.argv[1], sys.argv[2], Path(sys.argv[3])
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
        launcher = Path(launcher)
        if launcher.parts[-len(launcher_suffix.parts):] != launcher_suffix.parts:
            continue
        base = Path(*launcher.parts[:-len(launcher_suffix.parts)])
        registered.append((name, base))

if not registered:
    print(f"no browser lane host is registered in {manifest_dir}")
    sys.exit(0)

running = subprocess.run(["ps", "-axo", "pid=,command="], capture_output=True, text=True, check=True).stdout
for name, base in registered:
    subprocess.run(["bash", installer, "--binary", binary, "--base-path", str(base),
                    "--host-name", name, "--manifest-dir", str(manifest_dir)],
                   check=True, stdout=subprocess.DEVNULL)
    host = str(base / ".masc/browser-lane/host/masc-browser-host")
    stopped = []
    for line in running.splitlines():
        pid, _, command = line.strip().partition(" ")
        if command == host or command.startswith(host + " "):
            try:
                os.kill(int(pid), signal.SIGTERM)
                stopped.append(pid)
            except ProcessLookupError:
                pass
    restart = f"stopped host pid {', '.join(stopped)}; Firefox starts the new copy" if stopped else "no host running"
    print(f"refreshed browser lane host {name} for {base} ({restart})")
PY

# Installed binaries and browser hosts now hold their own copies. Clean only
# the default output this invocation built, never externally supplied input.
# A prefix placed inside the build tree would be removed by Dune's clean.
if [ "$skip_build" = false ] && [ "$keep_build" = false ] \
    && [ "$custom_build_dir" = false ] && [ -z "${DUNE_BUILD_DIR:-}" ] \
    && [ ! -L "$repo/_build" ] \
    && [ "${MASC_DUNE_DRY_RUN:-0}" != 1 ]; then
  installed_prefix=$(cd "$prefix" && pwd -P)
  case "$installed_prefix/" in
    "$repo/_build/"*)
      echo "install-local-build: retaining build output because the install prefix is inside _build" ;;
    *)
      if (cd "$repo" && scripts/dune-local.sh clean --root "$repo"); then
        echo "install-local-build: removed default build artifacts after successful installation"
      else
        echo "install-local-build: WARN installation succeeded, but build cleanup failed" >&2
      fi ;;
  esac
fi
