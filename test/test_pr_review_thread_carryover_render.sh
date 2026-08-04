#!/usr/bin/env bash
# Render contract for scripts/pr-review-thread-carryover.sh --render-only:
# unresolved threads appear with path:line, author, flattened excerpt, and the
# dedup marker; resolved threads are excluded; an all-resolved document
# renders nothing.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT_DIR/scripts/pr-review-thread-carryover.sh"

FIXTURE='{
  "data": { "repository": { "pullRequest": { "reviewThreads": { "nodes": [
    { "id": "T_alpha", "isResolved": false, "path": "lib/foo.ml", "line": 12,
      "comments": { "nodes": [ { "author": { "login": "reviewer-a" },
        "body": "P1 finding line one\r\nline two" } ] } },
    { "id": "T_beta", "isResolved": true, "path": "lib/bar.ml", "line": 34,
      "comments": { "nodes": [ { "author": { "login": "reviewer-b" },
        "body": "already handled" } ] } },
    { "id": "T_gamma", "isResolved": false, "path": null, "line": null,
      "comments": { "nodes": [ { "author": null, "body": "orphan finding" } ] } }
  ] } } } }
}'

OUTPUT="$(printf '%s' "$FIXTURE" | bash "$SCRIPT" --render-only jeong-sik/masc 77)"

expect_contains() {
    local needle="$1"
    if ! printf '%s' "$OUTPUT" | grep -qF "$needle"; then
        echo "render output is missing: $needle" >&2
        printf '%s\n' "$OUTPUT" >&2
        exit 1
    fi
}

expect_contains "2 unresolved review thread(s)"
expect_contains "lib/foo.ml:12"
expect_contains "reviewer-a"
expect_contains "T_alpha"
expect_contains "P1 finding line one line two"
expect_contains "?:?"
expect_contains "orphan finding"
expect_contains "carryover-marker:pr-77"

if printf '%s' "$OUTPUT" | grep -qF "already handled"; then
    echo "render output leaked a resolved thread" >&2
    printf '%s\n' "$OUTPUT" >&2
    exit 1
fi

ALL_RESOLVED='{
  "data": { "repository": { "pullRequest": { "reviewThreads": { "nodes": [
    { "id": "T_beta", "isResolved": true, "path": "lib/bar.ml", "line": 34,
      "comments": { "nodes": [ { "author": { "login": "reviewer-b" },
        "body": "already handled" } ] } }
  ] } } } }
}'

EMPTY_OUTPUT="$(printf '%s' "$ALL_RESOLVED" | bash "$SCRIPT" --render-only jeong-sik/masc 77)"
if [ -n "$EMPTY_OUTPUT" ]; then
    echo "all-resolved document must render nothing" >&2
    printf '%s\n' "$EMPTY_OUTPUT" >&2
    exit 1
fi

echo "review thread carryover render contract holds"
