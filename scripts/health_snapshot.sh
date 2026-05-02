#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT"

SKIP_BUILD=0
JSON_OUT=""
BASELINE_FILE=".ci/health-baseline.json"
BASELINE_REF=""
CHANGED_REF=""
FAIL_ON_LIB_REGRESSION=0
FAIL_ON_ML_LINE_CAP_REGRESSION=0

usage() {
  cat <<'EOF'
Usage: scripts/health_snapshot.sh [options]

Options:
  --skip-build                 Skip `dune build @check`
  --json-out <path>            Write machine-readable JSON snapshot
  --baseline-file <path>       Baseline JSON file (default: .ci/health-baseline.json)
  --baseline-ref <git-ref>     Read the baseline file from a git ref
  --changed-ref <git-ref>      Read changed-file scope from a git ref
  --fail-on-lib-regression     Exit non-zero when lib counts exceed baseline
  --fail-on-ml-line-cap-regression
                               Exit non-zero when .ml line-cap regresses
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --skip-build)
      SKIP_BUILD=1
      shift
      ;;
    --json-out)
      JSON_OUT="${2:-}"
      shift 2
      ;;
    --baseline-file)
      BASELINE_FILE="${2:-}"
      shift 2
      ;;
    --baseline-ref)
      BASELINE_REF="${2:-}"
      shift 2
      ;;
    --changed-ref)
      CHANGED_REF="${2:-}"
      shift 2
      ;;
    --fail-on-lib-regression)
      FAIL_ON_LIB_REGRESSION=1
      shift
      ;;
    --fail-on-ml-line-cap-regression)
      FAIL_ON_ML_LINE_CAP_REGRESSION=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if ! command -v rg >/dev/null 2>&1; then
  echo "ERROR: ripgrep (rg) is required" >&2
  exit 2
fi

now_iso="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
branch="$(git rev-parse --abbrev-ref HEAD)"
head_sha="$(git rev-parse HEAD)"
baseline_source="none"
baseline_ref_used=""
baseline_file_used="$BASELINE_FILE"
BASELINE_CONTENT=""
BASELINE_TMP=""

cleanup() {
  if [ -n "$BASELINE_TMP" ]; then
    rm -rf "$BASELINE_TMP"
  fi
}
trap cleanup EXIT

count_pattern() {
  local dir="$1"
  local pattern="$2"
  local total
  total="$(rg -c "$pattern" "$dir" -g '*.{ml,mli}' 2>/dev/null | awk -F: '{s+=$2} END {print s+0}')"
  printf '%s' "${total:-0}"
}

count_pattern_pcre() {
  local dir="$1"
  local pattern="$2"
  local total
  total="$(
    rg -n -P "$pattern" "$dir" -g '*.{ml,mli}' 2>/dev/null \
      | awk 'END {print NR+0}'
  )"
  printf '%s' "${total:-0}"
}

extract_baseline_value() {
  local content="$1"
  local key="$2"
  local value
  value="$(printf '%s\n' "$content" | grep -E "\"${key}\"[[:space:]]*:" | head -1 | sed -E 's/.*:[[:space:]]*([0-9]+).*/\1/')"
  printf '%s' "${value:-0}"
}

load_baseline_content() {
  if [ -n "$BASELINE_REF" ]; then
    local ref_content
    ref_content="$(git show "${BASELINE_REF}:${BASELINE_FILE}" 2>/dev/null || true)"
    if [ -n "$ref_content" ]; then
      baseline_source="git_ref"
      baseline_ref_used="$BASELINE_REF"
      BASELINE_CONTENT="$ref_content"
      return 0
    fi
  fi

  if [ -f "$BASELINE_FILE" ]; then
    baseline_source="file"
    BASELINE_CONTENT="$(cat "$BASELINE_FILE")"
  else
    BASELINE_CONTENT=""
  fi
}

