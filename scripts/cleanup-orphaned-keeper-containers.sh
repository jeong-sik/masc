#!/usr/bin/env bash
# cleanup-orphaned-keeper-containers.sh — reap exited keeper sandbox
# containers that lost their parent (server crash, lost SSH session, etc.).
#
# Why this exists:
#   `docker run --rm` (used by scripts/keeper-docker-multikeeper-isolation-smoke.sh)
#   self-cleans on a clean exit, but if the parent process is killed
#   mid-run, or if `--rm` fails (Docker daemon hiccup), the container
#   stays. There's no in-tree reaper today.
#
# Convention:
#   Mark every keeper-sandbox container with the label
#       masc.keeper.sandbox=true
#   Optionally also:
#       masc.keeper.id=<keeper-name>
#       masc.keeper.session=<server-session-uuid>
#
#   Containers without the label are not touched. This script is a
#   strictly additive safety net; it never removes named volumes (e.g.
#   masc-state from docker-compose.yml) and never touches running
#   containers.
#
# Usage:
#   scripts/cleanup-orphaned-keeper-containers.sh                # dry-run, AGE_HOURS=2
#   scripts/cleanup-orphaned-keeper-containers.sh --apply
#   AGE_HOURS=24 scripts/cleanup-orphaned-keeper-containers.sh --apply
#   LABEL=masc.keeper.sandbox=true scripts/cleanup-orphaned-keeper-containers.sh

set -euo pipefail

AGE_HOURS="${AGE_HOURS:-2}"
LABEL="${LABEL:-masc.keeper.sandbox=true}"
APPLY=0

for arg in "$@"; do
  case "$arg" in
    --apply) APPLY=1 ;;
    --help|-h)
      sed -n '2,27p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *)
      echo "unknown arg: $arg" >&2
      exit 2
      ;;
  esac
done

case "$AGE_HOURS" in
  ''|*[!0-9]*)
    echo "invalid AGE_HOURS=${AGE_HOURS}; expected positive integer hours" >&2
    exit 2
    ;;
esac
if [ "$AGE_HOURS" -le 0 ]; then
  echo "invalid AGE_HOURS=${AGE_HOURS}; expected positive integer hours" >&2
  exit 2
fi

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

echo "==> cleanup-orphaned-keeper-containers mode=$(mode_label) AGE_HOURS=${AGE_HOURS} LABEL=${LABEL}"

# List exited+created+dead containers carrying our label, then filter by
# FinishedAt age. We deliberately do NOT touch status=running.
# Use a temp file (not mapfile) so this works on bash 3.2 (macOS default).
candidates_file=$(mktemp -t masc-orphan-keeper-cands.XXXXXX)
trap 'rm -f "$candidates_file"' EXIT
docker ps -a \
  --filter "label=${LABEL}" \
  --filter "status=exited" \
  --filter "status=created" \
  --filter "status=dead" \
  --format '{{.ID}}' > "$candidates_file"

if [ ! -s "$candidates_file" ]; then
  echo "no labeled non-running keeper containers found."
  exit 0
fi

now_epoch=$(date -u +%s)
removed=0
inspected=0
while IFS= read -r cid; do
  [ -z "$cid" ] && continue
  inspected=$((inspected + 1))
  finished=$(docker inspect --format '{{.State.FinishedAt}}' "$cid" 2>/dev/null || echo "")
  # Make the name lookup best-effort like [finished]: if the container
  # disappears between listing and inspect (or inspect errors transiently),
  # the script must not exit under [set -e]. Default to the container ID
  # so log lines remain attributable.
  name_raw=$(docker inspect --format '{{.Name}}' "$cid" 2>/dev/null || true)
  name=$(printf '%s\n' "$name_raw" | sed 's|^/||')
  if [ -z "$name" ]; then name="$cid"; fi
  if [ -z "$finished" ] || [ "$finished" = "0001-01-01T00:00:00Z" ]; then
    # never started cleanly — treat as old
    age_hours=999
  else
    # Trim Docker RFC3339Nano fractional seconds to 6 digits so
    # python3 datetime.fromisoformat accepts the value on platforms
    # without GNU [date -d]. Docker emits up to 9 fractional digits
    # (e.g. ...123456789Z) which the stdlib parser rejected, leaving
    # finished_epoch=0 and silently skipping removals on macOS.
    finished_iso="$finished"
    finished_epoch=$(date -u -d "$finished" +%s 2>/dev/null \
      || python3 -c "
import datetime, re, sys
raw = sys.argv[1].replace('Z', '+00:00')
m = re.match(r'(.*?\\.\\d{0,6})\\d*([+-].*)$', raw)
if m:
    raw = m.group(1) + m.group(2)
print(int(datetime.datetime.fromisoformat(raw).timestamp()))
" "$finished_iso" 2>/dev/null \
      || echo 0)
    if [ "$finished_epoch" -eq 0 ]; then
      echo "  skip $cid ($name): could not parse FinishedAt=$finished"
      continue
    fi
    age_hours=$(( (now_epoch - finished_epoch) / 3600 ))
  fi
  if [ "$age_hours" -lt "$AGE_HOURS" ]; then
    echo "  keep $cid ($name): ${age_hours}h old < ${AGE_HOURS}h"
    continue
  fi
  if [ "$APPLY" -eq 1 ]; then
    if docker rm -f "$cid" >/dev/null 2>&1; then
      echo "  removed $cid ($name) age=${age_hours}h"
      removed=$((removed + 1))
    else
      echo "  failed  $cid ($name)"
    fi
  else
    echo "  [dry-run] would remove $cid ($name) age=${age_hours}h"
    removed=$((removed + 1))
  fi
done < "$candidates_file"

echo "==> done $(mode_label): inspected=${inspected} removed=${removed}"
