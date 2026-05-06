#!/usr/bin/env bash
# docker-prune.sh — periodic Docker resource cleanup for masc-mcp hosts.
#
# Why this exists:
#   The repo today has cleanup-stale-worktrees.sh and
#   cleanup-merged-worktrees.sh for git, but no equivalent for Docker
#   resources. On hosts that build the image (`Dockerfile`,
#   `Dockerfile.worker-runtime`, `Dockerfile.keeper-sandbox`) and run
#   keeper-docker smoke tests (`scripts/keeper-docker-multikeeper-isolation-smoke.sh`)
#   repeatedly, dangling images / stopped containers / orphaned volumes
#   accumulate and eat disk.
#
# Default mode is dry-run (mirrors cleanup-stale-worktrees.sh idiom),
# pass --apply to actually prune.
#
# Scope:
#   - dangling images (untagged layers from rebuilds)
#   - stopped containers older than $AGE_HOURS
#   - dangling/anonymous volumes (NOT named volumes such as masc-state)
#   - builder cache older than $AGE_HOURS
#
# Out of scope (intentionally never pruned):
#   - tagged images currently in use
#   - named volumes (e.g. masc-state from docker-compose.yml)
#   - running containers
#
# Usage:
#   scripts/docker-prune.sh                # dry-run, default age 24h
#   scripts/docker-prune.sh --apply        # actually prune
#   AGE_HOURS=72 scripts/docker-prune.sh --apply

set -euo pipefail

AGE_HOURS="${AGE_HOURS:-24}"
APPLY=0

for arg in "$@"; do
  case "$arg" in
    --apply) APPLY=1 ;;
    --help|-h)
      sed -n '1,40p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *)
      echo "unknown arg: $arg" >&2
      exit 2
      ;;
  esac
done

if ! command -v docker >/dev/null 2>&1; then
  echo "docker not found in PATH; nothing to do." >&2
  exit 0
fi

if ! docker info >/dev/null 2>&1; then
  echo "docker daemon unreachable; nothing to do." >&2
  exit 0
fi

mode_label() {
  if [ "$APPLY" -eq 1 ]; then echo "APPLY"; else echo "DRY-RUN"; fi
}

run_or_echo() {
  if [ "$APPLY" -eq 1 ]; then
    "$@"
  else
    echo "[dry-run] $*"
  fi
}

echo "==> docker-prune mode=$(mode_label) AGE_HOURS=${AGE_HOURS}"

# 1. Dangling images
echo "--- dangling images ---"
docker images --filter "dangling=true" --format '{{.ID}} {{.Repository}}:{{.Tag}} {{.CreatedSince}}' || true
run_or_echo docker image prune -f --filter "until=${AGE_HOURS}h"

# 2. Stopped containers
echo "--- stopped containers ---"
docker ps -a --filter "status=exited" --filter "status=created" \
  --format '{{.ID}} {{.Names}} {{.Status}}' || true
run_or_echo docker container prune -f --filter "until=${AGE_HOURS}h"

# 3. Dangling/anonymous volumes
# Named volumes (driver=local with explicit name in compose) are safe;
# `docker volume prune` without --all only removes anonymous volumes
# not referenced by any container.
echo "--- dangling volumes ---"
docker volume ls --filter "dangling=true" --format '{{.Name}}' || true
run_or_echo docker volume prune -f

# 4. Builder cache
echo "--- builder cache ---"
docker buildx du 2>/dev/null | head -5 || docker system df --format '{{.Type}} {{.Reclaimable}}' || true
run_or_echo docker builder prune -f --filter "until=${AGE_HOURS}h"

echo "==> done ($(mode_label))"