load_baseline_ref_counts() {
  BASELINE_TMP="$(mktemp -d)"
  if ! git archive "$BASELINE_REF" -- lib | tar -x -C "$BASELINE_TMP"; then
    echo "ERROR: unable to read baseline ref: $BASELINE_REF" >&2
    exit 2
  fi

  baseline_source="git_ref_scan"
  baseline_ref_used="$BASELINE_REF"
  baseline_lib_failwith="$(count_pattern "$BASELINE_TMP/lib" 'failwith')"
  baseline_lib_list_hd="$(count_pattern "$BASELINE_TMP/lib" 'List\.hd')"
  baseline_lib_list_tl="$(count_pattern "$BASELINE_TMP/lib" 'List\.tl')"
  baseline_lib_option_get="$(count_pattern "$BASELINE_TMP/lib" 'Option\.get')"
  baseline_lib_obj_magic="$(count_pattern_pcre "$BASELINE_TMP/lib" '^(?:[^"\n]*"[^"\n]*")*[^"\n]*\bObj\.magic\b')"
}

extract_json_int() {
  local json_file="$1"
  local key="$2"
  python3 - "$json_file" "$key" <<'PY'
import json
import sys

path, key = sys.argv[1], sys.argv[2]
with open(path) as handle:
    data = json.load(handle)
print(int(data["counts"][key]))
PY
}

extract_json_field() {
  local json_file="$1"
  local section="$2"
  local field="$3"
  python3 - "$json_file" "$section" "$field" <<'PY'
import json
import sys

path, section, field = sys.argv[1], sys.argv[2], sys.argv[3]
with open(path) as handle:
    data = json.load(handle)
node = data[section]
print(node[field])
PY
}

# Read a top-level integer field from a JSON file (no section nesting).
extract_json_top_int() {
  local json_file="$1"
  local key="$2"
  python3 - "$json_file" "$key" <<'PY'
import json
import sys

path, key = sys.argv[1], sys.argv[2]
with open(path) as handle:
    data = json.load(handle)
print(int(data[key]))
PY
}

echo "=== Health Snapshot ==="
if [ "$SKIP_BUILD" -eq 0 ]; then
  echo "Running scripts/dune-local.sh build @check"
  scripts/dune-local.sh build @check
else
  echo "Skipping scripts/dune-local.sh build @check"
fi

anti_fake_output=""
anti_fake_status=0
set +e
anti_fake_output="$(bash scripts/anti-fake-audit.sh 2>&1)"
anti_fake_status=$?
set -e

anti_fake_good="$(printf '%s\n' "$anti_fake_output" | awk '/^  Good:/ {print $2}')"
anti_fake_suspect="$(printf '%s\n' "$anti_fake_output" | awk '/^  Suspect:/ {print $2}')"
anti_fake_fake="$(printf '%s\n' "$anti_fake_output" | awk '/^  Fake:/ {print $2}')"
anti_fake_total="$(printf '%s\n' "$anti_fake_output" | awk '/^  Total:/ {print $2}')"

anti_fake_good="${anti_fake_good:-0}"
anti_fake_suspect="${anti_fake_suspect:-0}"
anti_fake_fake="${anti_fake_fake:-0}"
anti_fake_total="${anti_fake_total:-0}"

case "$anti_fake_status" in
  0) anti_fake_label="pass" ;;
  1) anti_fake_label="findings" ;;
  *)
    printf '%s\n' "$anti_fake_output" >&2
    echo "ERROR: anti-fake audit failed unexpectedly" >&2
    exit "$anti_fake_status"
    ;;
esac

base_policy_json="$(mktemp)"
base_policy_cmd=(
  bash
  scripts/base-policy-audit.sh
  --json-out "$base_policy_json"
  --baseline-file "$BASELINE_FILE"
)
if [ -n "$BASELINE_REF" ]; then
  base_policy_cmd+=(--baseline-ref "$BASELINE_REF")
fi
"${base_policy_cmd[@]}"

mli_open_base="$(extract_json_top_int "$base_policy_json" "mli_open_base")"
ml_base_stdlib_shadow="$(extract_json_top_int "$base_policy_json" "ml_base_stdlib_shadow")"
baseline_mli_open_base="$(extract_json_field "$base_policy_json" baseline mli_open_base)"
baseline_ml_base_stdlib_shadow="$(extract_json_field "$base_policy_json" baseline ml_base_stdlib_shadow)"
rm -f "$base_policy_json"

lib_failwith="$(count_pattern lib 'failwith')"
lib_list_hd="$(count_pattern lib 'List\.hd')"
lib_list_tl="$(count_pattern lib 'List\.tl')"
lib_option_get="$(count_pattern lib 'Option\.get')"
lib_obj_magic="$(count_pattern_pcre lib '^(?:[^"\n]*"[^"\n]*")*[^"\n]*\bObj\.magic\b')"

