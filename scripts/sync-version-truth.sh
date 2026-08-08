#!/usr/bin/env bash
# sync-version-truth.sh — make lib/sdk_version.ml and <project>.opam match
# the authoritative version in dune-project.
#
# Counterpart to scripts/release.sh:
#   release.sh               — assert the 3 version surfaces agree, optionally tag.
#   sync-version-truth.sh    — update sdk_version.ml + opam so they DO agree,
#                              using dune-project as the single source of truth.
#
# Scope (deliberately narrow):
#   - dune-project            : source of truth, read only.
#   - <project>.opam          : regenerated via `dune build <project>.opam`
#                               (dune owns this file; we never hand-edit it).
#   - lib/sdk_version.ml      : `let version = "..."` literal rewritten in place.
#   - CHANGELOG.md            : NOT touched. Release-bump needs human judgement
#                               about changelog content — out of scope.
#
# Usage:
#   scripts/sync-version-truth.sh              # dry-run (default), show drift
#   scripts/sync-version-truth.sh --apply      # actually rewrite files
#   scripts/sync-version-truth.sh --apply --quiet
#
# Exit codes:
#   0  already in sync / dry-run OK / apply OK
#   1  file read/write error, missing required surface (dune-project /
#      opam / sdk_version.ml), or internal 3-axis verification failed
#      after --apply. This script does NOT invoke scripts/release.sh;
#      the post-apply check is its own re-read of the three surfaces.
#   2  usage error
#
# Motivation: OAS has had the exact "dune-project bumped in isolation, but
# sdk_version.ml / opam left behind" failure more than once (e.g. the
# 0.119.1 → 0.119.2 transition that broke every PR's Version Consistency
# check until a manual fix-up commit). Make re-sync a one-shot command
# instead of a recurring chore.

set -euo pipefail

apply=false
quiet=false

usage() {
  sed -n '2,25p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
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

# ── Derive project name from dune-project (no hardcoding) ───
project_name="$(sed -n 's/^(name \([^)]*\)).*/\1/p' dune-project | head -n1)"
if [[ -z "$project_name" ]]; then
  echo "sync-version-truth: no (name ...) in dune-project" >&2
  exit 1
fi
opam_file="${project_name}.opam"
if [[ ! -f "$opam_file" ]]; then
  echo "sync-version-truth: ${opam_file} not found (project_name=${project_name})" >&2
  exit 1
fi

# ── Source of truth: dune-project ────────────────────────────
dune_version="$(sed -n 's/^(version \([^)]*\)).*/\1/p' dune-project | head -n1)"
if [[ -z "$dune_version" ]]; then
  echo "sync-version-truth: no version in dune-project" >&2
  exit 1
fi

# ── Targets ──────────────────────────────────────────────────
opam_version="$(sed -n 's/^version: "\([^"]*\)".*/\1/p' "$opam_file" | head -n1)"
sdk_version="$(sed -n 's/^let version = "\([^"]*\)".*/\1/p' lib/sdk_version.ml | head -n1)"

info() {
  $quiet && return 0
  printf '%s\n' "$*"
}

drift=0
opam_drift=false
sdk_drift=false

if [[ "$opam_version" != "$dune_version" ]]; then
  info "opam drift: ${opam_file}=${opam_version} → ${dune_version} (will regenerate via dune)"
  opam_drift=true
  drift=$((drift + 1))
fi

if [[ "$sdk_version" != "$dune_version" ]]; then
  info "sdk_version.ml drift: let version=\"${sdk_version}\" → \"${dune_version}\""
  sdk_drift=true
  drift=$((drift + 1))
fi

if ((drift == 0)); then
  info "Version truth already in sync: dune=${dune_version} opam=${opam_version} sdk=${sdk_version}"
  exit 0
fi

if ! $apply; then
  info ""
  info "DRY RUN (${drift} drift)."
  info "Rerun with --apply to write changes."
  exit 0
fi

if $opam_drift; then
  info "running: scripts/dune-local.sh build ${opam_file}"
  # stderr intentionally NOT redirected: when dune fails (lock contention,
  # missing deps, syntax error in dune-project), the operator needs the
  # real diagnostic to troubleshoot, not a generic "failed" message.
  if ! scripts/dune-local.sh build "$opam_file"; then
    echo "sync-version-truth: 'scripts/dune-local.sh build ${opam_file}' failed" >&2
    exit 1
  fi
fi

if $sdk_drift; then
  # Rewrite only the exact `let version = "..."` line. Anchored match
  # protects every other "version" occurrence in the file from accidental edit.
  tmp="$(mktemp)"
  sed "s|^let version = \"[^\"]*\"|let version = \"${dune_version}\"|" \
    lib/sdk_version.ml > "$tmp"
  mv "$tmp" lib/sdk_version.ml
  info "updated: lib/sdk_version.ml let version = \"${dune_version}\""
fi

# ── Re-read surfaces and verify equality (3-axis) ──────────
# Intentionally re-do our own check rather than delegating to
# scripts/release.sh, whose dry-run is stricter (asserts the git tag
# does NOT already exist) — that invariant is irrelevant post-bump and
# would always fail here once the version has been tagged once.
final_opam="$(sed -n 's/^version: "\([^"]*\)".*/\1/p' "$opam_file" | head -n1)"
final_sdk="$(sed -n 's/^let version = "\([^"]*\)".*/\1/p' lib/sdk_version.ml | head -n1)"
if [[ "$final_opam" != "$dune_version" || "$final_sdk" != "$dune_version" ]]; then
  echo "sync-version-truth: verification failed after apply" >&2
  echo "  dune=${dune_version} opam=${final_opam} sdk=${final_sdk}" >&2
  exit 1
fi

info "Version truth synced: dune=${dune_version}"
