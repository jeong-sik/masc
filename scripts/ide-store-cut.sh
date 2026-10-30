#!/usr/bin/env bash
# RFC-0378 §5.6 — hard cut of the IDE observation store.
#
# Dry-run by default: measures the store and prints exactly what --execute
# would do. Execution archives the store to a tar next to it, deletes the
# directory, and reminds the operator that the running server must restart
# (the LSP overlay cache keys revisions by file byte length under an
# append-only assumption a directory swap breaks — review P0-2).
#
# The store root is <project-root>/.masc-ide. MASC_BASE_PATH is that project
# root, so pass the store explicitly or let the script append .masc-ide to the
# runtime's exact base path.
set -euo pipefail

usage() {
  echo "usage: $0 [<store-root>] [--execute]" >&2
  echo "       (or set MASC_BASE_PATH and omit <store-root>)" >&2
}

STORE=""
MODE="dry-run"
case "$#" in
  0) ;;
  1)
    if [ "$1" = "--execute" ]; then
      MODE="--execute"
    else
      STORE="$1"
    fi
    ;;
  2)
    STORE="$1"
    MODE="$2"
    ;;
  *)
    usage
    exit 2
    ;;
esac

if [ "${MODE}" != "dry-run" ] && [ "${MODE}" != "--execute" ]; then
  echo "unsupported mode: ${MODE}" >&2
  usage
  exit 2
fi

if [ -z "${STORE}" ]; then
  if [ -z "${MASC_BASE_PATH:-}" ]; then
    usage
    exit 2
  fi
  STORE="${MASC_BASE_PATH%/}/.masc-ide"
fi

STORE="${STORE%/}"
if [ -z "${STORE}" ] || [ "$(basename "${STORE}")" != ".masc-ide" ]; then
  echo "refusing non-.masc-ide store target: ${STORE:-<empty>}" >&2
  exit 2
fi

if [ -L "${STORE}" ]; then
  echo "refusing symlink store target: ${STORE}" >&2
  exit 2
fi

if [ ! -d "${STORE}" ]; then
  echo "store not found: ${STORE}" >&2
  exit 1
fi

STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
ARCHIVE="${STORE%/}-pre-cut-${STAMP}.tar.gz"

if [ -e "${ARCHIVE}" ]; then
  echo "archive already exists: ${ARCHIVE}" >&2
  exit 1
fi

echo "== RFC-0378 ide store cut (${MODE}) =="
echo "store:    ${STORE}"
echo "size:     $(du -sh "${STORE}" | cut -f1)"
echo "files:    $(find "${STORE}" -type f | wc -l | tr -d ' ')"
echo "orphan:   $(du -sh "${STORE}/_orphan" 2>/dev/null | cut -f1 || echo 'absent')"
echo "by-url:   $(du -sh "${STORE}/by-url" 2>/dev/null | cut -f1 || echo 'absent')"
echo "archive:  ${ARCHIVE}"

if [ "${MODE}" != "--execute" ]; then
  echo
  echo "dry-run only. To execute:"
  echo "  1. stop the masc server (the overlay cache must not survive the swap)"
  echo "  2. $0 ${STORE} --execute"
  echo "  3. start the server — the store regrows from live keeper writes"
  exit 0
fi

# The overlay cache keys revisions by file byte length under an
# append-only assumption a directory swap breaks, so no process may hold
# store files across the cut. An open file under the store is proof the
# server (or another reader) is still running — refuse. lsof reporting
# nothing is necessarily weaker evidence (a running server holds store
# fds only around reads and writes), which is why the restart step in
# the procedure above stays mandatory rather than being replaced by
# this check.
# lsof exits non-zero on traversal warnings even when it did find open
# files, so the verdict reads the output, never the exit code.
if command -v lsof >/dev/null 2>&1; then
  OPEN_PIDS="$(lsof -t +D "${STORE}" 2>/dev/null || true)"
  if [ -n "${OPEN_PIDS}" ]; then
    echo "refusing: processes still hold files under ${STORE}:" >&2
    lsof +D "${STORE}" 2>/dev/null | head -6 >&2 || true
    echo "stop the masc server first." >&2
    exit 1
  fi
else
  echo "warning: lsof unavailable — cannot check for open store files" >&2
fi

tar -czf "${ARCHIVE}" -C "$(dirname "${STORE}")" "$(basename "${STORE}")"
tar -tzf "${ARCHIVE}" >/dev/null
echo "archived: ${ARCHIVE} ($(du -sh "${ARCHIVE}" | cut -f1))"
rm -rf "${STORE}"
echo "deleted:  ${STORE}"
echo "restart the masc server before serving IDE reads."
