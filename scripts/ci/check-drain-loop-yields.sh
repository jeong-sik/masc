#!/usr/bin/env bash
# CI gate: every Eio fiber that drains a non-blocking primitive must
# yield between iterations.
#
# Background
#   PR #14491 introduced Keeper_telemetry_consumer.spawn_subscriber
#   with a drain loop that called the non-blocking
#   [Agent_sdk_metrics_bridge.drain] and recursed without
#   [Eio.Time.sleep] / [Eio.Fiber.yield]. On a quiet bus the fiber
#   pinned its Eio domain at ~100% CPU, starving every co-located
#   fiber on the same domain — including HTTP handlers and lazy
#   startup tasks. Server boot stalled at
#   "lazy_task: starting restore_sessions" while ports remained
#   LISTEN; /health timed out. PR #14499 restored the yield, RFC-0063
#   §6 codified the contract, PR #14508 added a test-harness probe
#   (RFC §7-D), this lint is RFC §7-B.
#
# Contract (RFC-0063 §6.1)
#   Every .ml file under lib/ that calls a non-blocking drain
#   primitive must also call a cooperative yield in the same file —
#   either an explicit yield or a blocking IO primitive that yields
#   by construction.
#
# Heuristic (file-level)
#   1. Find every .ml in lib/ that mentions a non-blocking drain.
#   2. For each, check it ALSO mentions a yield primitive.
#   3. File-level granularity is sufficient because all eleven known
#      drain-callers on origin/main keep the drain and the yield in
#      the same file (verified 2026-05-11). A future change that
#      splits them across files would itself be a structural smell.
#
# Known false negatives (acceptable)
#   - A file with two functions where one drains and the other
#     (unrelated) sleeps: the lint passes but the drain loop is
#     still starved. Mitigations:
#       * test/test_keeper_telemetry_consumer.ml (RFC-0063 §7-D)
#       * PR review checklist (RFC-0063 §7-A)
#       * AST-based lint (RFC-0063 §7 candidate follow-up)
#
# Known false positives (none currently)
#   - All eleven current drain-caller files match. New sites that
#     legitimately one-shot drain without looping (e.g. shutdown
#     drain) will pass as long as they touch any yield primitive in
#     the same file — which is almost always true.
#
# Output
#   Exit 0 — every drain-caller file has at least one yield.
#   Exit 1 — at least one drains without yielding; emit the file path.

set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

# Patterns that indicate a non-blocking drain. Recurses immediately on
# empty queue, so the loop body must yield before the next iteration.
DRAIN_RE='Agent_sdk_metrics_bridge\.drain|Agent_sdk\.Event_bus\.drain|Eio\.Stream\.take_nonblocking'

# Patterns that count as a cooperative yield. Narrow on purpose:
#   - Eio.Time.sleep        explicit timed wait
#   - Eio.Fiber.yield       explicit scheduling point
#   - Eio.Time.with_timeout wraps an inner blocking op with a deadline
#   - Eio.Stream.take       blocking take on an Eio stream (yields
#                            cooperatively when the stream is empty)
# The trailing [^_] on take excludes take_nonblocking, which is the
# very primitive we are guarding against.
YIELD_RE='Eio\.Time\.sleep|Eio\.Fiber\.yield|Eio\.Time\.with_timeout|Eio\.Stream\.take[^_]'

failed=0
checked=0
ok=0

drain_files=$(rg -l "${DRAIN_RE}" lib/ 2>/dev/null || true)

if [ -z "$drain_files" ]; then
  echo "check-drain-loop-yields: no non-blocking drains found in lib/"
  exit 0
fi

while IFS= read -r file; do
  [ -z "$file" ] && continue
  checked=$((checked + 1))

  if rg -q "${YIELD_RE}" "$file" 2>/dev/null; then
    ok=$((ok + 1))
  else
    echo "  FAIL  ${file}"
    echo "        drains a non-blocking primitive but no cooperative"
    echo "        yield call (Eio.Time.sleep / Eio.Fiber.yield /"
    echo "        Eio.Time.with_timeout / blocking Eio.Stream.take)"
    echo "        in the same file."
    echo "        Contract: RFC-0063 §6.1 — drain loops must yield"
    echo "        before recursing, otherwise they pin the Eio domain"
    echo "        and starve co-located fibers."
    failed=1
  fi
done <<< "$drain_files"

if [ "$failed" -ne 0 ]; then
  echo ""
  echo "check-drain-loop-yields: at least one drain caller lacks a yield."
  echo "Reference: PR #14491 (regression source) → PR #14499 (fix)"
  echo "           docs/rfc/RFC-0063-telemetry-feedback-loop.md §6"
  exit 1
fi

echo "check-drain-loop-yields: ok (${ok}/${checked} drain-caller file(s) verified)"
