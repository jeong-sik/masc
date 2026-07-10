#!/usr/bin/env bash
# Boundary ratchet: counts known MASC/OAS boundary violations.
# Fails if any count exceeds its baseline, preventing new violations.
# Lower baselines as violations are fixed.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
rc=0

check() {
  local label="$1" baseline="$2" pattern="$3" path="$4"
  if [[ ! -e "$REPO_ROOT/$path" ]]; then
    echo "BOUNDARY ERROR: $label — path $path does not exist"
    rc=1
    return
  fi
  local count
  count="$(grep -rn --include='*.ml' --include='*.mli' "$pattern" "$REPO_ROOT/$path" 2>/dev/null | wc -l | tr -d ' ' || true)"
  if [[ "$count" -gt "$baseline" ]]; then
    echo "BOUNDARY FAIL: $label — found $count (baseline $baseline)"
    grep -rn --include='*.ml' --include='*.mli' "$pattern" "$REPO_ROOT/$path" 2>/dev/null | head -5
    rc=1
  elif [[ "$count" -lt "$baseline" ]]; then
    echo "BOUNDARY INFO: $label — found $count (baseline $baseline) — consider lowering baseline"
  fi
}

check_forbidden_outside() {
  local label="$1" pattern="$2" path="$3"
  shift 3
  local allowed=("$@")
  if [[ ! -e "$REPO_ROOT/$path" ]]; then
    echo "BOUNDARY ERROR: $label — path $path does not exist"
    rc=1
    return
  fi
  local hits=()
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    local file="${line%%:*}"
    local allowed_hit=0
    local rel_file="${file#$REPO_ROOT/}"
    for allow in "${allowed[@]}"; do
      if [[ "$rel_file" == "$allow" ]]; then
        allowed_hit=1
        break
      fi
    done
    if [[ "$allowed_hit" -eq 0 ]]; then
      hits+=("$line")
    fi
  done < <(grep -rn --include='*.ml' --include='*.mli' "$pattern" "$REPO_ROOT/$path" 2>/dev/null || true)

  if [[ "${#hits[@]}" -gt 0 ]]; then
    echo "BOUNDARY FAIL: $label — found ${#hits[@]} forbidden match(es)"
    printf '%s\n' "${hits[@]:0:5}"
    rc=1
  else
    echo "BOUNDARY INFO: $label — no forbidden matches"
  fi
}

check_forbidden_active() {
  local label="$1" pattern="$2"
  shift 2
  local hits=()
  local path
  for path in "$@"; do
    if [[ ! -e "$REPO_ROOT/$path" ]]; then
      echo "BOUNDARY ERROR: $label — path $path does not exist"
      rc=1
      continue
    fi
    while IFS= read -r line; do
      [[ -z "$line" ]] || hits+=("$line")
    done < <(
      grep -rnE \
        --include='*.ml' --include='*.mli' \
        --include='*.ts' --include='*.tsx' \
        --include='*.py' --include='*.rs' \
        --include='*.md' --include='*.json' \
        "$pattern" "$REPO_ROOT/$path" 2>/dev/null || true
    )
  done

  if [[ "${#hits[@]}" -gt 0 ]]; then
    echo "BOUNDARY FAIL: $label — found ${#hits[@]} forbidden active-source match(es)"
    printf '%s\n' "${hits[@]:0:8}"
    rc=1
  else
    echo "BOUNDARY INFO: $label — no forbidden active-source matches"
  fi
}

# V2: MASC-specific importance_scores in keeper working_context wrapper
# These wrap OAS Context.t with domain-specific scoring that should
# be handled by OAS custom closures instead.
check "V2-importance-scores" 0 \
  'importance_scores' \
  "lib/keeper/"

# V4: MASC domain marker constant definitions (message content pollution)
# Allowed: keeper_working_context.ml (goal_prefix),
#          context_compact_oas.ml (memory_summary_prefix),
#          tool_goals.ml (goal_prefix)
check "V4-marker-definitions" 2 \
  'let goal_prefix\|let memory_summary_prefix' \
  "lib/"

# V4b: retired model-authored state and introspection protocols are zero-pinned.
# Decision-history RFC tombstones and negative regression tests are intentionally
# outside this active product-source scan.
check_forbidden_active "V4b-retired-state-protocol-zero-pin" \
  '\[STATE\]|NEXT Constraints|OpenQuestions|SOCIAL_MODEL|MASC_STRUCTURED_STATE|state_block_start|keeper_working_state|keeper_state_block_prompt|meta_cognition|continuity_judgment|continuity_verdict|continuity_similarity|auto_rules|(^|[^[:alnum:]_])BDI([^[:alnum:]_]|$)' \
  "lib/" \
  "bin/" \
  "dashboard/src/" \
  "dashboard_bonsai/src/" \
  "sidecars/" \
  "viewer/src/" \
  "config/prompts/" \
  "config/personas/"

# V6: OAS lifecycle orchestration from keeper_agent_run
# Oas_worker.run_named calls should be isolated to a thin bridge.
check "V6-oas-orchestration" 0 \
  'Oas_worker\.run_named' \
  "lib/keeper/keeper_agent_run.ml"

# V7: MASC-specific safety gates in OAS hook layer
# Eval_gate destructive detection and keeper deny list should be
# injected via OAS hook config, not hardcoded in hook callbacks.
check "V7-masc-hook-gates" 3 \
  'Eval_gate\.detect_destructive\|[^[]keeper_denied_tools' \
  "lib/keeper/keeper_hooks_oas.ml"

# V8: Direct OAS Agent.state mutation from keeper code
# Baseline 0: legacy keeper_extend_turns.ml was removed.
check "V8-agent-state-mutation" 0 \
  'Agent\.set_state\|Agent_sdk\.Agent\.state[^_]' \
  "lib/keeper/"

# V9: MASC_LLAMA env var coupling (should migrate to MASC_LOCAL_*)
# The compatibility surface is fully removed; pin it at zero.
check "V9-masc-llama-envvar" 0 \
  'MASC_LLAMA' \
  "lib/"

# V10: OAS-owned provider filters must not be re-owned outside compatibility loaders/scrubbers.
# The .mli of keeper_meta_json_scrub is the public interface for the already-allowed
# .ml; the doc-comment legitimately surfaces the legacy key name in its API contract.
check_forbidden_outside "V10-provider-filter-ownership" \
  'allowed_providers' \
  "lib/" \
  "lib/keeper_types/keeper_types.ml" \
  "lib/keeper_types/keeper_types.mli" \
  "lib/keeper/keeper_meta_json_scrub.ml" \
  "lib/keeper/keeper_meta_json_scrub.mli" \
  "lib/keeper/keeper_config.ml" \
  "lib/keeper/keeper_config_text.ml" \
  "lib/keeper/keeper_config_text.mli"

# V11: proof-store layout knowledge must stay inside the contract proof-store owner
# and proof reader adapter.
check_forbidden_outside "V11-proof-store-layout" \
  'Filename\.concat .*"proofs"' \
  "lib/" \
  "lib/cdal_runtime/proof_store.ml" \
  "lib/cdal_runtime/proof_store.mli" \
  "lib/cdal/proof_artifact_reader.ml" \
  "lib/cdal/proof_artifact_reader.mli"

# V12: oas-runtime session root literal must stay inside the runtime path adapter.
check_forbidden_outside "V12-oas-runtime-layout" \
  '"oas-runtime"' \
  "lib/" \
  "lib/local/worker_container.ml"

if [[ "$rc" -eq 0 ]]; then
  echo "BOUNDARY: all checks within baseline"
fi
exit "$rc"
