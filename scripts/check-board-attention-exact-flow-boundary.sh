#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${MASC_BOARD_ATTENTION_BOUNDARY_ROOT:-$(cd "${SCRIPT_DIR}/.." && pwd)}"
FLOW_ML="${REPO_ROOT}/lib/keeper/keeper_board_attention_exact_flow.ml"
FLOW_MLI="${REPO_ROOT}/lib/keeper/keeper_board_attention_exact_flow.mli"
WORKER_ML="${REPO_ROOT}/lib/keeper/keeper_board_attention_worker.ml"
WORKER_MLI="${REPO_ROOT}/lib/keeper/keeper_board_attention_worker.mli"
PARTITION_ML="${REPO_ROOT}/lib/keeper/keeper_board_attention_partition.ml"
PARTITION_MLI="${REPO_ROOT}/lib/keeper/keeper_board_attention_partition.mli"
TARGETS=(
  "${FLOW_ML}"
  "${FLOW_MLI}"
  "${WORKER_ML}"
  "${WORKER_MLI}"
  "${PARTITION_ML}"
  "${PARTITION_MLI}"
)

fail() {
  printf '[board-attention-exact-flow-boundary] %s\n' "$*" >&2
  exit 1
}

command -v rg >/dev/null 2>&1 || fail "ripgrep is required"
command -v python3 >/dev/null 2>&1 || fail "python3 is required"

ocaml_code() {
  local target="$1"
  python3 - "${target}" <<'PY'
import pathlib
import sys

source = pathlib.Path(sys.argv[1]).read_text()
output = []
index = 0
comment_depth = 0
in_string = False
escaped = False

while index < len(source):
    char = source[index]
    following = source[index:index + 2]

    if comment_depth:
        if following == "(*":
            comment_depth += 1
            output.extend((" ", " "))
            index += 2
        elif following == "*)":
            comment_depth -= 1
            output.extend((" ", " "))
            index += 2
        else:
            output.append("\n" if char == "\n" else " ")
            index += 1
    elif in_string:
        output.append("\n" if char == "\n" else " ")
        if escaped:
            escaped = False
        elif char == "\\":
            escaped = True
        elif char == '"':
            in_string = False
        index += 1
    elif following == "(*":
        comment_depth = 1
        output.extend((" ", " "))
        index += 2
    elif char == '"':
        in_string = True
        output.append(" ")
        index += 1
    else:
        output.append(char)
        index += 1

sys.stdout.write("".join(output))
PY
}

count_fixed() {
  local token="$1"
  local target="$2"
  { ocaml_code "${target}" | rg -o --fixed-strings "${token}" 2>/dev/null || true; } \
    | wc -l \
    | tr -d ' '
}

require_once() {
  local token="$1"
  local target="$2"
  local count
  count="$(count_fixed "${token}" "${target}")"
  [[ "${count}" == "1" ]] \
    || fail "expected exactly one ${token} in ${target}, found ${count}"
}

require_raw() {
  local token="$1"
  local target="$2"
  rg -q --fixed-strings "${token}" "${target}" \
    || fail "expected ${token} in ${target}"
}

matches_pattern() {
  local pattern="$1"
  shift
  local target status
  for target in "$@"; do
    if ocaml_code "${target}" | rg --multiline -- "${pattern}" >/dev/null; then
      return 0
    else
      status=$?
    fi
    if [[ ${status} -eq 1 ]]; then
      continue
    fi
    fail "rg failed while checking: ${target}"
  done
  return 1
}

forbid_pattern() {
  local pattern="$1"
  local detail="$2"
  if matches_pattern "${pattern}" "${TARGETS[@]}"; then
    rg -n --multiline -- "${pattern}" "${TARGETS[@]}" >&2 || true
    fail "${detail}"
  fi
}

