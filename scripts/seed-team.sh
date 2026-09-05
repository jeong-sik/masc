#!/usr/bin/env bash
# seed-team.sh — copy a team preset into a live MASC config
# root so the named keepers autoboot on the next server start.
#
# Config seeding intentionally excludes keepers/, so a fresh
# install boots zero keepers. This script is the explicit opt-in that seeds a
# team. It copies files from presets/<preset>/ (listed in that preset's
# manifest.txt) into <base-path>/.masc/config/. The keepers name no model of
# their own: they inherit [runtime].default from that config root's
# runtime.toml, so no model catalog is touched — AGENT_CORE embedded catalog
# plus deployment overlay stays authoritative.
#
# Usage:
#   scripts/seed-team.sh [--preset classic] --base-path DIR [--force] [--dry-run] [--list]
#
# Flags:
#   --preset ID     Team preset under presets/ (default: classic)
#   --base-path DIR Live MASC base path; seeds into DIR/.masc/config (required)
#   --force         Overwrite existing Keeper files
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

  # Track bootable keepers for the summary. Every keepers/<name>.toml is a
  # keeper; no filename is reserved for shared defaults.
  case "$rel" in
    keepers/*.toml)
      keeper_names+=("$(basename "$rel" .toml)")
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
  # The seeded keepers name no model; the live config root's runtime.toml
  # does, under [runtime].default, and the operator owns that file. Read it
  # rather than restate it here: the repo default moved once already and
  # this line kept printing the old one.
  runtime_toml="$CONFIG_DIR/runtime.toml"
  default_runtime=""
  if [ -f "$runtime_toml" ]; then
    default_runtime="$(awk -F'"' '/^\[/ { in_runtime = ($0 == "[runtime]") } in_runtime && /^default[[:space:]]*=/ { print $2; exit }' "$runtime_toml")"
  fi
  if [ -n "$default_runtime" ]; then
    printf '%s  model: %s ([runtime].default in %s)%s\n' "$c_dim" "$default_runtime" "$runtime_toml" "$c_off"
  else
    warn "no [runtime].default in $runtime_toml; the keepers have no model until it names one"
  fi
fi
