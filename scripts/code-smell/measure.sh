#!/usr/bin/env bash
# RFC-0151 code-smell monotone ratchet.
#
# This is a trend gate, not a cleanup codemod: each strict metric must stay at
# or below the committed baseline in ci/code-smell-baseline.json.
#
# Usage:
#   scripts/code-smell/measure.sh              # print + enforce baseline
#   scripts/code-smell/measure.sh --print      # print current/baseline only
#   scripts/code-smell/measure.sh --regenerate # rewrite baseline from current

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
BASELINE_FILE="${REPO_ROOT}/ci/code-smell-baseline.json"
IGNORE_LINT="${REPO_ROOT}/scripts/lint-ignore-without-comment.sh"

for tool in rg python3 awk find wc; do
  command -v "$tool" >/dev/null 2>&1 || {
    echo "[code-smell-ratchet] required tool missing: $tool" >&2
    exit 1
  }
done

cd "$REPO_ROOT"

count_godfiles() {
  find lib -type f -name '*.ml' \
    -not -name '*_intf.ml' \
    -not -name '*_test.ml' \
    -not -path '*/_build/*' 2>/dev/null \
    | while IFS= read -r file; do
        lines=$(wc -l < "$file")
        if [[ "$lines" -ge 1000 ]]; then
          printf '%s\n' "$file"
        fi
      done \
    | wc -l \
    | tr -d ' '
}

count_catch_all_arms() {
  ( set +o pipefail
    rg -c '^\s*\| _ -> ' --glob 'lib/**/*.ml' --glob '!lib/**/test/**' lib 2>/dev/null \
      | awk -F: '{s+=$NF} END {print s+0}'
  )
}

count_contains_substring_defs() {
  ( set +o pipefail
    rg -nP '^\s*let\s+(rec\s+)?[a-zA-Z0-9_]*\s+[^=]*=\s*.*\b(String\.(starts_with|ends_with|contains)|Astring\.(is_prefix|is_infix|is_suffix)|Astring\.String\.(is_prefix|is_infix|is_suffix))\b' \
      --glob 'lib/**/*.ml' --glob '!lib/**/test/**' lib 2>/dev/null \
      | wc -l \
      | tr -d ' '
  )
}

count_ignore_no_comment() {
  if [[ ! -x "${IGNORE_LINT}" ]]; then
    echo "[code-smell-ratchet] missing scripts/lint-ignore-without-comment.sh" >&2
    exit 1
  fi
  bash "${IGNORE_LINT}" --target lib 2>/dev/null \
    | wc -l \
    | tr -d ' '
}

metric_file_breakdown() {
  case "$1" in
    godfile_loc_1000plus)
      find lib -type f -name '*.ml' \
        -not -name '*_intf.ml' \
        -not -name '*_test.ml' \
        -not -path '*/_build/*' 2>/dev/null \
        | while IFS= read -r file; do
            lines=$(wc -l < "$file")
            if [[ "$lines" -ge 1000 ]]; then
              printf '%s\t%s\n' "$file" "$lines"
            fi
          done \
        | sort
      ;;
    catch_all_arms)
      ( set +o pipefail
        rg -n '^\s*\| _ -> ' --glob 'lib/**/*.ml' --glob '!lib/**/test/**' lib 2>/dev/null \
          | cut -d: -f1 \
          | sort \
          | uniq -c \
          | awk '{count=$1; $1=""; sub(/^ /, ""); printf "%s\t%s\n", $0, count}'
      )
      ;;
    contains_substring_defs)
      ( set +o pipefail
        rg -nP '^\s*let\s+(rec\s+)?[a-zA-Z0-9_]*\s+[^=]*=\s*.*\b(String\.(starts_with|ends_with|contains)|Astring\.(is_prefix|is_infix|is_suffix)|Astring\.String\.(is_prefix|is_infix|is_suffix))\b' \
          --glob 'lib/**/*.ml' --glob '!lib/**/test/**' lib 2>/dev/null \
          | cut -d: -f1 \
          | sort \
          | uniq -c \
          | awk '{count=$1; $1=""; sub(/^ /, ""); printf "%s\t%s\n", $0, count}'
      )
      ;;
    ignore_no_comment)
      bash "${IGNORE_LINT}" --target lib 2>/dev/null \
        | cut -d: -f1 \
        | sort \
        | uniq -c \
        | awk '{count=$1; $1=""; sub(/^ /, ""); printf "%s\t%s\n", $0, count}'
      ;;
    *) echo "unknown metric: $1" >&2; exit 1 ;;
  esac
}

current_value() {
  case "$1" in
    godfile_loc_1000plus) count_godfiles ;;
    catch_all_arms) count_catch_all_arms ;;
    contains_substring_defs) count_contains_substring_defs ;;
    ignore_no_comment) count_ignore_no_comment ;;
    *) echo "unknown metric: $1" >&2; exit 1 ;;
  esac
}

