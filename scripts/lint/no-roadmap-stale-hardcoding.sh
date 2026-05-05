#!/usr/bin/env bash
# Detect regression of hardcoded LLM model name prefixes in OCaml/TOML
# under lib/ and oas/lib/.
#
# Why this gate exists:
#   `fundamental_roadmap.md` Phase 2 calls out 40+ model-prefix matches
#   in lib/cascade/capabilities.ml (e.g. "gpt-4o" | "claude-3.5-sonnet" |
#   "gemini-1.5-pro"). The 2026-05-05 reality-check audit
#   (docs/audit/2026-05-05-fundamental-roadmap-reality-check.md) found
#   capabilities.ml gone and remaining instances near-zero. PR #12990
#   (refactor(cascade): externalize scoring magic numbers) cleaned
#   adjacent magic numbers. This gate prevents the prefix-match style
#   from creeping back via copy-paste.
#
# Signal:
#   Quoted model-name prefix appearing in *.ml or *.toml under tracked
#   source roots:
#     "gpt-4o*", "gpt-5*", "claude-3-5-sonnet*", "claude-3.5-sonnet*",
#     "claude-4*", "gemini-1.5*", "gemini-2*"
#
# Allowed (never flagged):
#   - Anything outside lib/ or oas/lib/ (tests, scripts, RFCs, configs).
#   - Lines marked `(* keep-model-name *)` or `# keep-model-name`.
#   - Entries listed in the allowlist file
#     (scripts/lint/no-roadmap-stale-hardcoding.allowlist) as "path:line".
#
# Allowlist format: one entry per line, "path:line", '#' comments allowed.
#
# Exit codes:
#   0 — clean
#   1 — new violations (not in allowlist)

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
ALLOWLIST="${ROOT}/scripts/lint/no-roadmap-stale-hardcoding.allowlist"

# Ranges scanned. oas/lib/ stays optional in case the repo layout
# changes; rg silently skips missing roots.
ROOTS=("${ROOT}/lib" "${ROOT}/oas/lib")

PATTERN='"(gpt-4o|gpt-5|claude-3[-.]5-sonnet|claude-3-5|claude-4|gemini-1\.5|gemini-2)[a-zA-Z0-9_.-]*"'

# Build allowlist set (path:line) into a temp file. Portable across
# macOS bash 3.2 and Linux bash 5.x — avoids `declare -A`.
ALLOW_TMP="$(mktemp -t no-roadmap-stale-hc.XXXXXX)"
trap 'rm -f "${ALLOW_TMP}"' EXIT
if [[ -f "${ALLOWLIST}" ]]; then
  sed -E 's/#.*//; s/[[:space:]]//g; /^$/d' "${ALLOWLIST}" >"${ALLOW_TMP}"
fi

violations=0
report=()

for root in "${ROOTS[@]}"; do
  [[ -d "${root}" ]] || continue
  while IFS= read -r match; do
    # match format: relative_path:line:content
    rel="${match%%:*}"
    rest="${match#*:}"
    line_no="${rest%%:*}"
    content="${rest#*:}"
    # strip ROOT prefix
    rel="${rel#${ROOT}/}"
    key="${rel}:${line_no}"

    # Skip lines marked keep-model-name
    if grep -qE '\(\*[^*]*keep-model-name|#[[:space:]]*keep-model-name' <<<"${content}"; then
      continue
    fi

    # Skip allowlisted
    if [[ -s "${ALLOW_TMP}" ]] && grep -Fxq "${key}" "${ALLOW_TMP}"; then
      continue
    fi

    report+=("${key}: ${content}")
    violations=$((violations + 1))
  done < <(rg --no-heading --line-number --color=never --type-add 'mlx:*.{ml,mli,mll,mly}' -t mlx -t toml "${PATTERN}" "${root}" 2>/dev/null || true)
done

if [[ ${violations} -gt 0 ]]; then
  echo "::error title=Hardcoded model prefix::${violations} new instances found"
  printf '  %s\n' "${report[@]}"
  echo
  echo "Add to ${ALLOWLIST#${ROOT}/} (path:line) only with cross-reference"
  echo "to a Catalog/router-based replacement task. See"
  echo "docs/audit/2026-05-05-fundamental-roadmap-reality-check.md §8."
  exit 1
fi

echo "no-roadmap-stale-hardcoding: clean (${#ROOTS[@]} roots scanned)"
exit 0
