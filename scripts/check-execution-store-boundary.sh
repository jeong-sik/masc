#!/usr/bin/env bash
set -euo pipefail

repo_root="$(git rev-parse --show-toplevel)"
cd "$repo_root"

source_list="$(mktemp)"
trap 'rm -f "$source_list"' EXIT
find lib -type f \( -name '*.ml' -o -name '*.mli' \) -print \
  | LC_ALL=C sort >"$source_list"

failed=0
while IFS= read -r source; do
  case "$source" in
    lib/execution_event_store.ml | lib/execution_event_store.mli | \
      lib/execution_journal.ml | lib/execution_journal.mli)
      continue
      ;;
  esac

  dependencies="$(ocamldep -modules "$source")"
  for dependency in ${dependencies#*:}; do
    if [[ "$dependency" == "Execution_event_store" ]]; then
      printf '%s\n' \
        "execution store boundary violation: $source depends on Execution_event_store" \
        >&2
      failed=1
    fi
  done
done <"$source_list"

if ((failed != 0)); then
  printf '%s\n' \
    'Execution_journal must remain the sole production owner of the durable store.' \
    >&2
  exit 1
fi

printf '%s\n' 'execution store boundary: journal is the sole production owner'
