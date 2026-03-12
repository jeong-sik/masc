#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT"

SKIP_BUILD=0
JSON_OUT=""
BASELINE_FILE=".ci/health-baseline.json"
BASELINE_REF=""
FAIL_ON_LIB_REGRESSION=0

usage() {
  cat <<'EOF'
Usage: scripts/health_snapshot.sh [options]

Options:
  --skip-build                 Skip `dune build @check`
  --json-out <path>            Write machine-readable JSON snapshot
  --baseline-file <path>       Baseline JSON file (default: .ci/health-baseline.json)
  --baseline-ref <git-ref>     Read the baseline file from a git ref
  --fail-on-lib-regression     Exit non-zero when lib counts exceed baseline
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
    --fail-on-lib-regression)
      FAIL_ON_LIB_REGRESSION=1
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

count_pattern() {
  local dir="$1"
  local pattern="$2"
  local total
  total="$(rg -c "$pattern" "$dir" -g '*.{ml,mli}' 2>/dev/null | awk -F: '{s+=$2} END {print s+0}')"
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
    if git show "${BASELINE_REF}:${BASELINE_FILE}" 2>/dev/null; then
      return 0
    fi
  fi

  if [ -f "$BASELINE_FILE" ]; then
    cat "$BASELINE_FILE"
  else
    printf ''
  fi
}

echo "=== Health Snapshot ==="
if [ "$SKIP_BUILD" -eq 0 ]; then
  echo "Running dune build --root . @check"
  dune build --root . @check
else
  echo "Skipping dune build --root . @check"
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

lib_failwith="$(count_pattern lib 'failwith')"
lib_list_hd="$(count_pattern lib 'List\.hd')"
lib_list_tl="$(count_pattern lib 'List\.tl')"
lib_option_get="$(count_pattern lib 'Option\.get')"
lib_obj_magic="$(count_pattern lib 'Obj\.magic')"

test_failwith="$(count_pattern test 'failwith')"
test_list_hd="$(count_pattern test 'List\.hd')"
test_list_tl="$(count_pattern test 'List\.tl')"
test_option_get="$(count_pattern test 'Option\.get')"
test_obj_magic="$(count_pattern test 'Obj\.magic')"

ratchet_status="disabled"
ratchet_message="baseline check not requested"
if [ "$FAIL_ON_LIB_REGRESSION" -eq 1 ]; then
  baseline_content="$(load_baseline_content)"
  if [ -z "$baseline_content" ]; then
    echo "ERROR: baseline file not found: $BASELINE_FILE" >&2
    exit 2
  fi

  baseline_lib_failwith="$(extract_baseline_value "$baseline_content" "lib_failwith")"
  baseline_lib_list_hd="$(extract_baseline_value "$baseline_content" "lib_list_hd")"
  baseline_lib_list_tl="$(extract_baseline_value "$baseline_content" "lib_list_tl")"
  baseline_lib_option_get="$(extract_baseline_value "$baseline_content" "lib_option_get")"
  baseline_lib_obj_magic="$(extract_baseline_value "$baseline_content" "lib_obj_magic")"

  regressions=()
  [ "$lib_failwith" -gt "$baseline_lib_failwith" ] && regressions+=("lib_failwith ${baseline_lib_failwith}->${lib_failwith}")
  [ "$lib_list_hd" -gt "$baseline_lib_list_hd" ] && regressions+=("lib_list_hd ${baseline_lib_list_hd}->${lib_list_hd}")
  [ "$lib_list_tl" -gt "$baseline_lib_list_tl" ] && regressions+=("lib_list_tl ${baseline_lib_list_tl}->${lib_list_tl}")
  [ "$lib_option_get" -gt "$baseline_lib_option_get" ] && regressions+=("lib_option_get ${baseline_lib_option_get}->${lib_option_get}")
  [ "$lib_obj_magic" -gt "$baseline_lib_obj_magic" ] && regressions+=("lib_obj_magic ${baseline_lib_obj_magic}->${lib_obj_magic}")

  if [ "${#regressions[@]}" -eq 0 ]; then
    ratchet_status="pass"
    ratchet_message="no lib regressions"
  else
    ratchet_status="fail"
    ratchet_message="$(printf '%s; ' "${regressions[@]}")"
    ratchet_message="${ratchet_message%; }"
  fi
fi

echo ""
echo "Branch: $branch"
echo "HEAD:   $head_sha"
echo "At:     $now_iso"
echo ""
echo "Anti-fake: status=${anti_fake_label} good=${anti_fake_good} suspect=${anti_fake_suspect} fake=${anti_fake_fake} total=${anti_fake_total}"
echo "Unsafe patterns (lib):  failwith=${lib_failwith} list_hd=${lib_list_hd} list_tl=${lib_list_tl} option_get=${lib_option_get} obj_magic=${lib_obj_magic}"
echo "Unsafe patterns (test): failwith=${test_failwith} list_hd=${test_list_hd} list_tl=${test_list_tl} option_get=${test_option_get} obj_magic=${test_obj_magic}"
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
    "test_obj_magic": ${test_obj_magic}
  },
  "ratchet": {
    "status": "${ratchet_status}",
    "message": "${ratchet_message}"
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
    echo ""
    echo "| Surface | failwith | List.hd | List.tl | Option.get | Obj.magic |"
    echo "|---|---:|---:|---:|---:|---:|"
    echo "| lib | $lib_failwith | $lib_list_hd | $lib_list_tl | $lib_option_get | $lib_obj_magic |"
    echo "| test | $test_failwith | $test_list_hd | $test_list_tl | $test_option_get | $test_obj_magic |"
    echo ""
    echo "- Anti-fake: \`$anti_fake_label\` (good=$anti_fake_good suspect=$anti_fake_suspect fake=$anti_fake_fake total=$anti_fake_total)"
    echo "- Ratchet: \`$ratchet_status\` ($ratchet_message)"
  } >> "$GITHUB_STEP_SUMMARY"
fi

if [ "$FAIL_ON_LIB_REGRESSION" -eq 1 ] && [ "$ratchet_status" = "fail" ]; then
  exit 1
fi