test_failwith="$(count_pattern test 'failwith')"
test_list_hd="$(count_pattern test 'List\.hd')"
test_list_tl="$(count_pattern test 'List\.tl')"
test_option_get="$(count_pattern test 'Option\.get')"
test_obj_magic="$(count_pattern_pcre test '^(?:[^"\n]*"[^"\n]*")*[^"\n]*\bObj\.magic\b')"

ml_line_cap_json="$(mktemp)"
ml_line_cap_cmd=(
  bash
  scripts/ml_line_cap_audit.sh
  --json-out "$ml_line_cap_json"
  --baseline-file "$BASELINE_FILE"
  --exceptions-file .ci/ml-line-cap-exceptions.txt
)
if [ -n "$BASELINE_REF" ]; then
  ml_line_cap_cmd+=(--baseline-ref "$BASELINE_REF")
fi
if [ -n "$CHANGED_REF" ]; then
  ml_line_cap_cmd+=(--changed-ref "$CHANGED_REF" --fail-on-changed-violations)
fi
if [ "$FAIL_ON_ML_LINE_CAP_REGRESSION" -eq 1 ]; then
  ml_line_cap_cmd+=(--fail-on-regression)
fi
"${ml_line_cap_cmd[@]}"

manual_ml_over_500="$(extract_json_int "$ml_line_cap_json" "manual_ml_over_500")"
excepted_ml_over_500="$(extract_json_int "$ml_line_cap_json" "excepted_ml_over_500")"
lib_ml_over_500="$(extract_json_int "$ml_line_cap_json" "lib_ml_over_500")"
bin_ml_over_500="$(extract_json_int "$ml_line_cap_json" "bin_ml_over_500")"
test_ml_over_500="$(extract_json_int "$ml_line_cap_json" "test_ml_over_500")"
examples_ml_over_500="$(extract_json_int "$ml_line_cap_json" "examples_ml_over_500")"
ml_line_cap_status="$(extract_json_field "$ml_line_cap_json" baseline status)"
ml_line_cap_message="$(extract_json_field "$ml_line_cap_json" baseline message)"
ml_line_cap_changed_status="$(extract_json_field "$ml_line_cap_json" changed status)"
ml_line_cap_changed_message="$(extract_json_field "$ml_line_cap_json" changed message)"

ratchet_status="disabled"
ratchet_message="baseline check not requested"
regressions=()
baseline_lib_failwith=0
baseline_lib_list_hd=0
baseline_lib_list_tl=0
baseline_lib_option_get=0
baseline_lib_obj_magic=0
if [ "$FAIL_ON_LIB_REGRESSION" -eq 1 ]; then
  if [ -n "$BASELINE_REF" ]; then
    load_baseline_ref_counts
  else
    load_baseline_content
    baseline_content="$BASELINE_CONTENT"
    if [ -z "$baseline_content" ]; then
      echo "ERROR: baseline file not found: $BASELINE_FILE" >&2
      exit 2
    fi

    baseline_lib_failwith="$(extract_baseline_value "$baseline_content" "lib_failwith")"
    baseline_lib_list_hd="$(extract_baseline_value "$baseline_content" "lib_list_hd")"
    baseline_lib_list_tl="$(extract_baseline_value "$baseline_content" "lib_list_tl")"
    baseline_lib_option_get="$(extract_baseline_value "$baseline_content" "lib_option_get")"
    baseline_lib_obj_magic="$(extract_baseline_value "$baseline_content" "lib_obj_magic")"
  fi

  [ "$lib_failwith" -gt "$baseline_lib_failwith" ] && regressions+=("lib_failwith ${baseline_lib_failwith}->${lib_failwith}")
  [ "$lib_list_hd" -gt "$baseline_lib_list_hd" ] && regressions+=("lib_list_hd ${baseline_lib_list_hd}->${lib_list_hd}")
  [ "$lib_list_tl" -gt "$baseline_lib_list_tl" ] && regressions+=("lib_list_tl ${baseline_lib_list_tl}->${lib_list_tl}")
  [ "$lib_option_get" -gt "$baseline_lib_option_get" ] && regressions+=("lib_option_get ${baseline_lib_option_get}->${lib_option_get}")
  [ "$lib_obj_magic" -gt "$baseline_lib_obj_magic" ] && regressions+=("lib_obj_magic ${baseline_lib_obj_magic}->${lib_obj_magic}")
  [ "$mli_open_base" -gt "$baseline_mli_open_base" ] && regressions+=("mli_open_base ${baseline_mli_open_base}->${mli_open_base}")
  [ "$ml_base_stdlib_shadow" -gt "$baseline_ml_base_stdlib_shadow" ] && regressions+=("ml_base_stdlib_shadow ${baseline_ml_base_stdlib_shadow}->${ml_base_stdlib_shadow}")

  if [ "${#regressions[@]}" -eq 0 ]; then
    ratchet_status="pass"
    ratchet_message="no lib regressions"
  else
    ratchet_status="fail"
    ratchet_message="$(printf '%s; ' "${regressions[@]}")"
    ratchet_message="${ratchet_message%; }"
  fi
