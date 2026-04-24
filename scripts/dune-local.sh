#!/usr/bin/env bash
set -euo pipefail

repo_root="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
lock_path="${DUNE_LOCAL_LOCK:-/tmp/me-dune-local.lock}"

usage() {
  cat <<'USAGE'
Usage: scripts/dune-local.sh [dune-subcommand] [args...]

Local Dune wrapper for multi-agent development:
  - serializes local Dune invocations with a machine-wide lock
  - defaults local concurrency to DUNE_LOCAL_JOBS, or 2
  - injects --root <repo-root> unless --root is already present

Set MASC_DUNE_THROTTLE=0 to bypass the local lock.
Set MASC_DUNE_DRY_RUN=1 to print the command without running it.
USAGE
}

args=("$@")
if [[ "${#args[@]}" -eq 0 ]]; then
  args=(build)
fi

case "${args[0]}" in
  -h|--help)
    usage
    exit 0
    ;;
esac

has_root=0
for arg in "${args[@]}"; do
  case "$arg" in
    --root|--root=*)
      has_root=1
      break
      ;;
  esac
done
if [[ -n "${DUNE_ROOT:-}" ]]; then
  has_root=1
fi

cmd=(dune)
if [[ "$has_root" -eq 0 && "${args[0]}" != -* ]]; then
  cmd+=("${args[0]}" --root "$repo_root")
  if [[ "${#args[@]}" -gt 1 ]]; then
    cmd+=("${args[@]:1}")
  fi
else
  cmd+=("${args[@]}")
fi

if [[ "${GITHUB_ACTIONS:-}" != "true" ]]; then
  export DUNE_JOBS="${DUNE_JOBS:-${DUNE_LOCAL_JOBS:-2}}"
  export DUNE_BUILD_DIR="${DUNE_BUILD_DIR:-$repo_root/_build}"
fi

printf '[dune-local] DUNE_JOBS=%s DUNE_BUILD_DIR=%s\n' \
  "${DUNE_JOBS:-auto}" "${DUNE_BUILD_DIR:-_build}" >&2
printf '[dune-local] command:' >&2
printf ' %q' "${cmd[@]}" >&2
printf '\n' >&2

if [[ "${MASC_DUNE_DRY_RUN:-0}" = "1" ]]; then
  exit 0
fi

if [[ "${GITHUB_ACTIONS:-}" = "true" || "${MASC_DUNE_THROTTLE:-1}" = "0" ]]; then
  exec "${cmd[@]}"
fi

printf '[dune-local] waiting for lock %s\n' "$lock_path" >&2
if command -v lockf >/dev/null 2>&1; then
  exec lockf "$lock_path" "${cmd[@]}"
elif command -v flock >/dev/null 2>&1; then
  exec flock "$lock_path" "${cmd[@]}"
else
  printf '[dune-local] warning: neither lockf nor flock found; running unlocked\n' >&2
  exec "${cmd[@]}"
fi