baseline_value() {
  local name="$1"
  if [[ ! -f "$BASELINE_FILE" ]]; then
    echo "[code-smell-ratchet] missing baseline: $BASELINE_FILE" >&2
    exit 1
  fi
  python3 - "$BASELINE_FILE" "$name" <<'PYEOF'
import json
import sys

path, name = sys.argv[1], sys.argv[2]
with open(path) as f:
    data = json.load(f)
metric = data.get("metrics", {}).get(name)
if metric is None:
    raise SystemExit(f"missing metric in baseline: {name}")
print(int(metric["baseline"]))
PYEOF
}

metrics=(
  godfile_loc_1000plus
  catch_all_arms
  contains_substring_defs
  ignore_no_comment
)

print_counts() {
  printf "%-30s %9s  %9s\n" "metric" "current" "baseline"
  echo "--------------------------------------------------------"
  local name current baseline
  for name in "${metrics[@]}"; do
    current=$(current_value "$name")
    baseline=$(baseline_value "$name")
    printf "%-30s %9d  %9d\n" "$name" "$current" "$baseline"
  done
}

regenerate() {
  local god catch substr ignore
  god=$(count_godfiles)
  catch=$(count_catch_all_arms)
  substr=$(count_contains_substring_defs)
  ignore=$(count_ignore_no_comment)
  local tmpdir
  tmpdir="$(mktemp -d)"
  metric_file_breakdown godfile_loc_1000plus > "${tmpdir}/godfile_loc_1000plus.tsv"
  metric_file_breakdown catch_all_arms > "${tmpdir}/catch_all_arms.tsv"
  metric_file_breakdown contains_substring_defs > "${tmpdir}/contains_substring_defs.tsv"
  metric_file_breakdown ignore_no_comment > "${tmpdir}/ignore_no_comment.tsv"
  if ! python3 - "$BASELINE_FILE" "$tmpdir" "$god" "$catch" "$substr" "$ignore" <<'PYEOF'
import json
import sys
from pathlib import Path

path = Path(sys.argv[1])
tmpdir = Path(sys.argv[2])
god, catch, substr, ignore = map(int, sys.argv[3:])

def files_for(metric):
    rows = []
    tsv = tmpdir / f"{metric}.tsv"
    if not tsv.exists():
        return rows
    for line in tsv.read_text().splitlines():
        if not line.strip():
            continue
        file, value = line.rsplit("\t", 1)
        rows.append({"file": file, "value": int(value)})
    return rows

data = {
    "_comment": "RFC-0151 code-smell monotone ratchet baseline. Regenerate with scripts/code-smell/measure.sh --regenerate.",
    "_policy": "Current metric values must be <= baseline. Decreases should be committed as baseline updates.",
    "metrics": {
        "godfile_loc_1000plus": {
            "baseline": god,
            "scope": "lib/**/*.ml excluding *_intf.ml, *_test.ml, _build; LoC >= 1000",
            "files": files_for("godfile_loc_1000plus"),
        },
        "catch_all_arms": {
            "baseline": catch,
            "scope": "line-leading OCaml anonymous match arms: | _ ->",
            "files": files_for("catch_all_arms"),
        },
        "contains_substring_defs": {
            "baseline": substr,
            "scope": "let definitions using String/Astring substring/prefix/suffix helpers",
            "files": files_for("contains_substring_defs"),
        },
        "ignore_no_comment": {
            "baseline": ignore,
            "scope": "scripts/lint-ignore-without-comment.sh --target lib",
            "files": files_for("ignore_no_comment"),
        },
    },
}
path.parent.mkdir(parents=True, exist_ok=True)
path.write_text(json.dumps(data, indent=2) + "\n")
print(f"[code-smell-ratchet] wrote {path}")
PYEOF
  then
    status=$?
    rm -rf "$tmpdir"
    return "$status"
  fi
  rm -rf "$tmpdir"
}

check() {
  local drift=0
  local name current baseline
  for name in "${metrics[@]}"; do
    current=$(current_value "$name")
    baseline=$(baseline_value "$name")
    if (( current > baseline )); then
      echo "[code-smell-ratchet] DRIFT UP: ${name} current=${current} baseline=${baseline}" >&2
      drift=1
    fi
  done
  return "$drift"
}

case "${1:-}" in
  --print)
    print_counts
    ;;
  --regenerate)
    regenerate
    ;;
  "")
    print_counts
    if check; then
      echo
      echo "[code-smell-ratchet] OK"
      exit 0
    else
      echo
      echo "[code-smell-ratchet] FAIL - current exceeds baseline" >&2
      echo "  If the increase is intentional, cite RFC-0151 and commit the" >&2
      echo "  paired baseline update with an explicit RATCHET-WAIVED note." >&2
      exit 2
    fi
    ;;
  *)
    echo "usage: $0 [--print | --regenerate]" >&2
    exit 1
    ;;
esac
