#!/usr/bin/env bash
# Build this checkout's masc, masc-tui and masc-browser-host, install them into
# a prefix, and bring every registered Firefox browser lane host up to the same
# build.
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
# Usage: scripts/install-local-build.sh [--prefix DIR] [--manifest-dir DIR]
#                                       [--skip-build] [--build-dir DIR]
#   --prefix        where masc, masc-tui and masc-browser-host go (default ~/.local/bin)
#   --manifest-dir  Firefox native messaging manifests (default: the per-user directory)
#   --skip-build    install what --build-dir already holds
#   --build-dir     directory holding main_eio.exe, masc_tui.exe, masc_browser_host.exe
#                   (default <repo>/_build/default/bin)
set -euo pipefail

repo=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
prefix="$HOME/.local/bin"
build_dir="$repo/_build/default/bin"
skip_build=false
case "$(uname -s)" in
  Darwin) manifest_dir="$HOME/Library/Application Support/Mozilla/NativeMessagingHosts" ;;
  Linux) manifest_dir="$HOME/.mozilla/native-messaging-hosts" ;;
  *) echo "install-local-build: macOS and Linux only" >&2; exit 2 ;;
esac

while [ $# -gt 0 ]; do
  case "$1" in
    --prefix) prefix=${2:?--prefix needs a directory}; shift 2 ;;
    --manifest-dir) manifest_dir=${2:?--manifest-dir needs a directory}; shift 2 ;;
    --build-dir) build_dir=${2:?--build-dir needs a directory}; shift 2 ;;
    --skip-build) skip_build=true; shift ;;
    -h|--help) sed -n '15,21p' "$0"; exit 0 ;;
    *) echo "install-local-build: unknown option: $1" >&2; exit 2 ;;
  esac
done

if [ "$skip_build" = false ]; then
  # --root: a worktree under .worktrees sits inside the parent checkout's dune
  # project, which excludes that directory, so dune must be told this root.
  dune build --root "$repo" ./bin/main_eio.exe ./bin/masc_tui.exe ./bin/masc_browser_host.exe
fi

mkdir -p "$prefix"
install -m 755 "$build_dir/main_eio.exe" "$prefix/masc"
install -m 755 "$build_dir/masc_tui.exe" "$prefix/masc-tui"
install -m 755 "$build_dir/masc_browser_host.exe" "$prefix/masc-browser-host"
echo "installed masc, masc-tui, masc-browser-host into $prefix"

exec python3 - "$repo/connectors/browser/install-host.sh" "$prefix/masc-browser-host" "$manifest_dir" <<'PY'
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
