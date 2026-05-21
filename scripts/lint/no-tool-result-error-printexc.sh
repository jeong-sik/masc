#!/usr/bin/env bash
# RFC-0148 §5.4 backsliding guard.
#
# Reject lines in lib/tool_*.ml that route a raw exception text into
# Tool_result.error on the same line. The closed-sum surface
# (Tool_error.t, lib/tool_error.ml) is the SSOT; new failure surfaces
# must go through Tool_error.of_exn so the LLM sees a typed `kind`
# tag instead of a free-form Printexc.to_string blob.
#
# Pattern matched (line-level): a line containing both `Tool_result.error`
# and `Printexc.to_string` — the historical N-of-M leak shape.
#
# Allowed shape after migration:
#
#   let err = Tool_error.of_exn ~detail:"..." exn in
#   Tool_result.error ~tool_name ~start_time (Tool_error.to_string err)
#
# That form keeps `Printexc.to_string` on a *different* line (inside the
# ~detail builder) and routes the LLM-facing value through Tool_error.
#
# Exit 1 if any violating line is found.

set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

# rg may exit non-zero when there are zero matches; absorb that.
matches="$(rg --line-number 'Tool_result\.error' lib/tool_*.ml 2>/dev/null || true)"

violations=0
while IFS= read -r line; do
  [[ -z "$line" ]] && continue
  if echo "$line" | grep -q 'Printexc\.to_string'; then
    echo "ERROR: Tool_result.error must not embed Printexc.to_string inline (use Tool_error.of_exn): $line"
    violations=$((violations + 1))
  fi
done <<< "$matches"

if [[ $violations -gt 0 ]]; then
  echo ""
  echo "Found $violations RFC-0148 backsliding site(s)."
  echo "Route the exception through Tool_error.of_exn (lib/tool_error.mli) and"
  echo "pass Tool_error.to_string to Tool_result.error. See RFC-0148 §5.4."
  exit 1
fi

echo "OK: no RFC-0148 backsliding sites in lib/tool_*.ml"
exit 0
