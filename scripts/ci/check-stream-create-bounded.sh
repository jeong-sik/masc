#!/usr/bin/env bash
# CI gate: every Eio.Stream.create N must have N > 0 and N != max_int.
#
# Background
#   The actor pattern in masc-mcp uses Eio.Stream.t as message mailboxes
#   between producers and a single consumer fiber. An unbounded mailbox
#   (Eio.Stream.create max_int) masks back-pressure: when the consumer
#   slows or stalls, producers enqueue without limit and exhaust the
#   heap. A zero-capacity mailbox (Eio.Stream.create 0) gives synchronous
#   rendez-vous semantics that are almost never what an actor wants —
#   the producer blocks until the consumer takes, which defeats the
#   whole point of decoupling.
#
#   Production fires this rule prevents:
#     - #10777: Session.start_loop never called → restore_sessions
#       enqueued forever into the unbounded registry mailbox, OOM
#       blocked the keeper autoboot.
#     - #11022: bounded Session.{registry, mcp_session_store} mailboxes
#       (10_000 each, see lib/session.ml). Without this lint, a future
#       refactor could revert to max_int unnoticed.
#
# Contract
#   Every Eio.Stream.create N in lib/ that is real OCaml code (not a
#   comment) must have N as a positive literal or a named constant.
#   N = 0, max_int, or Int.max_int is a hard fail.
#
# Heuristic
#   1. Grep all `Eio.Stream.create` calls in lib/ (excluding test/).
#   2. Filter out lines inside comment blocks (line starts with `*`
#      after whitespace, or contains `(**` / `(*` opener before the
#      match, or contains `*)` closer after the match).
#   3. For each remaining line, check the argument: max_int, 0,
#      Int.max_int → FAIL. Anything else → OK (named constants and
#      arbitrary positive literals are trusted; reviewers verify the
#      bound is appropriate at PR time).
#
# Allowlist
#   Add a same-line trailing comment `(* stream-bounded-allow:<reason> *)`
#   to opt out a specific line — e.g. for an integration test fixture
#   that intentionally needs an unbounded queue. Production code SHOULD
#   NOT use this escape hatch.

set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

# Real call-site shape: a binding context must precede the call.
# Inventory of all 10 production call sites in lib/ as of 2026-04-27 shows
# every real call has `=` immediately before `Eio.Stream.create` (let
# binding, record field, or assignment). Doc-comment occurrences of the
# literal lack this binding context — using the binding context as the
# filter cleanly excludes comments without a fragile multi-line state
# machine.
CALL_RE='=\s*Eio\.Stream\.create\s+\S+'

# Patterns considered unbounded / synchronous (the bad set).
BAD_RE='=\s*Eio\.Stream\.create\s+(max_int|0|Int\.max_int)\b'

exit_code=0
checked=0
flagged=0

while IFS= read -r hit; do
  # rg -n output: file:lineno:content
  file=$(printf '%s' "$hit" | cut -d: -f1)
  lineno=$(printf '%s' "$hit" | cut -d: -f2)
  content=$(printf '%s' "$hit" | cut -d: -f3-)

  # Same-line allowlist escape hatch.
  if printf '%s' "$content" | grep -q 'stream-bounded-allow'; then
    continue
  fi

  # Skip lines lacking a binding context — those are doc-comment occurrences
  # of the literal, not real call sites (see CALL_RE comment above).
  if ! printf '%s' "$content" | grep -qE "$CALL_RE"; then
    continue
  fi

  checked=$((checked + 1))

  if printf '%s' "$content" | grep -qE "$BAD_RE"; then
    flagged=$((flagged + 1))
    if [ "$flagged" -eq 1 ]; then
      echo "FAIL  Eio.Stream.create with unbounded / zero capacity:"
    fi
    echo "  ${file}:${lineno}: ${content}"
    exit_code=1
  fi
done < <(rg -n 'Eio\.Stream\.create' lib/ --type ml -g '!test/' 2>/dev/null || true)

if [ "$exit_code" -eq 0 ]; then
  echo "check-stream-create-bounded: ok (${checked} call site(s) verified)"
else
  echo
  echo "check-stream-create-bounded: ${flagged} unbounded / zero-capacity site(s)."
  echo "Reference: docs/spec/18-log-severity-taxonomy.md (related actor-pattern guidance)"
  echo "Fix: replace max_int / 0 with a named constant sized to expected"
  echo "     producer burst (see lib/session.ml max_registry_mailbox for example)."
  echo "     For an intentional exception, add (* stream-bounded-allow:<reason> *)"
  echo "     on the same line."
fi

exit "$exit_code"
