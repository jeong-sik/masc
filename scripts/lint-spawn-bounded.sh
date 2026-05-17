#!/usr/bin/env bash
# RFC-0109 P1 — Spawn-bounded ratchet.
#
# Every `Eio.Process.spawn` site in lib/ must either:
#   (a) Be the canonical `Bounded_proc.run_argv_with_timeout` helper
#       itself.
#   (b) Live inside a function whose public callers wrap the spawn in
#       `Eio.Time.with_timeout_exn` + a fresh `Eio.Switch.run`.
#   (c) Carry a `(* SPAWN-UNBOUNDED-OK: <reason> *)` inline justification.
#
# This script enforces (a)/(b) via an explicit allowlist
# (scripts/lint-spawn-bounded.allowlist). New spawn sites added to the
# code without a corresponding allowlist entry fail CI. The allowlist
# is the audit record — every line in it has been read once and judged
# bounded.
#
# Exit 0 = baseline matches allowlist, no new spawns.
# Exit 1 = new spawn site(s) found OR a stale allowlist entry that no
#          longer points at a spawn line.
set -euo pipefail

REPO_ROOT="$(git -C "$(dirname "$0")/.." rev-parse --show-toplevel)"
ALLOWLIST="$REPO_ROOT/scripts/lint-spawn-bounded.allowlist"

if [ ! -f "$ALLOWLIST" ]; then
  echo "lint-spawn-bounded: allowlist missing: $ALLOWLIST" >&2
  exit 1
fi

# Strip comments + blanks from the allowlist to get the canonical entry set.
allowed=$(grep -vE '^\s*(#|$)' "$ALLOWLIST" | sort -u)

# Discover every current spawn site.
discovered=$(
  cd "$REPO_ROOT" && \
  rg -n --no-heading --type=ml 'Eio\.Process\.spawn' lib/ \
    | awk -F: '{print $1 ":" $2}' \
    | sort -u
)

# 1. New spawn sites not in allowlist.
new=$(comm -23 <(echo "$discovered") <(echo "$allowed") || true)
# 2. Stale allowlist entries that no longer match a spawn line.
stale=$(comm -13 <(echo "$discovered") <(echo "$allowed") || true)

status=0

if [ -n "$new" ]; then
  echo "lint-spawn-bounded: NEW spawn site(s) without allowlist entry:" >&2
  echo "$new" | sed 's/^/  /' >&2
  echo >&2
  echo "  Each new site MUST satisfy one of:" >&2
  echo "    (a) Bounded_proc.run_argv_with_timeout (RFC-0109 SSOT)" >&2
  echo "    (b) Eio.Time.with_timeout_exn + fresh Eio.Switch.run wrap" >&2
  echo "        at the caller boundary" >&2
  echo "    (c) Inline (* SPAWN-UNBOUNDED-OK: <reason> *) justification" >&2
  echo >&2
  echo "  After auditing, append the path:line entry to:" >&2
  echo "    scripts/lint-spawn-bounded.allowlist" >&2
  status=1
fi

if [ -n "$stale" ]; then
  echo "lint-spawn-bounded: STALE allowlist entry/entries (no longer matches a spawn line):" >&2
  echo "$stale" | sed 's/^/  /' >&2
  echo >&2
  echo "  Remove these from scripts/lint-spawn-bounded.allowlist." >&2
  status=1
fi

if [ $status -eq 0 ]; then
  count=$(echo "$discovered" | wc -l | tr -d ' ')
  echo "lint-spawn-bounded: PASS ($count spawn site(s), all in allowlist)"
fi

exit $status
