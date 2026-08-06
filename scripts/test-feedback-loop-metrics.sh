#!/usr/bin/env bash
# Fixture test for scripts/feedback-loop.sh Measure step (task-190).
#
# Verifies that the "3. Measure" step collects real per-iteration metrics into
# the JSONL LOG_FILE instead of being a no-op:
#   - build_duration_ms is a positive integer
#   - build_mem_kb is a positive integer (from /usr/bin/time peak RSS)
#   - bin_size_bytes matches the mock build artifact size
#   - shell_peak_rss_kb is a positive integer
#   - the summary (jq) aggregates the new metric fields
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
FEEDBACK_LOOP="$REPO_ROOT/scripts/feedback-loop.sh"

fixture="$(mktemp -d "${TMPDIR:-/tmp}/feedback-loop-metrics.XXXXXX")"
trap 'rm -rf "$fixture"' EXIT

# Build a minimal fake repo layout: scripts/dune-local.sh (mock build) and a
# mock build artifact at _build/default/bin/main_eio.exe.
mkdir -p "$fixture/scripts" "$fixture/_build/default/bin" "$fixture/logs"

cat >"$fixture/scripts/dune-local.sh" <<'MOCK'
#!/usr/bin/env bash
# Mock dune-local.sh: succeed immediately so the loop reaches the Measure step.
exit 0
MOCK
chmod +x "$fixture/scripts/dune-local.sh"

# Deterministic mock artifact so bin_size_bytes is assertable.
printf 'mock-binary' >"$fixture/_build/default/bin/main_eio.exe"
# Platform-branch like the script under test: GNU stat treats "-f %z" as a
# file-system query that succeeds, so a macOS-first fallback chain silently
# yields the wrong number on Linux instead of falling back.
if [ "$(uname -s)" = "Darwin" ]; then
  expected_size="$(stat -f %z "$fixture/_build/default/bin/main_eio.exe")"
else
  expected_size="$(stat -c %s "$fixture/_build/default/bin/main_eio.exe")"
fi

cp "$FEEDBACK_LOOP" "$fixture/scripts/feedback-loop.sh"

# Run one iteration. The mock build is instant, so the loop completes quickly.
(
  cd "$fixture"
  ./scripts/feedback-loop.sh 1 >/dev/null 2>&1
)

log_file="$(find "$fixture/logs/feedback-loop/" -name '*.jsonl' -type f | head -1)"
if [[ -z "$log_file" ]]; then
  echo "FAIL: no JSONL log file produced" >&2
  exit 1
fi

row="$(head -1 "$log_file")"

failures=0
check() {
  local label="$1" got="$2"
  if [[ -z "$got" || "$got" == "null" ]]; then
    echo "FAIL: ${label} is missing/empty (got '${got}')" >&2
    failures=$((failures + 1))
  fi
}

check_num() {
  local label="$1" got="$2"
  if ! [[ "$got" =~ ^[0-9]+$ ]] || [[ "$got" -eq 0 ]]; then
    echo "FAIL: ${label} should be a positive integer (got '${got}')" >&2
    failures=$((failures + 1))
  fi
}

# Extract fields from the JSONL row.
build_duration="$(printf '%s' "$row" | jq -r '.build_duration_ms')"
build_mem="$(printf '%s' "$row" | jq -r '.build_mem_kb')"
bin_size="$(printf '%s' "$row" | jq -r '.bin_size_bytes')"
shell_rss="$(printf '%s' "$row" | jq -r '.shell_peak_rss_kb')"
phase="$(printf '%s' "$row" | jq -r '.phase')"

check "phase" "$phase"
[[ "$phase" == "complete" ]] || { echo "FAIL: phase should be complete (got '$phase')" >&2; failures=$((failures + 1)); }
check_num "build_duration_ms" "$build_duration"
check_num "build_mem_kb" "$build_mem"
check_num "shell_peak_rss_kb" "$shell_rss"

if [[ "$bin_size" != "$expected_size" ]]; then
  echo "FAIL: bin_size_bytes should be $expected_size (got '$bin_size')" >&2
  failures=$((failures + 1))
fi

# Summary must aggregate the new metric fields without error.
summary="$(cd "$fixture" && ./scripts/feedback-loop.sh 1 2>/dev/null | sed -n '/^{/,/^}/p' || true)"
if ! printf '%s' "$summary" | jq -e '.avg_build_duration_ms > 0' >/dev/null 2>&1; then
  echo "FAIL: summary should aggregate avg_build_duration_ms" >&2
  failures=$((failures + 1))
fi

if ((failures > 0)); then
  echo "feedback-loop metrics fixture: ${failures} failure(s)" >&2
  exit 1
fi
echo "feedback-loop metrics fixture: OK"
