#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT"

JSON_OUT=""

usage() {
  cat <<'EOF'
Usage: scripts/ocaml-north-star-health.sh [options]

Options:
  --json-out <path>  Write the observational snapshot as JSON.
  -h, --help         Show this help.

This check is warn-only by design. It reports OCaml north-star risk-pattern
counts without changing CI pass/fail policy.
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --json-out)
      JSON_OUT="${2:-}"
      if [ -z "$JSON_OUT" ]; then
        echo "ERROR: --json-out requires a path" >&2
        exit 2
      fi
      shift 2
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

count_pattern() {
  local scope="$1"
  local pattern="$2"
  rg -n "$pattern" $scope -g '*.{ml,mli}' 2>/dev/null | awk 'END {print NR+0}'
}

count_prod() {
  count_pattern "lib bin" "$1"
}

count_all() {
  count_pattern "lib bin test" "$1"
}

now_iso="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
branch="$(git rev-parse --abbrev-ref HEAD)"
head_sha="$(git rev-parse HEAD)"

prod_failwith="$(count_prod 'failwith')"
prod_invalid_arg="$(count_prod 'invalid_arg')"
prod_assert_false="$(count_prod 'assert false')"
prod_obj_magic="$(count_prod 'Obj\.magic')"
prod_sys_command="$(count_prod 'Sys\.command')"
prod_unix_process="$(count_prod 'Unix\.create_process|Unix\.create_process_env|Unix\.waitpid')"
prod_manual_mutex="$(count_prod 'Mutex\.(lock|unlock)')"
prod_fun_protect="$(count_prod 'Fun\.protect')"
prod_broad_catch="$(count_prod 'with[[:space:]]+_')"
prod_yojson_util="$(count_prod 'Yojson\.Safe\.Util')"

all_failwith="$(count_all 'failwith')"
all_assert_false="$(count_all 'assert false')"
all_obj_magic="$(count_all 'Obj\.magic')"

cat <<EOF
=== OCaml North Star Health (warn-only) ===
checked_at: $now_iso
branch: $branch
head: $head_sha

Production scope: lib bin
  failwith: $prod_failwith
  invalid_arg: $prod_invalid_arg
  assert false: $prod_assert_false
  Obj.magic: $prod_obj_magic
  Sys.command: $prod_sys_command
  Unix process primitives: $prod_unix_process
  manual Mutex.lock/unlock: $prod_manual_mutex
  Fun.protect: $prod_fun_protect
  broad catch (with _): $prod_broad_catch
  Yojson.Safe.Util: $prod_yojson_util

All OCaml scope: lib bin test
  failwith: $all_failwith
  assert false: $all_assert_false
  Obj.magic: $all_obj_magic

status: warn-only; no CI failure policy is applied.
EOF

if [ -n "$JSON_OUT" ]; then
  mkdir -p "$(dirname "$JSON_OUT")"
  cat > "$JSON_OUT" <<EOF
{
  "checked_at": "$now_iso",
  "branch": "$branch",
  "head": "$head_sha",
  "mode": "warn_only",
  "counts": {
    "prod_failwith": $prod_failwith,
    "prod_invalid_arg": $prod_invalid_arg,
    "prod_assert_false": $prod_assert_false,
    "prod_obj_magic": $prod_obj_magic,
    "prod_sys_command": $prod_sys_command,
    "prod_unix_process": $prod_unix_process,
    "prod_manual_mutex": $prod_manual_mutex,
    "prod_fun_protect": $prod_fun_protect,
    "prod_broad_catch": $prod_broad_catch,
    "prod_yojson_util": $prod_yojson_util,
    "all_failwith": $all_failwith,
    "all_assert_false": $all_assert_false,
    "all_obj_magic": $all_obj_magic
  }
}
EOF
  echo "JSON snapshot: $JSON_OUT"
fi
