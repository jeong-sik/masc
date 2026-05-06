#!/usr/bin/env bash
set -euo pipefail

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
coverage_dir="${COVERAGE_DIR:-$root_dir/_coverage}"
reuse_existing=false

require_bisect_reporter() {
  if ! command -v opam >/dev/null 2>&1; then
    echo "opam is required to run coverage_percent.sh" >&2
    exit 127
  fi
  if ! opam exec -- bash -lc 'command -v bisect-ppx-report >/dev/null 2>&1'; then
    cat >&2 <<'EOF'
bisect-ppx-report is not installed in the active opam switch.

Install/pin the repo test dependencies with bisect support before measuring:
  scripts/opam-pin-external-deps.sh --with-bisect
  opam install . --deps-only --with-test

CI does this through the setup/pin dependency actions with --with-bisect.
EOF
    exit 127
  fi
}

for arg in "$@"; do
  case "$arg" in
    --reuse-existing)
      reuse_existing=true
      ;;
    *)
      echo "unknown argument: $arg" >&2
      exit 2
      ;;
  esac
done

require_bisect_reporter

if ! $reuse_existing; then
  rm -rf "$coverage_dir"
  mkdir -p "$coverage_dir"
  (
    cd "$root_dir"
    CI_TEST_TIMEOUT_SEC=1200 CI_TEST_HEARTBEAT_SEC=30 \
      ./scripts/ci-run-tests.sh \
      "BISECT_FILE='$coverage_dir/bisect' ./scripts/dune-local.sh test --instrument-with bisect_ppx --force"
  )
fi

summary="$(
  opam exec -- bash -lc "cd '$root_dir' && bisect-ppx-report summary --coverage-path '$coverage_dir'"
)"
percent="$(
  printf '%s\n' "$summary" \
    | sed -nE 's/^Coverage: [0-9]+\/[0-9]+ \(([0-9]+(\.[0-9]+)?)%\)$/\1/p'
)"

if [ -z "$percent" ]; then
  echo "failed to parse bisect summary" >&2
  printf '%s\n' "$summary" >&2
  exit 1
fi

printf '%s\n' "$percent"
