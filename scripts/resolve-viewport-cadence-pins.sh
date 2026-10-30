#!/usr/bin/env bash
# Resolve both inputs before changing trees, and retain the exact source heads.
set -euo pipefail

: "${GITHUB_ENV:?GITHUB_ENV must name the workflow environment file}"
: "${RUNNER_TEMP:?RUNNER_TEMP must name the artifact staging directory}"

resolve_commit() {
  local requested="$1" resolved
  if resolved="$(git rev-parse --verify --quiet --end-of-options "${requested}^{commit}")"; then
    printf '%s\n' "$resolved"
  elif resolved="$(git rev-parse --verify --quiet --end-of-options "refs/remotes/origin/${requested}^{commit}")"; then
    printf '%s\n' "$resolved"
  else
    printf 'Cannot resolve input to a commit: %s\n' "$requested" >&2
    return 1
  fi
}

before_sha="$(resolve_commit "${BEFORE_SHA:-eb39c50f3379^}")"
after_sha="$(resolve_commit "${AFTER_REF:-eb39c50f3379}")"
git checkout --quiet --detach "$after_sha"
printf 'BEFORE_SHA=%s\nAFTER_SHA=%s\n' "$before_sha" "$after_sha" >> "$GITHUB_ENV"
printf 'before_sha=%s\nafter_sha=%s\n' "$before_sha" "$after_sha" > "$RUNNER_TEMP/source-heads.txt"
printf 'before=%s after=%s\n' "$before_sha" "$after_sha"
