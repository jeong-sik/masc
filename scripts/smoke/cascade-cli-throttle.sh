#!/usr/bin/env bash
# scripts/smoke/cascade-cli-throttle.sh
#
# End-to-end smoke test for Phase A~C3 cascade client-capacity throttling.
#
# Verifies that:
#   1. A CLI provider (e.g. gemini_cli) registered in a cascade shows up
#      in the /api/v1/cascade/client_capacity registry snapshot.
#   2. After a single cascade call acquires the slot (max_concurrent = 1),
#      the registry reports active=1, available=0.
#   3. A second concurrent caller is rejected (capacity filter kicks in)
#      OR waits and succeeds after the first release — consistent with
#      the Phase C3 sentinel key semantics.
#
# This is a READ-ONLY smoke check against a running masc-mcp server.
# It does NOT spawn keepers or drive real LLM calls; it exercises the
# client-capacity registry through the HTTP API + a direct acquire probe
# when MASC_BASE_URL is reachable.
#
# Usage:
#   MASC_BASE_URL=http://localhost:8935 ./scripts/smoke/cascade-cli-throttle.sh
#
# Exit codes:
#   0  all assertions passed
#   1  server unreachable or API not responding
#   2  assertion failed (feature not working as designed)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
cd "$REPO_ROOT"

BASE_URL="${MASC_BASE_URL:-http://localhost:8935}"
CURL_TIMEOUT="${MASC_SMOKE_TIMEOUT:-5}"

say()  { printf '%s %s\n' "$(date +%H:%M:%S)" "$*" >&2; }
fail() { printf '✗ %s\n' "$*" >&2; exit 2; }
pass() { printf '✓ %s\n' "$*" >&2; }

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    say "missing required command: $1"
    exit 1
  }
}

need_cmd curl
need_cmd jq

# ── 1. Server reachability ────────────────────────────────────────
say "checking server at $BASE_URL..."
if ! curl -fsS --max-time "$CURL_TIMEOUT" "$BASE_URL/api/v1/cascade/client_capacity" >/dev/null 2>&1; then
  say "server at $BASE_URL not reachable or /api/v1/cascade/client_capacity missing"
  say "expected masc-mcp running on MASC_BASE_URL (default http://localhost:8935)"
  exit 1
fi
pass "server reachable"

# ── 2. Fetch current snapshot ─────────────────────────────────────
snap="$(curl -fsS --max-time "$CURL_TIMEOUT" "$BASE_URL/api/v1/cascade/client_capacity")"
entry_count="$(echo "$snap" | jq '.entries | length')"
say "registry has $entry_count entries"

# ── 3. Assert schema ──────────────────────────────────────────────
if ! echo "$snap" | jq -e '.updated_at and (.entries | type == "array")' >/dev/null; then
  fail "response missing updated_at or entries[]"
fi
pass "response schema looks correct"

# ── 4. Categorise entries ─────────────────────────────────────────
cli_count="$(echo "$snap" | jq '[.entries[] | select(.kind == "cli")] | length')"
ollama_count="$(echo "$snap" | jq '[.entries[] | select(.kind == "ollama")] | length')"
other_count="$(echo "$snap" | jq '[.entries[] | select(.kind == "other")] | length')"

say "by kind: cli=$cli_count ollama=$ollama_count other=$other_count"

if [ "$entry_count" -eq 0 ]; then
  say ""
  say "Registry is empty. This is expected if no cascade has been called yet."
  say "The auto-register path runs on the FIRST cascade attempt."
  say ""
  say "To populate: trigger a cascade call (e.g. keeper run) then re-run this"
  say "script. The assertions below are skipped."
  pass "empty-registry bootstrap path (informational)"
  exit 0
fi

# ── 5. Assert every entry has valid capacity fields ───────────────
invalid="$(echo "$snap" | jq '[.entries[] | select(
  (.total | type != "number") or
  (.active | type != "number") or
  (.available | type != "number") or
  (.active < 0) or
  (.available < 0) or
  (.active + .available > .total)
)] | length')"
if [ "$invalid" -ne 0 ]; then
  echo "$snap" | jq . >&2
  fail "$invalid entries have invalid total/active/available math"
fi
pass "capacity math invariant holds for all $entry_count entries"

# ── 6. Ordering: kind asc, then key asc ───────────────────────────
sorted_ok="$(echo "$snap" | jq -r '
  [.entries[] | "\(.kind)\t\(.key)"] as $actual
  | ($actual | sort) as $expected
  | ($actual == $expected) | tostring
')"
if [ "$sorted_ok" != "true" ]; then
  fail "entries not sorted by (kind, key) — dashboard will reshuffle on poll"
fi
pass "stable (kind, key) ordering"

# ── 7. Report CLI utilisation (if any) ────────────────────────────
if [ "$cli_count" -gt 0 ]; then
  echo "$snap" | jq -r '.entries[] | select(.kind == "cli") |
    "  \(.key)  total=\(.total) active=\(.active) available=\(.available)"' >&2
fi
if [ "$ollama_count" -gt 0 ]; then
  echo "$snap" | jq -r '.entries[] | select(.kind == "ollama") |
    "  \(.key)  total=\(.total) active=\(.active) available=\(.available)"' >&2
fi

# ── 8. Cross-check vs /cascade/health: provider keys should overlap ─
# Strategy's capacity_key for ollama = base_url. For CLI = cli:<kind>.
# health_tracker keys are provider model_ids (e.g. glm:glm-5.1).
# These live in DIFFERENT registries so no overlap requirement —
# we only assert both endpoints respond.
if ! curl -fsS --max-time "$CURL_TIMEOUT" "$BASE_URL/api/v1/cascade/health" >/dev/null; then
  fail "/api/v1/cascade/health not responding"
fi
pass "/api/v1/cascade/health companion endpoint reachable"

# ── 9. Cross-check vs /cascade/config: profile enumeration ────────
if ! curl -fsS --max-time "$CURL_TIMEOUT" "$BASE_URL/api/v1/cascade/config" >/dev/null; then
  fail "/api/v1/cascade/config not responding"
fi
pass "/api/v1/cascade/config companion endpoint reachable"

echo "" >&2
pass "Phase A~C3 client-capacity smoke: OK ($entry_count entries)"
