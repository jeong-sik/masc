#!/usr/bin/env bash
# Library code that runs inside the server starts children one way.
#
# eio_posix's process manager spawns with fork(2), and on macOS the parent
# side of a fork locks every malloc zone; with masc's 1-2 GB heap that held
# the main domain about 140 ms per spawn. Posix_spawn_process_mgr.mgr runs
# no atfork handler and takes the same arguments, so lib/ uses it and the
# runtime is wired to it in server_runtime_bootstrap.
#
# Entry points under bin/ and test code keep their own choice: they are
# separate processes with small heaps, and the tools/spawn_bench comparison
# needs the fork manager on purpose.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

if ! command -v rg >/dev/null 2>&1; then
  echo "[one-process-manager] required tool missing: rg" >&2
  exit 2
fi

tmp="$(mktemp -t one-process-manager.XXXXXX)"
trap 'rm -f "$tmp"' EXIT

(
  cd "$ROOT"
  rg -n --glob '*.ml' --glob '*.mli' --glob '!**/test/**' \
    'Eio\.Stdenv\.process_mgr' lib
) >"$tmp" || true

if [[ -s "$tmp" ]]; then
  echo "[one-process-manager] lib/ reaches for eio's fork-based process manager" >&2
  cat "$tmp" >&2
  echo "[one-process-manager] use Posix_spawn_process_mgr.mgr instead" >&2
  exit 1
fi

echo "[one-process-manager] OK"
