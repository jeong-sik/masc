#!/usr/bin/env bash
# audit-rfc-closeout-lag.sh — Surface RFCs whose status: Draft has been
# left behind while implementation commits already landed on origin/main.
#
# Background: 2026-05-21 audit found 20+ Draft RFCs whose RFC-NNNN
# identifier appears in main commit subjects. The frontmatter status
# update is a manual step performed by the RFC author after every
# phase; that discipline often slips. This script makes the lag
# observable without prescribing a fix (don't auto-flip status —
# Active vs Implemented is a judgement call).
#
# Usage:
#   bash scripts/audit-rfc-closeout-lag.sh [--since DATE] [--min N] [--exclude-body]
#
# Defaults: since=2026-04-01, min=1, exclude-body=false.
#
# --exclude-body: skip commits whose subject is RFC body or renumber
#   (`docs(rfc):` / `chore(rfc): renumber`). Reduces false positives
#   surfaced by the 2026-05-21 sweep where RFC-0145 and RFC-0122 were
#   flagged purely because of body / renumber commits with no
#   implementation behind them.
#
# Output (TSV on stdout, sorted by descending commit count):
#   RFC-NNNN<TAB><commits>
#
# Exit status: always 0 unless a tooling error occurs. The audit is
# observational, not a gate.
#
# See: docs/rfc/README.md §Status, memory/feedback_rfc_closeout_lag_systemic_pattern_2026_05_21.md

set -euo pipefail

since="2026-04-01"
min_commits=1
exclude_body=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --since)
      since="$2"; shift 2 ;;
    --min)
      min_commits="$2"; shift 2 ;;
    --exclude-body)
      exclude_body=true; shift ;;
    -h|--help)
      sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'
      exit 0 ;;
    *)
      echo "unknown flag: $1" >&2
      exit 2 ;;
  esac
done

cd "$(git rev-parse --show-toplevel)"

# Match commit subjects that are RFC body or renumber paperwork rather
# than implementation. Format from `git log --oneline`:
#   <short_sha> docs(rfc): ... RFC-NNNN ...
#   <short_sha> chore(rfc): renumber RFC-NNNN ...
# Anchored after the sha+space prefix so production fix() / feat()
# subjects that mention "docs(rfc)" in their body do not get dropped.
body_subject_pattern='^[a-f0-9]+ (docs\(rfc\)|chore\(rfc\): renumber)'

# Capture RFC identifiers appearing in commit subjects on origin/main
# within the window. Sort -u + while-read keeps the script grep-free
# in the loop body.
git log --oneline origin/main --since="$since" 2>/dev/null \
  | grep -oE "RFC-[0-9]+" \
  | sort -u \
  | while read -r rfc; do
      # Find a frontmatter file for this RFC. Multi-phase RFCs may have
      # several files sharing the number; we only need the main spec.
      spec=$(ls "docs/rfc/${rfc}"-*.md 2>/dev/null | head -1)
      [[ -z "$spec" ]] && continue

      # Only flag entries that are still Draft. Active and Implemented
      # are intentional states — don't report them.
      if ! grep -q '^status: Draft' "$spec"; then
        continue
      fi

      # Count commit subjects that reference this RFC identifier.
      # Disable pipefail locally so an empty intermediate grep does
      # not abort the surrounding while-read loop.
      set +o pipefail
      if [[ "$exclude_body" == true ]]; then
        count=$(git log --oneline origin/main --since="$since" 2>/dev/null \
          | grep "${rfc}\b" \
          | grep -vE "$body_subject_pattern" \
          | wc -l | tr -d ' ')
      else
        count=$(git log --oneline origin/main --since="$since" 2>/dev/null \
          | grep -c "${rfc}\b")
      fi
      set -o pipefail

      if [[ "$count" -ge "$min_commits" ]]; then
        printf "%s\t%d\n" "$rfc" "$count"
      fi
    done \
  | sort -t$'\t' -k2 -n -r
