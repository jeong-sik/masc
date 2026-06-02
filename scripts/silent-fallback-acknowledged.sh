#!/usr/bin/env bash
# silent-fallback-acknowledged.sh — RFC-0109 Phase 2 P0 infrastructure.
#
# Lists every [@@silent_fallback_acknowledged "..."] attribute occurrence
# in the OCaml codebase.  Currently 0 sites — the attribute name is
# reserved for the Phase 2 ppxlib lint described in
# docs/rfc/RFC-0109-silent-fallback-discipline.md §6.2.
#
# Until Phase 2 is implemented, this script gives a baseline count and a
# `rg`-style table that PR review can quote.  When Phase 2 lints, the
# lint's "acknowledged" lookup MUST be byte-identical to this scan so
# review and lint never diverge.
#
# Output: one site per line:
#   <file>:<line>: <attribute body>
# Exit 0 = scan completed (regardless of count).
# Use the trailing "total: N" line as the count.
#
# Limitations vs Phase 2 lint:
#   - regex-only; does not validate that the attribute attaches to a
#     [Pexp_match] / [Pexp_try] node (Phase 2 ppxlib will).
#   - sees the literal string only, so a renamed attribute is invisible.
#   - cannot enforce attribute *placement* on a wildcard arm.
#
# These limitations are intentional: a regex baseline gives operators a
# count today without paying the ppxlib build cost.  Phase 2 supersedes.

set -euo pipefail

REPO_ROOT="$(git -C "$(dirname "$0")/.." rev-parse --show-toplevel)"
ATTR_NAME="silent_fallback_acknowledged"

cd "$REPO_ROOT"

# Match the OCaml attribute forms:
#   [@@silent_fallback_acknowledged "..."]
#   [@@@silent_fallback_acknowledged "..."]   (floating)
#   [@silent_fallback_acknowledged "..."]     (item-attached)
# Restrict the rationale string to non-quote chars so a stray quote does
# not eat the rest of the line.
PATTERN="\\[@@?@?${ATTR_NAME}[[:space:]]+\"[^\"]*\"\\]"

count=0
if rg --line-number --no-heading --color=never "$PATTERN" lib/ bin/ test/ 2>/dev/null > /tmp/silent_fallback_hits.$$; then
  while IFS= read -r line; do
    echo "$line"
    count=$((count + 1))
  done < /tmp/silent_fallback_hits.$$
fi
rm -f /tmp/silent_fallback_hits.$$

echo "---"
echo "total: ${count}"
echo "attribute_name: ${ATTR_NAME}"
echo "rfc: docs/rfc/RFC-0109-silent-fallback-discipline.md §6.2"