check_boundary() {
  local target
  for target in "${TARGETS[@]}"; do
    [[ -f "${target}" ]] || fail "required target not found: ${target}"
  done

  require_once "let lane_id =" "${FLOW_ML}"
  require_raw '"board_attention_exact"' "${FLOW_ML}"
  require_once "Exact_output.make_flow_candidate" "${FLOW_ML}"
  require_once "Exact_output.admit_flow" "${FLOW_ML}"
  require_once "Exact_output.start_flow" "${FLOW_ML}"
  require_once "Exact_output.execute_flow_once" "${FLOW_ML}"
  require_once "Exact_flow.prepare" "${WORKER_ML}"
  require_once "Exact_flow.execute" "${WORKER_ML}"
  require_once "Partition.bind_before_dispatch" "${WORKER_ML}"
  require_once "Partition.record_before_advance" "${WORKER_ML}"
  require_once "Partition.Fsync_completed" "${WORKER_ML}"
  require_once "let bind_before_dispatch" "${PARTITION_ML}"
  require_once "let record_before_advance" "${PARTITION_ML}"
  require_once "val bind_before_dispatch" "${PARTITION_MLI}"
  require_once "val record_before_advance" "${PARTITION_MLI}"

  forbid_pattern \
    'Keeper_provider_subcall|Llm_provider|Provider_config|provider_config|(^|[^[:alnum:]_])(provider_id|provider_name|selected_provider|model_id|model_name|selected_model|tier_id|tier_name|selected_tier|endpoint|credential|runtime_id)([^[:alnum:]_]|$)' \
    "Board attention execution must not regain provider, model, tier, credential, endpoint, or runtime-scalar policy"
  forbid_pattern \
    '(^|[\n])[[:space:]]*(let|and)[[:space:]]+(rec[[:space:]]+)?(provider|model|tier)[[:space:]]*([:=]|$)|(^|[\n])[[:space:]]*(let|and)[[:space:]]+(rec[[:space:]]+)?[[:alnum:]_]+[[:space:]]+(provider|model|tier)([^[:alnum:]_]|$)|[~?](provider|model|tier)([^[:alnum:]_]|$)|\.(provider|model|tier)([^[:alnum:]_]|$)|[{;][[:space:]]*(provider|model|tier)([^[:alnum:]_]|$)|\([[:space:]]*(provider|model|tier)[[:space:]]*(:|\))' \
    "Board attention execution must not regain bare provider, model, or tier code identifiers"
  forbid_pattern \
    '(^|[\n])[[:space:]]*(let|and)[[:space:]]+(rec[[:space:]]+)?[^=]*(^|[^[:alnum:]_])(provider|model|tier)([^[:alnum:]_]|$)[^=]*=|(^|[\n])[[:space:]]*fun[[:space:]]+[^-]*(^|[^[:alnum:]_])(provider|model|tier)([^[:alnum:]_]|$)[^-]*->' \
    "Board attention execution must not regain provider, model, or tier through tuple destructuring"
  forbid_pattern \
    'Keeper_board_attention_failure|attempt_failure|retryable|Retry\.|retry_after|retry_deadline|is_retryable|Deferred|Partition_deferred|(^|[^[:alnum:]_])defer([^[:alnum:]_]|$)|release_due_provider_retries|next_provider_retry_deadline|recover_claim_after_lane_abort' \
    "Board attention execution must not regain local retry or defer authority"
  forbid_pattern \
    'Exact_output\.(receipt_phase|receipt_dispatch_count)|receipt_(phase|dispatch_count)|dispatch_count|exact_execution_failed_before_dispatch' \
    "Board attention execution must not inspect OAS receipt phase or dispatch count"
  forbid_pattern \
    'Judgment_blocked|Claim_released|Claim_already_transitioned|Legacy_|legacy_failure' \
    "retired Board attention failure or claim-recovery surface returned"
  forbid_pattern \
    'Exact_output\.(admit|start_attempt|execute_once)([^_[:alnum:]]|$)' \
    "Board attention must not reconstruct a candidate loop from legacy one-shot APIs"

  for target in \
    "${REPO_ROOT}/lib/keeper/keeper_board_attention_failure.ml" \
    "${REPO_ROOT}/lib/keeper/keeper_board_attention_failure.mli"; do
    [[ ! -e "${target}" ]] || fail "retired Board attention failure module remains: ${target}"
  done

  printf '[board-attention-exact-flow-boundary] OK\n'
}

