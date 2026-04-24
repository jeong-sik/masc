#!/usr/bin/env bash
# sync-version-truth.sh — make masc_mcp.opam and ROADMAP.md match
# the authoritative version in dune-project.
#
# Counterpart to scripts/check-version-truth.sh:
#   check-version-truth.sh  — assert the 4 version surfaces agree.
#   sync-version-truth.sh   — update opam + ROADMAP package line so they agree
#                             with dune-project. CHANGELOG.md and ROADMAP
#                             "Latest release" are NOT touched; those are part
#                             of an explicit release action and left to a human
#                             who has decided to cut a release.
#
# Usage:
#   scripts/sync-version-truth.sh              # dry-run (default) — show diff preview
#   scripts/sync-version-truth.sh --apply      # actually rewrite files
#   scripts/sync-version-truth.sh --apply --quiet  # suppress diff preview
#
# Exit codes:
#   0  — files already in sync OR dry-run completed OR apply succeeded
#   1  — file read/write error, or check-version-truth.sh still fails after apply
#   2  — usage error

set -euo pipefail

apply=false
quiet=false

usage() {
  sed -n '2,17p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

while (($# > 0)); do
  case "$1" in
    --apply) apply=true ;;
    --quiet) quiet=true ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
  esac
  shift
done

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

# ── Source of truth: dune-project ────────────────────────────
dune_version="$(sed -n 's/^(version \([^)]*\)).*/\1/p' dune-project | head -n1)"
if [[ -z "$dune_version" ]]; then
  echo "sync-version-truth: no version found in dune-project" >&2
  exit 1
fi

# ── Targets ──────────────────────────────────────────────────
opam_version="$(sed -n 's/^version: "\([^"]*\)"/\1/p' masc_mcp.opam | head -n1)"
roadmap_version="$(sed -n 's/^> Current package version: v\([^ ]*\).*/\1/p' ROADMAP.md | head -n1)"

info() {
  $quiet && return 0
  printf '%s\n' "$*"
}

# ── Compute drift ───────────────────────────────────────────
drift=0
opam_drift=false
roadmap_drift=false

if [[ "$opam_version" != "$dune_version" ]]; then
  info "opam drift: masc_mcp.opam=$opam_version → $dune_version (will regenerate via dune)"
  opam_drift=true
  drift=$((drift + 1))
fi

if [[ "$roadmap_version" != "$dune_version" ]]; then
  info "ROADMAP drift: Current package version=v$roadmap_version → v$dune_version"
  roadmap_drift=true
  drift=$((drift + 1))
fi

if ((drift == 0)); then
  info "Version truth already in sync: dune=$dune_version opam=$opam_version ROADMAP=v$roadmap_version"
  exit 0
fi

# ── Preview / apply ─────────────────────────────────────────
if ! $apply; then
  info ""
  info "DRY RUN (${drift} drift${drift/#1/})."
  info "Rerun with --apply to write changes."
  exit 0
fi

if $opam_drift; then
  # dune regenerates masc_mcp.opam from dune-project when the (generate_opam_files true)
  # stanza is present. We don't hand-edit the file — that's what the "generated"
  # header tells every tool to expect.
  info "running: scripts/dune-local.sh build masc_mcp.opam"
  if ! scripts/dune-local.sh build masc_mcp.opam 2>/dev/null; then
    echo "sync-version-truth: 'scripts/dune-local.sh build masc_mcp.opam' failed" >&2
    exit 1
  fi
fi

if $roadmap_drift; then
  # Use a single sed that matches the full prefix so other "v<N>" patterns
  # elsewhere in ROADMAP.md are left alone.
  tmp="$(mktemp)"
  sed "s|^> Current package version: v[0-9][0-9.]*\(.*\)|> Current package version: v${dune_version}\1|" \
    ROADMAP.md > "$tmp"
  mv "$tmp" ROADMAP.md
  info "updated: ROADMAP.md 'Current package version: v${dune_version}'"
fi

# ── Verify via peer script ──────────────────────────────────
if ! bash scripts/check-version-truth.sh >/dev/null 2>&1; then
  echo "sync-version-truth: check-version-truth.sh still failing after apply" >&2
  bash scripts/check-version-truth.sh || true
  exit 1
fi

info "Version truth synced: dune=$dune_version"
