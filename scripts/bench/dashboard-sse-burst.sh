#!/usr/bin/env bash
# dashboard-sse-burst.sh
#
# Phase 0 perf harness. Opens the dashboard against the local MASC server
# with instructions for three recorded Chrome Performance scenarios.
#
# Scenarios:
#   A) SSE burst   — high-frequency event ingest → journal + OAS buffer
#   B) search typing — telemetry page search input responsiveness
#   C) scroll       — session-trace 500+ entries scroll FPS
#
# The harness does NOT auto-record. It prints the manual steps and the
# exact metrics to capture. Output lands in .tmp/perf-<scenario>-<phase>.json.

set -euo pipefail

here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null && pwd)
repo_root=$(cd "$here/../.." && pwd)
phase=${1:-before}

if [[ "$phase" != "before" && "$phase" != "after" ]]; then
  echo "usage: $0 [before|after]"
  exit 64
fi

out_dir="$repo_root/.tmp"
mkdir -p "$out_dir"

server_up() {
  curl -fsS -m 2 http://127.0.0.1:8935/api/v1/dashboard/status >/dev/null 2>&1
}

if ! server_up; then
  echo "masc-mcp server is not responding on :8935."
  echo "start it in another shell, then re-run:"
  echo "  dune exec masc_mcp_server -- --foreground"
  exit 1
fi

cat <<EOF
Dashboard SSE burst harness — phase=$phase
Artifacts: $out_dir/perf-<scenario>-$phase.{json,md}

Step 1 — start the dev dashboard (separate shell):
  pnpm --filter masc-dashboard dev
  # opens http://127.0.0.1:5173/dashboard/

Step 2 — open Chrome DevTools → Performance tab. For each scenario:

Scenario A — SSE burst (journal + OAS buffer hot path)
  1. Disable throttling, enable CPU 4x slowdown.
  2. Start recording.
  3. Trigger heavy board activity OR leave keeper chatter running for 10s.
     (If no live load, post 200 synthetic board posts via:
       for i in \$(seq 1 200); do
         curl -s -X POST http://127.0.0.1:8935/api/v1/dashboard/board/posts \\
           -H 'content-type: application/json' \\
           -d '{"author":"perf-bench","kind":"note","body":"burst #'"\$i"'"}' >/dev/null
       done)
  4. Stop recording, export profile → $out_dir/perf-A-$phase.json

Scenario B — telemetry search typing
  1. Navigate to Telemetry panel, wait for 100+ entries loaded.
  2. Start recording.
  3. Type a query of 10 characters, pause 1s, clear, repeat twice.
  4. Stop recording → $out_dir/perf-B-$phase.json

Scenario C — session-trace scroll
  1. Open a session-trace with 500+ events.
  2. Start recording.
  3. Scroll top→bottom→top at ~1 page/s for 10s.
  4. Stop recording → $out_dir/perf-C-$phase.json

Step 3 — record the aggregate numbers in $out_dir/perf-baseline.md
(long-tasks count, INP, scripting %, JS heap peak).

Step 4 — for the 'after' run, compare side-by-side and paste the diff
into the PR description.
EOF
