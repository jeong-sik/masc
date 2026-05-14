#!/usr/bin/env bash
# Report provider/client-name literals outside approved catalogs.
#
# Default mode is advisory so the repo can measure the debt before enforcing.
# Use --fail once the report reaches zero.

set -euo pipefail

ROOT="${PROVIDER_NAME_HARDCODING_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
ALLOWLIST="${PROVIDER_NAME_HARDCODING_ALLOWLIST:-${ROOT}/scripts/lint/no-provider-name-hardcoding.allowlist}"
TERMS_FILE="${PROVIDER_NAME_HARDCODING_TERMS:-${ROOT}/scripts/lint/no-provider-name-hardcoding.terms}"
MODE="${1:---report}"

if [[ "${MODE}" == "--self-test" ]]; then
  self_root="$(mktemp -d -t no-provider-name-hc-self.XXXXXX)"
  trap 'rm -rf "${self_root}"' EXIT
  mkdir -p "${self_root}/lib" "${self_root}/scripts/lint"
  printf 'let leaked = "codex"\n' >"${self_root}/lib/leak.ml"
  : >"${self_root}/scripts/lint/no-provider-name-hardcoding.allowlist"
  printf 'codex\n' >"${self_root}/scripts/lint/no-provider-name-hardcoding.terms"

  set +e
  PROVIDER_NAME_HARDCODING_ROOT="${self_root}" \
    PROVIDER_NAME_HARDCODING_ALLOWLIST="${self_root}/scripts/lint/no-provider-name-hardcoding.allowlist" \
    PROVIDER_NAME_HARDCODING_TERMS="${self_root}/scripts/lint/no-provider-name-hardcoding.terms" \
    bash "$0" --fail >"${self_root}/out" 2>&1
  status="$?"
  set -e

  if [[ "${status}" -eq 0 ]]; then
    echo "provider-name-hardcoding self-test: expected --fail to reject a disallowed literal" >&2
    sed -n '1,80p' "${self_root}/out" >&2
    exit 1
  fi
  if ! grep -q 'off-catalog match' "${self_root}/out"; then
    echo "provider-name-hardcoding self-test: failure output did not include violation summary" >&2
    sed -n '1,80p' "${self_root}/out" >&2
    exit 1
  fi

  echo "provider-name-hardcoding self-test: pass"
  exit 0
fi

ROOTS=(
  "${ROOT}/lib"
  "${ROOT}/bin"
  "${ROOT}/dashboard/src"
  "${ROOT}/dashboard_bonsai/src"
  "${ROOT}/dashboard_bonsai/bin"
  "${ROOT}/scripts"
  "${ROOT}/sidecars"
)

if [[ ! -f "${TERMS_FILE}" ]]; then
  echo "provider-name-hardcoding: missing terms catalog: ${TERMS_FILE}" >&2
  exit 2
fi

TERMS=()
while IFS= read -r term; do
  TERMS+=("${term}")
done < <(
  sed -E 's/#.*//; s/^[[:space:]]+//; s/[[:space:]]+$//; /^$/d' \
    "${TERMS_FILE}" | sort -u
)

if [[ "${#TERMS[@]}" -eq 0 ]]; then
  echo "provider-name-hardcoding: empty terms catalog: ${TERMS_FILE}" >&2
  exit 2
fi

TERMS_ALT=""
for term in "${TERMS[@]}"; do
  if [[ ! "${term}" =~ ^[[:alnum:]_-]+$ ]]; then
    echo "provider-name-hardcoding: unsupported detector term '${term}' in ${TERMS_FILE}" >&2
    exit 2
  fi
  if [[ -z "${TERMS_ALT}" ]]; then
    TERMS_ALT="${term}"
  else
    TERMS_ALT="${TERMS_ALT}|${term}"
  fi
done

PATTERN="(^|[^[:alnum:]_])(${TERMS_ALT})([^[:alnum:]_]|$)"

ALLOW_TMP="$(mktemp -t no-provider-name-hc.XXXXXX)"
REPORT_TMP="$(mktemp -t no-provider-name-hc-report.XXXXXX)"
EXCEPTION_TMP="$(mktemp -t no-provider-name-hc-exceptions.XXXXXX)"
trap 'rm -f "${ALLOW_TMP}" "${REPORT_TMP}" "${EXCEPTION_TMP}"' EXIT

if [[ -f "${ALLOWLIST}" ]]; then
  sed -E 's/#.*//; s/^[[:space:]]+//; s/[[:space:]]+$//; /^$/d' \
    "${ALLOWLIST}" >"${ALLOW_TMP}"
fi

is_allowed_path() {
  local rel="$1"
  local allowed
  while IFS= read -r allowed; do
    [[ -z "${allowed}" ]] && continue
    if [[ "${rel}" == "${allowed}" ]]; then
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
      if command -v rg >/dev/null 2>&1; then
        perl -0pe 's{\(\*.*?\*\)}{ my $s=$&; $s =~ s/[^\n]/ /g; $s }gse' \
          "${file}" \
          | rg --no-heading --line-number --color=never -i "${PATTERN}" - \
            2>/dev/null || true
      else
        perl -0pe 's{\(\*.*?\*\)}{ my $s=$&; $s =~ s/[^\n]/ /g; $s }gse' \
          "${file}" \
          | grep -Eni "${PATTERN}" - 2>/dev/null || true
      fi
      ;;
    *)
      if command -v rg >/dev/null 2>&1; then
        rg --no-heading --line-number --color=never -i "${PATTERN}" "${file}" \
          2>/dev/null || true
      else
        grep -Eni "${PATTERN}" "${file}" 2>/dev/null || true
      fi
      ;;
  esac
}

list_files() {
  local root="$1"
  if command -v rg >/dev/null 2>&1; then
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
  else
    find "${root}" \
      \( -path '*/node_modules/*' -o -path '*/_build/*' -o -path '*/test/*' -o -path '*/tests/*' \) -prune \
      -o -type f \
      ! -name '*.md' \
      ! -name '*.json' \
      ! -name '*.lock' \
      ! -name '*.png' \
      ! -name '*.jpg' \
      ! -name '*.jpeg' \
      ! -name '*.gif' \
      ! -name '*.webp' \
      ! -name '*.ico' \
      ! -name '*.woff' \
      ! -name '*.woff2' \
      ! -name '*.ttf' \
      ! -name '*.test.*' \
      -print
  fi
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

    if grep -Eq 'provider-name-hardcoding-ok:[[:space:]]+[^[:space:]]' <<<"${content}"; then
      printf '%s:%s:%s\n' "${rel}" "${line_no}" "${content}" >>"${EXCEPTION_TMP}"
      continue
    fi
    printf '%s:%s:%s\n' "${rel}" "${line_no}" "${content}" >>"${REPORT_TMP}"
    done < <(scan_file "${file}")
  done < <(list_files "${root}")
done

count="$(wc -l <"${REPORT_TMP}" | tr -d '[:space:]')"
exception_count="$(wc -l <"${EXCEPTION_TMP}" | tr -d '[:space:]')"

if [[ "${MODE}" == "--summary" ]]; then
  awk -F: '{ c[$1]++ } END { for (file in c) print c[file], file }' \
    "${REPORT_TMP}" | sort -nr
  echo "provider-name-hardcoding: ${count} off-catalog match(es)"
  echo "provider-name-hardcoding: ${exception_count} inline exception(s)"
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
if [[ "${exception_count}" -gt 0 ]]; then
  echo "provider-name-hardcoding: ${exception_count} inline exception(s)"
fi
exit 0
