#!/usr/bin/env bash
# lint-fun-protect.sh — Block bare Fun.protect in lib/ (use Eio_guard.protect instead)
# Exit 1 if any bare Fun.protect found that isn't already Eio_guard.protect

set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

# Files that are allowed to use Fun.protect. See issue #10395.
ALLOWLIST=(
  # ---- The Eio_guard implementation itself ----
  "lib/core/eio_guard.ml"
  "lib/core/eio_guard.mli"

  # ---- Cannot import Eio_guard (layer below masc_core or no masc_core dep) ----
  # Eio_guard lives in [lib/core/eio_guard.ml] (the [masc_core] library).
  # The following libraries either sit *below* masc_core in the dune graph
  # (importing Eio_guard would create a cycle) or do not declare a dependency
  # on masc_core at all. Per-file rationale based on each library's [dune]
  # libraries clause:
  "lib/masc_log/log.ml"             # masc_core depends on masc_log → cycle
  "lib/pulse/pulse.ml"              # deps: masc_config, masc_log (no masc_core)
  "lib/eio_context/eio_context.ml"  # deps: eio, masc_log, tls (no masc_core)
  "lib/dated_jsonl/dated_jsonl.ml"  # deps: fs_compat, eio, yojson (no masc_core)
  "lib/shared_audit/store.ml"       # deps: unix, yojson, digestif (no masc_core)

  # ---- Migratable but deferred ----
  # These libraries transitively depend on masc_core and therefore *can* import
  # Eio_guard. They remain on the allowlist because the migration was deferred
  # to keep PR #10395 scoped. Tracked for follow-up; do not extend this section
  # without an accompanying issue.
  "lib/backend/backend.ml"
  "lib/process/bg_task.ml"
  "lib/process/process_eio.ml"
  "lib/gate/channel_gate_discord_names.ml"
  "lib/gate/channel_gate_imessage_state.ml"
  "lib/gate/channel_gate_discord_state.ml"
  "lib/coord/coord_task_schedule.ml"
  "lib/repo_manager/credential_store.ml"
  "lib/repo_manager/repo_store.ml"
  "lib/repo_manager/credential_materializer.ml"
  "lib/repo_manager/keeper_repo_mapping.ml"
  "lib/cdal_runtime/autonomy_exec.ml"
  "lib/exec/test/test_exec_gate_runtime.ml"
)

count=0
while IFS= read -r line; do
  file=$(echo "$line" | cut -d: -f1)
  linenum=$(echo "$line" | cut -d: -f2)

  # Skip allowlisted files
  for allowed in "${ALLOWLIST[@]}"; do
    if [[ "$file" == "$allowed" ]]; then
      continue 2
    fi
  done

  # Skip .mli files (documentation references only, not executable code)
  if [[ "$file" == *.mli ]]; then
    continue
  fi

  # Skip if it's Eio_guard.protect (already migrated)
  if echo "$line" | grep -q "Eio_guard\.protect"; then
    continue
  fi

  # Skip if it's Stdlib.Fun.protect (explicit stdlib reference in compat modules)
  if echo "$line" | grep -q "Stdlib\.Fun\.protect"; then
    continue
  fi

  # Extract content after file:line prefix
  content=$(echo "$line" | cut -d: -f3-)

  # Skip comment-only lines:
  # - Lines starting with (* (comment block open)
  # - Lines that are inside a comment block: typically indented with * or contain [Fun.protect]
  #   inside prose/documentation context
  # - Lines starting with * (comment continuation)
  # - Lines containing only *) (comment block close)
  trimmed=$(echo "$content" | sed 's/^[[:space:]]*//')
  if [[ "$trimmed" == \(\** ]] || [[ "$trimmed" == \*\)* ]] || [[ "$trimmed" == \** ]]; then
    continue
  fi

  # Heuristic: if the line is inside an OCaml comment block, it's not code.
  # Detect by checking if the context has comment markers.
  # A line containing [Fun.protect ...] in prose (not code) context is inside (* ... *)
  if echo "$content" | grep -qE '\[Fun\.protect[^]]*\]'; then
    continue
  fi

  # Skip if same-line context shows this is inside a comment
  # (text before Fun.protect contains comment characters)
  before_fun=$(echo "$content" | sed 's/Fun\.protect.*//')
  if echo "$before_fun" | grep -qE '\(\*|^\s*\*'; then
    continue
  fi

  # Skip if the line is a prose reference like "the [Fun.protect] finally branch"
  # These appear inside OCaml doc comments and contain natural language before the match
  if echo "$content" | grep -qE '(the|a|its|outer|from) \[Fun\.protect'; then
    continue
  fi

  # Skip prose references without brackets: "Uses Fun.protect for ...", "via Fun.protect to ..."
  # "not Fun.protect", "Release token via Fun.protect"
  if echo "$content" | grep -qE '(Uses|via|not|Release|for cleanup|would be|would wrap) Fun\.protect'; then
    continue
  fi

  # Skip prose references where Fun.protect is followed by bracketed term in prose:
  # "Fun.protect [finally] above", "Fun.protect [finally] in ..."
  if echo "$content" | grep -qE 'Fun\.protect \[[^]]+\] (above|below|in|before|after|to|for|so|still)'; then
    continue
  fi

  # Skip lines ending with *) (inside a closing comment block)
  trimmed_end=$(echo "$trimmed" | sed 's/[[:space:]]*$//')
  if [[ "$trimmed_end" == *'*)' ]]; then
    continue
  fi

  # Skip Stdlib.Mutex lock/unlock patterns (not migration targets —
  # these protect cross-thread shared state, not Eio fiber cleanup)
  # Pattern 1: Mutex.lock/unlock in the same line content
  if echo "$content" | grep -qE "(Stdlib\.)?Mutex\.(un)?lock"; then
    continue
  fi

  # Skip if the finally clause is purely Mutex.unlock (Mutex pattern)
  if echo "$content" | grep -qE "finally.*Mutex\.unlock"; then
    continue
  fi

  # Pattern 2: Check if the NEXT line contains Mutex.unlock in the finally clause
  # (Mutex-protect pattern: Fun.protect on one line, ~finally:(... Mutex.unlock ...) on next)
  nextline=$(sed -n "$((linenum + 1))p" "$file" 2>/dev/null || true)
  if echo "$nextline" | grep -qE "Mutex\.unlock"; then
    continue
  fi

  echo "ERROR: bare Fun.protect found (use Eio_guard.protect instead): $line"
  count=$((count + 1))
done < <(rg "Fun\.protect" lib/ --type ocaml --line-number 2>/dev/null || true)

if [[ $count -gt 0 ]]; then
  echo ""
  echo "Found $count bare Fun.protect usage(s). Replace with Eio_guard.protect."
  echo "See issue #10395 for migration guide."
  exit 1
fi

echo "OK: no bare Fun.protect found in lib/"
exit 0
