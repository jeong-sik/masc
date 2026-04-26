#!/usr/bin/env bash
# CI gate: every Eio actor consumer fiber must be wired up at boot.
#
# Background
#   Jane Street refactor wave (#10664 Session, #10730 Tool_registry +
#   Oas_worker_cascade) introduced multiple actor-pattern modules.
#   Each defines a consumer fiber starter — typically named
#   [start_loop] or [start_actor_if_needed] — but several were
#   defined and never called from a bootstrap path.
#
#   Without the consumer running, every helper that does
#   [Eio.Stream.add msg; Eio.Promise.await reply] blocks forever.
#   Visible production fires:
#     - #10777: Session.start_loop never called → restore_sessions
#       hung the entire keeper autoboot for ~3 minutes per restart
#       cycle until watchdog killed the server.
#     - #10895: Oas_worker_cascade.start_actor_if_needed never
#       called → cascade_metrics_json hangs the dashboard tool
#       inspector silently.
#
# Contract
#   For each module that defines a top-level consumer-starter (matched
#   by name pattern: [start_loop] or [start_actor*]), there must be at
#   least one CALLER outside the defining file itself. Self-calls
#   (the module calling its own starter from the same .ml) are
#   common for internal helpers and don't prove external bootstrap.
#
# Heuristic
#   1. Grep [^let start_(loop|actor)] in lib/ — collect (module, fn).
#   2. For each match, grep [Module.fn] in lib/ + bin/ EXCLUDING the
#      defining file. If zero hits, the consumer is unwired.
#
# Known false positives
#   - Internal-only helpers re-using the [start_loop]/[start_actor]
#     name. If a module legitimately exposes a starter for tests or
#     dependency-injection callers that live in [test/], extend the
#     search to test/ — but a starter that is *only* called from a
#     test is still a production-runtime hang risk in the dev server.
#
# Output
#   Exit 0 — every starter has at least one external caller in lib/ + bin/.
#   Exit 1 — at least one starter is unwired; emit (file, fn) pairs.

set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

failed=0
checked=0

# Find each top-level "let start_loop ..." or "let start_actor*" in lib/.
# The grep is anchored to column 0 to skip nested helpers.
hits=$(rg -n '^let start_(loop|actor)' lib/ 2>/dev/null || true)

if [ -z "$hits" ]; then
  echo "check-actor-consumer-wired: no actor consumer starters found"
  exit 0
fi

while IFS= read -r hit; do
  file=$(printf '%s\n' "$hit" | cut -d: -f1)
  body=$(printf '%s\n' "$hit" | cut -d: -f3-)

  # Extract the function name (token after "let ").
  fn=$(printf '%s\n' "$body" | sed -E 's/^let ([a-zA-Z_0-9]+).*/\1/')
  [ -z "$fn" ] && continue

  # Module name = capitalised basename without extension.
  base=$(basename "$file" .ml)
  mod=$(printf '%s' "$base" | awk '{ printf "%s%s", toupper(substr($1,1,1)), substr($1,2) }')

  checked=$((checked + 1))

  # Search for [Mod.fn] anywhere in lib/ + bin/ EXCLUDING the defining file.
  # A bare [fn] match would catch internal calls — we want to verify an
  # external bootstrap path imports the module and invokes it.
  callers=$(rg -l "${mod}\.${fn}\b" lib/ bin/ 2>/dev/null | grep -v "^${file}$" || true)

  if [ -z "$callers" ]; then
    echo "  FAIL  ${file}: ${mod}.${fn} defined but no external caller in lib/ or bin/"
    echo "        actor consumer unwired → Promise.await on this stream will hang"
    failed=1
  fi
done <<< "$hits"

if [ "$failed" -ne 0 ]; then
  echo ""
  echo "check-actor-consumer-wired: at least one actor consumer is unwired."
  echo "Reference: #10777 (Session.start_loop) and #10895 (Oas_worker_cascade)"
  echo "called the missing starter from lib/mcp_server.ml:create_state_eio."
  exit 1
fi

echo "check-actor-consumer-wired: ok (${checked} starter(s) verified)"
