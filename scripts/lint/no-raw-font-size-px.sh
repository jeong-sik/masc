#!/usr/bin/env bash
# Detect raw `font-size: <N>px` declarations in the dashboard stylesheets
# where <N> is a value that already has a generated --fs-<N> token. Such a
# literal bypasses the design-token SSOT (design-system/tokens/source.ts ->
# tokens.generated.css): the rendered size silently stops tracking the token
# if the token value later changes, and the type scale fragments.
#
# Why this gate exists:
#   chunk F of the dashboard token consolidation converted 1062 exact-match
#   font-size literals to `var(--fs-<N>)`. This ratchet keeps the converted
#   set at zero so new code does not re-introduce raw literals where a token
#   exists.
#
# Signal:
#   `font-size: <N>px` in dashboard/src/styles/**.css (excluding @generated
#   files) where <N> is one of the tokenized whole-pixel sizes:
#     9 10 11 12 13 14 16 20 28 36 56
#
# Deliberately NOT flagged (no token exists, so there is nothing to use):
#   - fractional sizes (e.g. 10.5px, 9.5px) — these await a type-scale
#     decision, tracked in override-drift / chunk F notes, not this gate.
#   - whole sizes without a token (e.g. 15px, 17px, 18px, 22px).
#   Adding such a literal is allowed; tokenizing it requires expanding the
#   --fs-* scale first (a design decision), after which this list grows.
#
# Exit codes:
#   0 - clean
#   1 - a raw font-size literal with an existing token was found

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
STYLES_DIR="${ROOT}/dashboard/src/styles"

[[ -d "${STYLES_DIR}" ]] || { echo "no-raw-font-size-px: styles dir absent, skipping"; exit 0; }

# Tokenized whole-pixel sizes (must mirror --fs-* in tokens.generated.css).
TOKEN_PX='9|10|11|12|13|14|16|20|28|36|56'

violations=()
while IFS= read -r match; do
  [[ -z "${match}" ]] && continue
  path="${match%%:*}"
  # Skip @generated artifacts (header marker in the first line).
  if head -n 1 "${path}" 2>/dev/null | grep -q '@generated'; then
    continue
  fi
  violations+=("${match#${ROOT}/}")
done < <(
  rg --no-heading --line-number --color=never \
     --glob '*.css' \
     "font-size:[[:space:]]*(${TOKEN_PX})px\b" "${STYLES_DIR}" 2>/dev/null || true
)

if [[ ${#violations[@]} -gt 0 ]]; then
  echo "Raw font-size literal found where a --fs-* token exists." >&2
  echo "Use the token so the size tracks the design-system SSOT:" >&2
  echo "  Bad : font-size: 11px;" >&2
  echo "  Good: font-size: var(--fs-11);" >&2
  echo "" >&2
  echo "Fractional/unmapped sizes (e.g. 10.5px, 17px) are exempt — they have" >&2
  echo "no token yet. Tokenizing them needs a --fs-* scale expansion first." >&2
  echo "" >&2
  echo "Violations:" >&2
  for v in "${violations[@]}"; do
    echo "  ${v}" >&2
  done
  exit 1
fi

echo "no-raw-font-size-px: clean"
