#!/usr/bin/env bash
# Guard OAS against coordinator-specific vocabulary in public/runtime surfaces.
#
# Tiers:
#   strict  (default): lib/, bin/, README.md — any match fails the build.
#   public  (default): current public docs/examples/scripts and root lockfiles.
#                      Historical RFC/audit/archive material is not scanned.
#   warn    (--include-tests): also scan test/. Matches are reported but exit 0.
#                              Use --strict-tests to promote warn-tier matches to failures.
#
# Permanently excluded from broad scans: docs/archive/, CHANGELOG.md, docs/rfc/.
# (history records and design RFCs may legitimately mention prior coordinator names).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

include_tests=0
strict_tests=0
for arg in "$@"; do
  case "$arg" in
    --include-tests) include_tests=1 ;;
    --strict-tests)  include_tests=1; strict_tests=1 ;;
    -h|--help)
      sed -n '1,12p' "$0"
      exit 0
      ;;
    *)
      echo "unknown flag: $arg" >&2
      exit 2
      ;;
  esac
done

if ! command -v rg >/dev/null 2>&1; then
  echo "SDK independence check failed: ripgrep (rg) is required" >&2
  exit 1
fi

shopt -s nullglob

STRICT_TARGETS=(lib bin README.md)
PUBLIC_TARGETS=(
  docs/gemma4-ollama-thinking.md
  docs/tool-concurrency.md
  examples/async_agent_demo.ml
  scripts/dune-local.sh
)
ROOT_ARTIFACT_TARGETS=()
for artifact in *.opam.locked; do
  ROOT_ARTIFACT_TARGETS+=("$artifact")
done
if [[ "${#ROOT_ARTIFACT_TARGETS[@]}" -gt 0 ]]; then
  PUBLIC_TARGETS+=("${ROOT_ARTIFACT_TARGETS[@]}")
fi
WARN_TARGETS=(test)

# Strict tier: full coordinator vocabulary (lib/, bin/, README.md).
strict_patterns=(
  '\bmasc\b'
  'masc_'
  '\bkeeper\b'
  'keeper_'
  '\bboard\b'
  'board_'
  '\broom\b'
  'room_'
)

# Warn tier: narrowed to high-signal terms only.
# `room` and `board` collide with common test vocabulary (schema parameter
# names, JSON keys, "no room", "scoreboard", etc.) and produce too many
# false positives in test/. Keep them strict-only.
warn_patterns=(
  '\bmasc\b'
  'masc_'
  '\bkeeper\b'
  'keeper_'
)

# Filter out:
#   - lines explicitly tagged with `boundary-allow` (intentional historical references)
#   - a match on the line immediately following such a tag (formatter can move
#     inline comments to their own line).
#   - OCaml comment lines that start with "(*", "*", or "(**"  (left-trimmed)
# Caveat: this is a line-level heuristic, not a full OCaml lexer. A code line
# containing an inline `(* ... *)` whose pattern sits inside the comment may
# slip through. Use `boundary-allow` for those edge cases.
filter_noise() {
  local pattern="$1"
  awk -v pattern="$pattern" '
    {
      # rg context format emits:
      #   path:120:  MATCH
      #   path:120-  CONTEXT
      # and chunk separators "--".
      if ($0 == "--") {
        last_file = ""
        last_allow = 0
        next
      }
      is_context = 0
      file = ""
      content = $0
      if (match($0, /^[^:]+:[0-9]+:/)) {
        file = substr($0, 1, RLENGTH)
        sub(/:[0-9]+:$/, "", file)
        content = substr($0, RSTART + RLENGTH)
      } else if (match($0, /^[^-]+-[0-9]+-/)) {
        is_context = 1
        file = substr($0, 1, RLENGTH)
        sub(/-[0-9]+-$/, "", file)
        content = substr($0, RSTART + RLENGTH)
      } else {
        next
      }
      if (file != last_file) {
        last_file = file
        last_allow = 0
      }
      # left-trim
      sub(/^[[:space:]]+/, "", content)
      if (is_context) {
        last_allow = (content ~ /boundary-allow/)
        next
      }
      # Preserve existing OCaml comment filtering.
      if (content ~ /^\*/) next
      if (content ~ /^\(\*/) next
      # explicit allow marker
      if (last_allow && content ~ pattern) {
        last_allow = 0
        next
      }
      print $0
    }
  ' 
}

scan_tier() {
  local tier="$1"; shift
  local fail_on_match="$1"; shift
  # bash 3.2 (macOS default) lacks `local -n` nameref. Use indirect array
  # expansion via eval to read the patterns array by name.
  local patterns_var="$1"; shift
  local targets=("$@")
  local patterns_arr=()
  eval "patterns_arr=( \"\${${patterns_var}[@]}\" )"
  local tier_fail=0
  for pattern in "${patterns_arr[@]}"; do
    local matches
    matches="$(rg --with-filename -n -i -C 1 -e "$pattern" "${targets[@]}" 2>/dev/null | filter_noise "$pattern" || true)"
    if [[ -n "$matches" ]]; then
      if [[ "$fail_on_match" -eq 1 ]]; then
        echo "FAIL [$tier]: coordinator-specific term matched pattern: $pattern" >&2
      else
        echo "WARN [$tier]: coordinator-specific term matched pattern: $pattern" >&2
      fi
      echo "$matches" >&2
      tier_fail=1
    fi
  done
  return "$tier_fail"
}

overall_fail=0
if ! scan_tier "strict" 1 strict_patterns "${STRICT_TARGETS[@]}"; then
  overall_fail=1
fi

if [[ "${#PUBLIC_TARGETS[@]}" -gt 0 ]]; then
  if ! scan_tier "public" 1 warn_patterns "${PUBLIC_TARGETS[@]}"; then
    overall_fail=1
  fi
fi

if [[ "$include_tests" -eq 1 ]]; then
  if ! scan_tier "test" "$strict_tests" warn_patterns "${WARN_TARGETS[@]}"; then
    if [[ "$strict_tests" -eq 1 ]]; then
      overall_fail=1
    fi
  fi
fi

if [[ "$overall_fail" -ne 0 ]]; then
  echo "SDK independence check failed" >&2
  exit 1
fi

echo "OK: SDK independence check passed"