fi

baseline_label="disabled"
if [ "$baseline_source" = "git_ref_scan" ]; then
  baseline_label="ref-scan:${baseline_ref_used}:lib"
elif [ "$baseline_source" = "git_ref" ]; then
  baseline_label="ref:${baseline_ref_used}:${baseline_file_used}"
elif [ "$baseline_source" = "file" ]; then
  baseline_label="file:${baseline_file_used}"
fi

regressions_json="[]"
if [ "${#regressions[@]}" -gt 0 ]; then
  regressions_json="["
  for item in "${regressions[@]}"; do
    if [ "$regressions_json" != "[" ]; then
      regressions_json="${regressions_json}, "
    fi
    regressions_json="${regressions_json}\"${item}\""
  done
  regressions_json="${regressions_json}]"
fi

echo ""
echo "Branch: $branch"
echo "HEAD:   $head_sha"
echo "At:     $now_iso"
echo ""
echo "Baseline: ${baseline_label}"
echo "Anti-fake: status=${anti_fake_label} good=${anti_fake_good} suspect=${anti_fake_suspect} fake=${anti_fake_fake} total=${anti_fake_total}"
echo "Unsafe patterns (lib):  failwith=${lib_failwith} list_hd=${lib_list_hd} list_tl=${lib_list_tl} option_get=${lib_option_get} obj_magic=${lib_obj_magic}"
echo "Unsafe patterns (test): failwith=${test_failwith} list_hd=${test_list_hd} list_tl=${test_list_tl} option_get=${test_option_get} obj_magic=${test_obj_magic}"
echo "Base policy: mli_open_base=${mli_open_base} ml_base_stdlib_shadow=${ml_base_stdlib_shadow}"
echo "ML line cap: manual=${manual_ml_over_500} excepted=${excepted_ml_over_500} lib=${lib_ml_over_500} bin=${bin_ml_over_500} test=${test_ml_over_500} examples=${examples_ml_over_500}"
echo "ML line cap changed: ${ml_line_cap_changed_status} (${ml_line_cap_changed_message})"
echo "ML line cap ratchet: ${ml_line_cap_status} (${ml_line_cap_message})"
echo "Ratchet: ${ratchet_status} (${ratchet_message})"

