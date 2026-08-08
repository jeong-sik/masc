#!/bin/sh
set -eu

manifest=${1:?coverage test manifest is required}

if [ ! -s "$manifest" ]; then
  echo "coverage test manifest is empty: $manifest" >&2
  exit 1
fi

emit_names() {
  while IFS= read -r name || [ -n "$name" ]; do
    case "$name" in
      test_[a-z0-9_]*) printf '  %s\n' "$name" ;;
      *)
        echo "invalid coverage test name: $name" >&2
        exit 1
        ;;
    esac
  done < "$manifest"
}

printf '(tests\n (names\n'
emit_names
printf ' )\n (modules\n'
emit_names
printf ' )\n (libraries masc_test_deps))\n'
