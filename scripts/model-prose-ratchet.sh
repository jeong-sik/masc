#!/usr/bin/env bash
# Model-facing prose inside OCaml ratchet.
#
# RFC docs/rfc/RFC-prompts-and-tool-definitions-outside-ocaml.md section 3
# item 0: the bytes and count of model-facing prose (tool descriptions,
# prompt fragments, judge prompts, tool-result guidance) still written as
# OCaml string literals may only go down. scripts/model-prose-scan.py owns
# the measurement (rules (i) structural description slots and (ii)
# allowlisted prompt files); this script compares it per file against
# scripts/model-prose-baseline.json.
#
# Any file whose bytes or count exceeds its baseline entry fails, and so
# does a file that has no baseline entry at all. When a file drops below its
# entry the check still passes and names the file so the baseline can be
# lowered with --update.
#
# Usage:
#   scripts/model-prose-ratchet.sh            # check; exit 0 ok / 2 drift up / 1 error
#   scripts/model-prose-ratchet.sh --update   # rewrite baseline from the current tree
#   scripts/model-prose-ratchet.sh --print    # print current per-file counts, no compare

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
SCANNER="${SCRIPT_DIR}/model-prose-scan.py"
BASELINE_FILE="${SCRIPT_DIR}/model-prose-baseline.json"

for tool in python3 git; do
  command -v "$tool" >/dev/null 2>&1 || {
    echo "[model-prose-ratchet] required tool missing: $tool" >&2
    exit 1
  }
done

[[ -f "$BASELINE_FILE" ]] || {
  echo "[model-prose-ratchet] baseline missing: $BASELINE_FILE" >&2
  exit 1
}

print_counts() {
  python3 "$SCANNER" --root "$REPO_ROOT" --baseline "$BASELINE_FILE"
}

update() {
  local commit
  commit="$(git -C "$REPO_ROOT" rev-parse HEAD)"
  python3 "$SCANNER" --root "$REPO_ROOT" --baseline "$BASELINE_FILE" --write-baseline --commit "$commit"
}

check() {
  python3 "$SCANNER" --root "$REPO_ROOT" --baseline "$BASELINE_FILE" --check
}

case "${1:-}" in
  --print)
    print_counts
    ;;
  --update)
    update
    ;;
  "")
    if check; then
      echo "[model-prose-ratchet] OK"
      exit 0
    else
      status=$?
      if (( status == 2 )); then
        echo "[model-prose-ratchet] FAIL - model-facing prose in OCaml grew" >&2
        echo "  description slots: move the text to <config-root> prompt/tool files" >&2
        echo "  (RFC prompts-and-tool-definitions-outside-ocaml)." >&2
        echo "  allowlisted files count every literal of 3+ tokens; shrink the file," >&2
        echo "  do not raise its entry. Run --update only after the count went down." >&2
      else
        echo "[model-prose-ratchet] ERROR - scanner failed (exit $status)" >&2
      fi
      exit "$status"
    fi
    ;;
  *)
    echo "Usage: $0 [--print|--update]" >&2
    exit 1
    ;;
esac
