#!/usr/bin/env bash
# seed-team.sh — copy a team preset (keepers + personas) into a live MASC config
# root so the named keepers autoboot on the next server start.
#
# Config seeding intentionally excludes keepers/ and personas/, so a fresh
# install boots zero keepers. This script is the explicit opt-in that seeds a
# team. It copies files from presets/<preset>/ (listed in that preset's
# manifest.txt) into <base-path>/.masc/config/. The keepers inherit
# [runtime].default from runtime.toml (ollama_cloud.deepseek-v4-flash), so no
# model catalog is touched — coherence with runtime.toml/oas-models.toml holds.
#
# Usage:
#   scripts/seed-team.sh [--preset classic] --base-path DIR [--force] [--dry-run] [--list]
#
# Flags:
#   --preset ID     Team preset under config/team-presets/ (default: classic)
#   --base-path DIR Live MASC base path; seeds into DIR/.masc/config (required)
#   --force         Overwrite existing keeper/persona files
#   --dry-run       Print what would happen, write nothing
#   --list          List available presets and exit

set -euo pipefail

c_grn=$(printf '\033[32m'); c_yel=$(printf '\033[33m'); c_red=$(printf '\033[31m')
c_dim=$(printf '\033[2m'); c_off=$(printf '\033[0m')
[ -t 1 ] || { c_grn=""; c_yel=""; c_red=""; c_dim=""; c_off=""; }
log()  { printf '%s==>%s %s\n' "$c_grn" "$c_off" "$*"; }
warn() { printf '%swarn:%s %s\n' "$c_yel" "$c_off" "$*" >&2; }
die()  { printf '%serror:%s %s\n' "$c_red" "$c_off" "$*" >&2; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# Presets are install-time seed assets, kept out of config/ so the server's
# config-root bootstrap never copies them into a live runtime config root.
# Override with MASC_PRESETS_ROOT (e.g. the image bakes them at /app/presets).
PRESETS_ROOT="${MASC_PRESETS_ROOT:-$REPO_ROOT/presets}"

PRESET="classic"
BASE_PATH=""
FORCE=0
DRY_RUN=0
LIST_ONLY=0

while [ $# -gt 0 ]; do
  case "$1" in
    --preset)    PRESET="${2:-}"; shift 2 ;;
    --base-path) BASE_PATH="${2:-}"; shift 2 ;;
    --force)     FORCE=1; shift ;;
    --dry-run)   DRY_RUN=1; shift ;;
    --list)      LIST_ONLY=1; shift ;;
    -h|--help)
      grep '^#' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
      exit 0 ;;
    *) die "unknown option: $1" ;;
  esac
done

list_presets() {
  [ -d "$PRESETS_ROOT" ] || die "no team presets directory: $PRESETS_ROOT"
  local d
  for d in "$PRESETS_ROOT"/*/; do
    [ -f "${d}manifest.txt" ] || continue
    printf '  %s\n' "$(basename "$d")"
  done
}

if [ "$LIST_ONLY" -eq 1 ]; then
  log "available team presets:"
  list_presets
  exit 0
fi

PRESET_DIR="$PRESETS_ROOT/$PRESET"
MANIFEST="$PRESET_DIR/manifest.txt"
[ -d "$PRESET_DIR" ] || die "unknown preset '$PRESET' (see: $0 --list)"
[ -f "$MANIFEST" ]   || die "preset '$PRESET' has no manifest.txt at $MANIFEST"
[ -n "$BASE_PATH" ]  || die "--base-path is required"

# Live config root matches Config_dir_resolver: <base-path>/.masc/config
CONFIG_DIR="$BASE_PATH/.masc/config"

log "seeding team preset '${c_grn}$PRESET${c_off}' into $CONFIG_DIR"

seeded=0
skipped=0
keeper_names=()

while IFS= read -r rel || [ -n "$rel" ]; do
  # Skip blank lines and comments.
  case "$rel" in ''|'#'*) continue ;; esac
  src="$PRESET_DIR/$rel"
  dest="$CONFIG_DIR/$rel"
  [ -f "$src" ] || die "manifest lists missing file: $rel (expected $src)"

  # Track bootable keepers for the summary (keepers/<name>.toml, excluding base).
  case "$rel" in
    keepers/*.toml)
      stem="$(basename "$rel" .toml)"
      [ "$stem" = "base" ] || keeper_names+=("$stem")
      ;;
  esac

  if [ -e "$dest" ] && [ "$FORCE" -eq 0 ]; then
    printf '  %sskip%s %s (exists; use --force to overwrite)\n' "$c_dim" "$c_off" "$rel"
    skipped=$((skipped + 1))
    continue
  fi

  if [ "$DRY_RUN" -eq 1 ]; then
    printf '  %s[dry-run]%s would write %s\n' "$c_yel" "$c_off" "$dest"
    seeded=$((seeded + 1))
    continue
  fi

  mkdir -p "$(dirname "$dest")"
  cp "$src" "$dest"
  printf '  %s+%s %s\n' "$c_grn" "$c_off" "$rel"
  seeded=$((seeded + 1))
done < "$MANIFEST"

echo
if [ "$DRY_RUN" -eq 1 ]; then
  log "[dry-run] would seed $seeded file(s), skip $skipped."
else
  log "seeded $seeded file(s), skipped $skipped."
fi

if [ "${#keeper_names[@]}" -gt 0 ]; then
  log "keepers that will autoboot on next start: ${keeper_names[*]}"
  printf '%s  model: ollama_cloud.deepseek-v4-flash (runtime.toml [runtime].default)%s\n' "$c_dim" "$c_off"
  printf '%s  requires: OLLAMA_CLOUD_API_KEY in the server environment%s\n' "$c_dim" "$c_off"
fi
