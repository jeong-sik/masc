#!/usr/bin/env bash
# A workflow must name a stable Ubuntu runner image. Scan active YAML text,
# including matrix values that reach runs-on indirectly; ignore comments.
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"
shopt -s nullglob
files=(.github/workflows/*.yml .github/workflows/*.yaml)
shopt -u nullglob

if (( ${#files[@]} == 0 )); then
  echo "no-ubuntu-latest-runner: no workflow files found" >&2
  exit 1
fi

hits="$(awk '{
  line = $0
  sub(/#.*/, "", line)
  if (line ~ /ubuntu-latest/) {
    printf "%s:%d:%s\n", FILENAME, FNR, line
  }
}' "${files[@]}")"

if [[ -n "$hits" ]]; then
  printf 'no-ubuntu-latest-runner: pin Ubuntu runners to an explicit version:\n%s\n' "$hits" >&2
  exit 1
fi

printf 'no-ubuntu-latest-runner: %d workflow files checked\n' "${#files[@]}"
