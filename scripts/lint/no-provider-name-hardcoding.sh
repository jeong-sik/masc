#!/usr/bin/env bash
# Report provider/client-name literals outside approved catalogs.
#
# Default mode is advisory so the repo can measure the debt before enforcing.
# Use --fail once the report reaches zero.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
ALLOWLIST="${ROOT}/scripts/lint/no-provider-name-hardcoding.allowlist"
MODE="${1:---report}"

ROOTS=(
  "${ROOT}/lib"
  "${ROOT}/bin"
  "${ROOT}/dashboard/src"
  "${ROOT}/dashboard_bonsai/src"
  "${ROOT}/dashboard_bonsai/bin"
  "${ROOT}/scripts"
  "${ROOT}/sidecars"
)

PATTERN='\b(codex|gemini|claude|kimi|glm)\b'

ALLOW_TMP="$(mktemp -t no-provider-name-hc.XXXXXX)"
REPORT_TMP="$(mktemp -t no-provider-name-hc-report.XXXXXX)"
trap 'rm -f "${ALLOW_TMP}" "${REPORT_TMP}"' EXIT

if [[ -f "${ALLOWLIST}" ]]; then
  sed -E 's/#.*//; s/^[[:space:]]+//; s/[[:space:]]+$//; /^$/d' \
    "${ALLOWLIST}" >"${ALLOW_TMP}"
fi

is_allowed_path() {
  local rel="$1"
  local allowed
  while IFS= read -r allowed; do
    [[ -z "${allowed}" ]] && continue
    if [[ "${rel}" == "${allowed}" || "${rel}" == "${allowed}/"* ]]; then
      return 0
    fi
  done <"${ALLOW_TMP}"
  return 1
}

scan_file() {
  local file="$1"

  case "${file}" in
    *.ml | *.mli)
      # Strip OCaml block comments while preserving line numbers, so the
      # report stays focused on code/string literals rather than doc prose.
      perl -0pe 's{\(\*.*?\*\)}{ my $s=$&; $s =~ s/[^\n]/ /g; $s }gse' \
        "${file}" \
        | rg --no-heading --line-number --color=never -i "${PATTERN}" - \
          2>/dev/null || true
      ;;
    *)
      rg --no-heading --line-number --color=never -i "${PATTERN}" "${file}" \
        2>/dev/null || true
      ;;
  esac
}

for root in "${ROOTS[@]}"; do
  [[ -d "${root}" ]] || continue
  while IFS= read -r file; do
    rel="${file#${ROOT}/}"
    if is_allowed_path "${rel}"; then
      continue
    fi

    while IFS= read -r match; do
      line_no="${match%%:*}"
      content="${match#*:}"
    trimmed="$(sed -E 's/^[[:space:]]+//' <<<"${content}")"

    case "${trimmed}" in
      '(*'* | '#'* | '//'*)
        continue
        ;;
    esac

    if grep -q 'provider-name-hardcoding-ok:' <<<"${content}"; then
      continue
    fi
    printf '%s:%s:%s\n' "${rel}" "${line_no}" "${content}" >>"${REPORT_TMP}"
    done < <(scan_file "${file}")
  done < <(
    rg --files "${root}" \
      --glob '!**/*.md' \
      --glob '!**/*.json' \
      --glob '!**/*.lock' \
      --glob '!**/*.png' \
      --glob '!**/*.jpg' \
      --glob '!**/*.jpeg' \
      --glob '!**/*.gif' \
      --glob '!**/*.webp' \
      --glob '!**/*.ico' \
      --glob '!**/*.woff' \
      --glob '!**/*.woff2' \
      --glob '!**/*.ttf' \
      --glob '!**/*.test.*' \
      --glob '!**/test/**' \
      --glob '!**/tests/**' \
      --glob '!**/node_modules/**' \
      --glob '!**/_build/**'
  )
done

count="$(wc -l <"${REPORT_TMP}" | tr -d '[:space:]')"

if [[ "${MODE}" == "--summary" ]]; then
  awk -F: '{ c[$1]++ } END { for (file in c) print c[file], file }' \
    "${REPORT_TMP}" | sort -nr
  echo "provider-name-hardcoding: ${count} off-catalog match(es)"
  exit 0
fi

if [[ "${count}" -gt 0 ]]; then
  echo "provider-name-hardcoding: ${count} off-catalog match(es)"
  sed -n '1,120p' "${REPORT_TMP}"
  if [[ "${count}" -gt 120 ]]; then
    echo "... truncated; rerun with --summary for file-level counts"
  fi
  if [[ "${MODE}" == "--fail" ]]; then
    exit 1
  fi
  exit 0
fi

echo "provider-name-hardcoding: clean"
exit 0
