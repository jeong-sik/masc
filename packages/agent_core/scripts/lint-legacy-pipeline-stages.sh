#!/usr/bin/env bash
# Forbid reintroducing the retired pre-Pipeline stage modules.
#
# These files were loadable through lib/dune's include_subdirs=unqualified even
# after the authoritative turn path moved into Pipeline plus
# Pipeline_stage_prepare / Pipeline_stage_route.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT"

legacy_files=(
  lib/pipeline/stage_input.ml
  lib/pipeline/stage_parse.ml
  lib/pipeline/stage_route.ml
  lib/pipeline/stage_collect.ml
  lib/pipeline/stage_execute.ml
  lib/pipeline/stage_output.ml
)

missing=0
for path in "${legacy_files[@]}"; do
  if [ -e "$path" ]; then
    echo "legacy pipeline stage file still exists: $path" >&2
    missing=1
  fi
done

# Scope the scan to OCaml sources only. A legacy *module* reference
# (Stage_execute.foo / open Stage_execute) can only exist in .ml/.mli; once the
# files above are gone such a reference is an unbound-module compile error that
# Build & Test catches. Scanning docs/README matched prose that merely describes
# the pipeline (e.g. an audit doc saying "Stage_execute takes a Nonempty.t"),
# producing false positives that blocked legitimate documentation. The nonexistent
# `bin` path also emitted a spurious "No such file or directory" each run.
pattern='\bStage_(input|parse|route|collect|execute|output)\b'
if command -v rg >/dev/null 2>&1; then
  matches="$(rg --no-heading -n -g '*.ml' -g '*.mli' -- "$pattern" lib test || true)"
else
  matches="$(grep -RnE --include='*.ml' --include='*.mli' -- "$pattern" lib test 2>/dev/null || true)"
fi

if [ -n "$matches" ]; then
  echo "legacy pipeline stage module references found:" >&2
  echo "$matches" >&2
  missing=1
fi

if [ "$missing" -ne 0 ]; then
  exit 1
fi

echo "legacy pipeline stage lint passed"
