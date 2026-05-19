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

# Line-drift suggestions.  When a file appears in BOTH new and stale with
# matching counts (1:1 most often), the only thing that changed is line
# numbers — usually caused by godfile splits shrinking a file with a
# spawn site.  This is the recurring false-positive that blocks
# unrelated PRs on the spawn-bounded ratchet.  Print a copy-pasteable
# replacement so the next agent / human can refresh the allowlist
# without re-reading every spawn site.
if [ -n "$new" ] && [ -n "$stale" ]; then
  drifted_paths=$(
    comm -12 \
      <(echo "$stale" | awk -F: '{print $1}' | sort -u) \
      <(echo "$new"   | awk -F: '{print $1}' | sort -u)
  )
  if [ -n "$drifted_paths" ]; then
    echo >&2
    echo "lint-spawn-bounded: line-drift suggestions (same file, line moved):" >&2
    while IFS= read -r drifted_path; do
      [ -z "$drifted_path" ] && continue
      stale_for_path=$(echo "$stale" | awk -F: -v p="$drifted_path" '$1==p {print}')
      new_for_path=$(echo "$new"   | awk -F: -v p="$drifted_path" '$1==p {print}')
      stale_count=$(printf '%s\n' "$stale_for_path" | grep -c .)
      new_count=$(printf '%s\n' "$new_for_path" | grep -c .)
      if [ "$stale_count" = "$new_count" ]; then
        echo "  $drifted_path: $stale_count entry/entries moved" >&2
        # Pair in input order — ratchet has no semantic info to do
        # better, so 1:1 is the only safe inference.  When count > 1
        # the operator should still review each pair.
        paste <(printf '%s\n' "$stale_for_path") <(printf '%s\n' "$new_for_path") \
          | while IFS=$'\t' read -r s n; do
              echo "    replace  $s" >&2
              echo "    with     $n" >&2
              echo "    (also update the matching '# $s — ...' comment in scripts/lint-spawn-bounded.allowlist)" >&2
            done
      else
        echo "  $drifted_path: $stale_count stale vs $new_count new — counts differ, review manually" >&2
      fi
    done <<< "$drifted_paths"
  fi
fi

if [ $status -eq 0 ]; then
  count=$(echo "$discovered" | wc -l | tr -d ' ')
  echo "lint-spawn-bounded: PASS ($count spawn site(s), all in allowlist)"
fi

exit $status