json_payload="$(cat <<EOF
{
  "generated_at": "${now_iso}",
  "branch": "${branch}",
  "head": "${head_sha}",
  "build": {
    "skipped": ${SKIP_BUILD},
    "status": "pass"
  },
  "anti_fake": {
    "status": "${anti_fake_label}",
    "good": ${anti_fake_good},
    "suspect": ${anti_fake_suspect},
    "fake": ${anti_fake_fake},
    "total": ${anti_fake_total}
  },
  "counts": {
    "lib_failwith": ${lib_failwith},
    "lib_list_hd": ${lib_list_hd},
    "lib_list_tl": ${lib_list_tl},
    "lib_option_get": ${lib_option_get},
    "lib_obj_magic": ${lib_obj_magic},
    "test_failwith": ${test_failwith},
    "test_list_hd": ${test_list_hd},
    "test_list_tl": ${test_list_tl},
    "test_option_get": ${test_option_get},
    "test_obj_magic": ${test_obj_magic},
    "manual_ml_over_500": ${manual_ml_over_500},
    "excepted_ml_over_500": ${excepted_ml_over_500},
    "lib_ml_over_500": ${lib_ml_over_500},
    "bin_ml_over_500": ${bin_ml_over_500},
    "test_ml_over_500": ${test_ml_over_500},
    "examples_ml_over_500": ${examples_ml_over_500},
    "mli_open_base": ${mli_open_base},
    "ml_base_stdlib_shadow": ${ml_base_stdlib_shadow}
  },
  "ml_line_cap": {
    "status": "${ml_line_cap_status}",
    "message": "${ml_line_cap_message}",
    "changed_status": "${ml_line_cap_changed_status}",
    "changed_message": "${ml_line_cap_changed_message}"
  },
  "baseline": {
    "source": "${baseline_source}",
    "ref": "${baseline_ref_used}",
    "file": "${baseline_file_used}",
    "counts": {
      "lib_failwith": ${baseline_lib_failwith},
      "lib_list_hd": ${baseline_lib_list_hd},
      "lib_list_tl": ${baseline_lib_list_tl},
      "lib_option_get": ${baseline_lib_option_get},
      "lib_obj_magic": ${baseline_lib_obj_magic},
      "mli_open_base": ${baseline_mli_open_base},
      "ml_base_stdlib_shadow": ${baseline_ml_base_stdlib_shadow}
    }
  },
  "ratchet": {
    "status": "${ratchet_status}",
    "message": "${ratchet_message}",
    "regressions": ${regressions_json}
  }
}
EOF
)"

if [ -n "$JSON_OUT" ]; then
  mkdir -p "$(dirname "$JSON_OUT")"
  printf '%s\n' "$json_payload" > "$JSON_OUT"
fi

if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
  {
    echo "## Health Snapshot"
    echo ""
    echo "- Branch: \`$branch\`"
    echo "- Head: \`$head_sha\`"
    echo "- Generated: \`$now_iso\`"
    echo "- Baseline: \`$baseline_label\`"
    echo ""
    echo "| Surface | failwith | List.hd | List.tl | Option.get | Obj.magic |"
    echo "|---|---:|---:|---:|---:|---:|"
    echo "| lib | $lib_failwith | $lib_list_hd | $lib_list_tl | $lib_option_get | $lib_obj_magic |"
    echo "| test | $test_failwith | $test_list_hd | $test_list_tl | $test_option_get | $test_obj_magic |"
    if [ "$FAIL_ON_LIB_REGRESSION" -eq 1 ]; then
      echo "| baseline(lib) | $baseline_lib_failwith | $baseline_lib_list_hd | $baseline_lib_list_tl | $baseline_lib_option_get | $baseline_lib_obj_magic |"
    fi
    echo ""
    echo "| Scope | manual >500 | excepted >500 |"
    echo "|---|---:|---:|"
    echo "| all .ml | $manual_ml_over_500 | $excepted_ml_over_500 |"
    echo "| lib | $lib_ml_over_500 | n/a |"
    echo "| bin | $bin_ml_over_500 | n/a |"
    echo "| test | $test_ml_over_500 | n/a |"
    echo "| examples | $examples_ml_over_500 | n/a |"
    echo ""
    echo "- Anti-fake: \`$anti_fake_label\` (good=$anti_fake_good suspect=$anti_fake_suspect fake=$anti_fake_fake total=$anti_fake_total)"
    echo "- Base policy: mli_open_base=\`$mli_open_base\` ml_base_stdlib_shadow=\`$ml_base_stdlib_shadow\`"
    echo "- ML line cap changed: \`$ml_line_cap_changed_status\` ($ml_line_cap_changed_message)"
    echo "- ML line cap ratchet: \`$ml_line_cap_status\` ($ml_line_cap_message)"
    echo "- Ratchet: \`$ratchet_status\` ($ratchet_message)"
    if [ "${#regressions[@]}" -gt 0 ]; then
      echo "- Regressions:"
      for item in "${regressions[@]}"; do
        echo "  - \`${item}\`"
      done
    fi
  } >> "$GITHUB_STEP_SUMMARY"
fi

rm -f "$ml_line_cap_json"

if [ "$FAIL_ON_LIB_REGRESSION" -eq 1 ] && [ "$ratchet_status" = "fail" ]; then
  exit 1
fi