self_test() (
  local fixture worker_backup injection
  fixture="$(mktemp -d "${TMPDIR:-/tmp}/board-attention-exact-flow-boundary.XXXXXX")"
  trap "rm -rf '${fixture}'" EXIT
  mkdir -p "${fixture}/lib/keeper"
  cp "${TARGETS[@]}" "${fixture}/lib/keeper/"
  worker_backup="${fixture}/worker.ml.clean"
  cp "${fixture}/lib/keeper/keeper_board_attention_worker.ml" "${worker_backup}"

  MASC_BOARD_ATTENTION_BOUNDARY_ROOT="${fixture}" \
    bash "${BASH_SOURCE[0]}" --check >/dev/null

  cat >>"${fixture}/lib/keeper/keeper_board_attention_worker.ml" <<'EOF'
(*
let keep, provider = ignored_comment
fun keep, model -> ignored_comment
*)
let _boundary_string_example = "
let (keep, tier) = ignored_string
"
EOF
  MASC_BOARD_ATTENTION_BOUNDARY_ROOT="${fixture}" \
    bash "${BASH_SOURCE[0]}" --check >/dev/null
  cp "${worker_backup}" "${fixture}/lib/keeper/keeper_board_attention_worker.ml"

  printf '%s\n' 'let _ = Exact_output.receipt_phase' \
    >"${fixture}/lib/keeper/keeper_librarian_runtime.ml"
  MASC_BOARD_ATTENTION_BOUNDARY_ROOT="${fixture}" \
    bash "${BASH_SOURCE[0]}" --check >/dev/null

  for injection in \
    'let _ = Keeper_provider_subcall.complete' \
    'let model_id = "forbidden"' \
    'let provider = "forbidden"' \
    'let _ = runtime.provider' \
    'let f ~provider = provider' \
    'let model = "forbidden"' \
    'let _ = runtime.model' \
    'let f ~model = model' \
    'let tier = "forbidden"' \
    'let _ = runtime.tier' \
    'let f ~tier = tier' \
    'let (provider, keep) = ("forbidden", ())' \
    'fun (model, keep) -> keep' \
    'let (keep, tier) = ((), "forbidden")' \
    'let keep, provider = (), "forbidden"' \
    'fun keep, model -> keep' \
    'let (keep, (tier, rest)) = ((), ("forbidden", ()))' \
    'let defer value = value' \
    'let _ = Exact_output.receipt_phase' \
    'let _ = Exact_output.receipt_dispatch_count' \
    'let _ = Judgment_blocked' \
    'let _ = Exact_output.execute_once'; do
    cp "${worker_backup}" "${fixture}/lib/keeper/keeper_board_attention_worker.ml"
    printf '\n%s\n' "${injection}" \
      >>"${fixture}/lib/keeper/keeper_board_attention_worker.ml"
    if
      MASC_BOARD_ATTENTION_BOUNDARY_ROOT="${fixture}" \
        bash "${BASH_SOURCE[0]}" --check >/dev/null 2>&1
    then
      fail "self-test accepted forbidden injection: ${injection}"
    fi
  done
  cp "${worker_backup}" "${fixture}/lib/keeper/keeper_board_attention_worker.ml"

  printf '%s\n' 'let _ = Keeper_board_attention_failure.Provider_retry' \
    >"${fixture}/lib/keeper/keeper_board_attention_failure.ml"
  if
    MASC_BOARD_ATTENTION_BOUNDARY_ROOT="${fixture}" \
      bash "${BASH_SOURCE[0]}" --check >/dev/null 2>&1
  then
    fail "self-test accepted the retired Board attention failure module"
  fi
  rm "${fixture}/lib/keeper/keeper_board_attention_failure.ml"

  mv \
    "${fixture}/lib/keeper/keeper_board_attention_exact_flow.ml" \
    "${fixture}/lib/keeper/keeper_board_attention_exact_flow.ml.missing"
  if
    MASC_BOARD_ATTENTION_BOUNDARY_ROOT="${fixture}" \
      bash "${BASH_SOURCE[0]}" --check >/dev/null 2>&1
  then
    fail "self-test accepted a missing required target"
  fi

  printf '%s\n' \
    '[board-attention-exact-flow-boundary:self-test] clean=pass unrelated=pass forbidden=fail missing=fail'
)

case "${1:-}" in
  --self-test)
    self_test
    ;;
  --check | "")
    check_boundary
    ;;
  *)
    fail "usage: $0 [--self-test|--check]"
    ;;
esac
