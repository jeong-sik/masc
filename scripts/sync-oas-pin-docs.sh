#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
CHECK_ONLY=0

usage() {
  cat <<'EOF'
Usage: scripts/sync-oas-pin-docs.sh [--check]

Options:
  --check      Verify generated OAS pin doc blocks and badges are up to date.
  -h, --help   Show this help.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --check)
      CHECK_ONLY=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

source "${SCRIPT_DIR}/oas-agent-sdk-pin.sh"

rel_path() {
  local file="$1"
  case "${file}" in
    "${REPO_ROOT}"/*) printf '%s' "${file#"${REPO_ROOT}/"}" ;;
    *) printf '%s' "${file}" ;;
  esac
}

write_or_check() {
  local file="$1" tmp_file="$2" repair="$3"
  local rel
  rel="$(rel_path "${file}")"

  if cmp -s "${file}" "${tmp_file}"; then
    rm -f "${tmp_file}"
    return 0
  fi

  if [[ "${CHECK_ONLY}" -eq 1 ]]; then
    echo "out of sync: ${rel}" >&2
    echo "repair: ${repair}" >&2
    rm -f "${tmp_file}"
    return 1
  fi

  mv "${tmp_file}" "${file}"
  echo "updated: ${rel}"
}

replace_generated_block() {
  local file="$1"
  local marker="$2"
  local begin="<!-- BEGIN GENERATED: ${marker} -->"
  local end="<!-- END GENERATED: ${marker} -->"
  local replacement_file tmp_file

  replacement_file="$(mktemp)"
  tmp_file="$(mktemp)"
  cat > "${replacement_file}"

  if ! grep -Fq "${begin}" "${file}" || ! grep -Fq "${end}" "${file}"; then
    echo "missing generated block markers for ${marker} in ${file}" >&2
    rm -f "${replacement_file}" "${tmp_file}"
    return 1
  fi

  awk -v begin="${begin}" -v end="${end}" -v replacement_file="${replacement_file}" '
    BEGIN {
      skipping = 0
      saw_begin = 0
      saw_end = 0
    }
    $0 == begin {
      saw_begin = 1
      print
      while ((getline line < replacement_file) > 0) {
        print line
      }
      close(replacement_file)
      skipping = 1
      next
    }
    $0 == end {
      saw_end = 1
      skipping = 0
      print
      next
    }
    !skipping {
      print
    }
    END {
      if (!saw_begin || !saw_end) {
        exit 4
      }
    }
  ' "${file}" > "${tmp_file}"

  if [[ "${CHECK_ONLY}" -eq 1 ]]; then
    rm -f "${replacement_file}"
    write_or_check "${file}" "${tmp_file}" "bash scripts/sync-oas-pin-docs.sh"
    return 0
  fi

  write_or_check "${file}" "${tmp_file}" "bash scripts/sync-oas-pin-docs.sh"
  rm -f "${replacement_file}"
}

sync_readme_badge() {
  local file="${REPO_ROOT}/README.md"
  local pattern='^\[!\[agent_sdk\]\(https://img[.]shields[.]io/badge/agent__sdk-.*-blue[.]svg\)\]\(https://github[.]com/jeong-sik/oas\)$'
  local count tmp_file expected_line

  count="$(grep -Ec "${pattern}" "${file}" || true)"
  if [[ "${count}" != "1" ]]; then
    echo "README agent_sdk badge: expected exactly one row in $(rel_path "${file}"), found ${count}" >&2
    return 1
  fi

  expected_line="[![agent_sdk](https://img.shields.io/badge/agent__sdk-%3E%3D%20${OAS_AGENT_SDK_MIN_VERSION}-blue.svg)](https://github.com/jeong-sik/oas)"
  tmp_file="$(mktemp)"
  sed -E "s|${pattern}|${expected_line}|" "${file}" > "${tmp_file}"
  write_or_check "${file}" "${tmp_file}" "bash scripts/sync-oas-pin-docs.sh"
}

manual_doc="${REPO_ROOT}/docs/KEEPER-USER-MANUAL.md"

printf -v manual_body '%s' \
  "OAS pin metadata is generated from \`scripts/oas-agent-sdk-pin.sh\`. Current dependency floor: \`agent_sdk >= ${OAS_AGENT_SDK_MIN_VERSION}\`, runtime pin: \`${OAS_AGENT_SDK_TRACK_REF}@${OAS_AGENT_SDK_SHA}\`, declared base version: \`${OAS_AGENT_SDK_BASE_VERSION}\`. 최신성 검증이 필요할 때는 문서에 적힌 숫자보다 \`dune-project\`와 pin script를 우선 truth source로 본다."

replace_generated_block "${manual_doc}" "oas-pin-manual" <<<"${manual_body}"
sync_readme_badge
