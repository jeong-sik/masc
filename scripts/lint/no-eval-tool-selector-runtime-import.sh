#!/usr/bin/env bash
# Keep eval-only tool-call selectors out of live keeper/runtime control paths.
#
# Eval_tool_selector is an observational harness primitive. It may match
# recorded route evidence in eval/replay/benchmark code, but live keeper and
# runtime code must not import it as a policy gate.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

if ! command -v rg >/dev/null 2>&1; then
  echo "[no-eval-tool-selector-runtime-import] required tool missing: rg" >&2
  exit 2
fi

tmp="$(mktemp -t eval-tool-selector-runtime-import.XXXXXX)"
trap 'rm -f "$tmp"' EXIT

(
  cd "$ROOT"
  rg -n --glob '*.ml' --glob '*.mli' '\bEval_tool_selector\b' \
    lib/keeper lib/runtime
) >"$tmp" || true

if [[ -s "$tmp" ]]; then
  echo "[no-eval-tool-selector-runtime-import] Eval_tool_selector used in live keeper/runtime paths" >&2
  cat "$tmp" >&2
  echo "[no-eval-tool-selector-runtime-import] keep it in eval, replay, benchmark, or dashboard read-model code" >&2
  exit 1
fi

echo "[no-eval-tool-selector-runtime-import] OK"
