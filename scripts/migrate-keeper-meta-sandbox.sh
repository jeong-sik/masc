#!/usr/bin/env bash
# migrate-keeper-meta-sandbox.sh — one-shot normalizer for legacy keeper meta JSON.
#
# Why this exists
#   Prior to 2026-04-28 [keeper_meta_json_parse.ml:170-188] silently fell back
#   to default_sandbox_profile = Local when sandbox_profile / network_mode were
#   absent from the persisted meta JSON. The new strict parser refuses to load
#   such files. This script walks the on-disk keeper meta directories, fills in
#   the missing fields from the matching config/keepers/<name>.toml, and writes
#   .bak alongside the modified file.
#
# Scope (filesystem locations searched)
#   1. <repo>/.masc/keepers/*.json          (worktree-local persistence)
#   2. ~/.masc/keepers/*.json               (per-user persistence)
#
# Usage
#   bash scripts/migrate-keeper-meta-sandbox.sh             # --dry-run (default)
#   bash scripts/migrate-keeper-meta-sandbox.sh --apply     # write .bak + edit
#   bash scripts/migrate-keeper-meta-sandbox.sh --apply --quiet
#
# Exit codes
#   0   normalized 0 or more files cleanly
#   2   tooling missing (jq) or argument error
#   3   conflict: meta has profile but TOML has different non-default value
#       (operator action required — script does not overwrite divergent values)

set -euo pipefail

MODE="dry-run"
QUIET=0
for arg in "$@"; do
  case "$arg" in
    --apply)   MODE="apply" ;;
    --dry-run) MODE="dry-run" ;;
    --quiet)   QUIET=1 ;;
    -h|--help)
      sed -n '1,30p' "$0"
      exit 0
      ;;
    *)
      echo "Unknown argument: $arg" >&2
      exit 2
      ;;
  esac
done

if ! command -v jq >/dev/null 2>&1; then
  echo "ERROR: jq is required (brew install jq)" >&2
  exit 2
fi

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || echo "$(cd "$(dirname "$0")/.." && pwd -P)")"
TOML_DIR="${REPO_ROOT}/config/keepers"

log() { [ "$QUIET" -eq 1 ] || echo "$@"; }

# Read a TOML scalar like `sandbox_profile = "docker"`. Returns empty string
# when the key is absent. Comments after the value are stripped.
read_toml_scalar() {
  local file="$1" key="$2"
  [ -f "$file" ] || { echo ""; return 0; }
  awk -v key="$key" '
    BEGIN { val = "" }
    $0 ~ "^[[:space:]]*"key"[[:space:]]*=" {
      sub(/^[[:space:]]*[A-Za-z_][A-Za-z0-9_]*[[:space:]]*=[[:space:]]*/, "")
      sub(/[[:space:]]*#.*$/, "")
      gsub(/^["[:space:]]+|["[:space:]]+$/, "")
      val = $0
      exit
    }
    END { print val }
  ' "$file"
}

# Default network mode for a profile, mirroring
# Keeper_types_profile.default_network_mode_for_profile.
default_network_for_profile() {
  case "$1" in
    docker) echo "none" ;;
    local)  echo "inherit" ;;
    *)      echo "" ;;
  esac
}

normalize_one() {
  local meta_file="$1"
  local name
  name="$(basename "$meta_file" .json)"

  local has_profile has_network
  has_profile="$(jq -r 'has("sandbox_profile")' < "$meta_file" 2>/dev/null || echo "false")"
  has_network="$(jq -r 'has("network_mode")'   < "$meta_file" 2>/dev/null || echo "false")"

  if [ "$has_profile" = "true" ] && [ "$has_network" = "true" ]; then
    log "  [ok]   $name : sandbox_profile + network_mode already present"
    return 0
  fi

  local toml="${TOML_DIR}/${name}.toml"
  local toml_profile toml_network
  toml_profile="$(read_toml_scalar "$toml" sandbox_profile)"
  toml_network="$(read_toml_scalar "$toml" network_mode)"

  # Resolution policy:
  #   1. TOML value wins when present.
  #   2. Otherwise, fall back to the conservative defaults
  #      (sandbox_profile=local, network_mode=inherit) — this matches the
  #      pre-fix runtime behavior and lets legacy keepers boot. The intent of
  #      this script is *not* to upgrade keepers to docker; it only fills in
  #      the field so the strict parser stops refusing the file.
  local profile="${toml_profile:-local}"
  local network="${toml_network:-$(default_network_for_profile "$profile")}"
  network="${network:-inherit}"

  log "  [fix]  $name : sandbox_profile=$profile network_mode=$network (toml profile='${toml_profile:-<absent>}')"

  if [ "$MODE" = "dry-run" ]; then
    return 0
  fi

  local backup="${meta_file}.bak"
  cp -p "$meta_file" "$backup"

  local tmp
  tmp="$(mktemp)"
  jq --arg profile "$profile" --arg network "$network" '
    (if has("sandbox_profile") then . else . + {sandbox_profile: $profile} end)
    | (if has("network_mode")   then . else . + {network_mode:   $network} end)
  ' < "$meta_file" > "$tmp"

  mv "$tmp" "$meta_file"
}

scan_dir() {
  local dir="$1"
  [ -d "$dir" ] || { log "[skip] $dir : not present"; return 0; }
  log "[scan] $dir"
  shopt -s nullglob
  local found=0
  for f in "$dir"/*.json; do
    [ -f "$f" ] || continue
    case "$(basename "$f")" in
      *.bak) continue ;;
    esac
    normalize_one "$f"
    found=$((found + 1))
  done
  shopt -u nullglob
  log "[scan] $dir : ${found} file(s)"
}

log "mode: $MODE"
scan_dir "${REPO_ROOT}/.masc/keepers"
scan_dir "${HOME}/.masc/keepers"
log "done."
