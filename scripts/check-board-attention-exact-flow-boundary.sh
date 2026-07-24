#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${MASC_BOARD_ATTENTION_BOUNDARY_ROOT:-$(cd "${SCRIPT_DIR}/.." && pwd)}"
FLOW_ML="${REPO_ROOT}/lib/keeper/keeper_board_attention_exact_flow.ml"
FLOW_MLI="${REPO_ROOT}/lib/keeper/keeper_board_attention_exact_flow.mli"
CANDIDATE_ML="${REPO_ROOT}/lib/keeper/keeper_board_attention_candidate.ml"
CANDIDATE_MLI="${REPO_ROOT}/lib/keeper/keeper_board_attention_candidate.mli"
WORKER_ML="${REPO_ROOT}/lib/keeper/keeper_board_attention_worker.ml"
WORKER_MLI="${REPO_ROOT}/lib/keeper/keeper_board_attention_worker.mli"
PARTITION_ML="${REPO_ROOT}/lib/keeper/keeper_board_attention_partition.ml"
PARTITION_MLI="${REPO_ROOT}/lib/keeper/keeper_board_attention_partition.mli"
RUNTIME_CONFIG="${REPO_ROOT}/config/runtime.toml"
TARGETS=(
  "${FLOW_ML}"
  "${FLOW_MLI}"
  "${CANDIDATE_ML}"
  "${CANDIDATE_MLI}"
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
import re
import sys

source = pathlib.Path(sys.argv[1]).read_text()
output = []
index = 0
comment_depth = 0
in_string = False
escaped = False
quoted_close = None

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
    elif quoted_close is not None:
        if source.startswith(quoted_close, index):
            output.extend(" " * len(quoted_close))
            index += len(quoted_close)
            quoted_close = None
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
    else:
        quoted_match = re.match(r"\{([a-z_][A-Za-z0-9_']*)?\|", source[index:])
        if following == "(*":
            comment_depth = 1
            output.extend((" ", " "))
            index += 2
        elif char == '"':
            in_string = True
            output.append(" ")
            index += 1
        elif quoted_match is not None:
            opener = quoted_match.group(0)
            identifier = quoted_match.group(1) or ""
            quoted_close = f"|{identifier}}}"
            output.extend(" " * len(opener))
            index += len(opener)
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

require_present() {
  local token="$1"
  local target="$2"
  local count
  count="$(count_fixed "${token}" "${target}")"
  (( count >= 1 )) \
    || fail "expected at least one ${token} in ${target}, found ${count}"
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

check_repo_retired_symbols() {
  local matches status
  if matches="$(
    rg -n --hidden \
      -g '!.git/**' \
      -g '!_build/**' \
      -g '!.worktrees/**' \
      -g '!scripts/check-board-attention-exact-flow-boundary.sh' \
      '(Keeper_board_attention_failure|keeper_board_attention_failure|drain_pending_on_owner_lane|drain_board_attention_candidates_on_owner_lane|keeper\.board_attention_judgment([^_[:alnum:]-]|$))' \
      "${REPO_ROOT}" 2>/dev/null
  )"; then
    printf '%s\n' "${matches}" >&2
    fail "retired Board attention symbol remains in the repository"
  else
    status=$?
  fi
  [[ ${status} -eq 1 ]] || fail "rg failed while checking repository retired symbols"
  [[ ! -e "${REPO_ROOT}/config/prompts/keeper.board_attention_judgment.md" ]] \
    || fail "retired singular Board attention prompt remains"
}

check_lane_declaration() {
  python3 - "${RUNTIME_CONFIG}" <<'PY'
import pathlib
import sys
import tomllib

runtime_path = pathlib.Path(sys.argv[1])
lane_id = "board_attention_exact"

with runtime_path.open("rb") as source:
    runtime = tomllib.load(source)

lanes = runtime.get("runtime", {}).get("exact_output_lanes", {})
lane = lanes.get(lane_id)
if not isinstance(lane, dict):
    raise SystemExit(
        f"{runtime_path}: missing [runtime.exact_output_lanes.{lane_id}]"
    )
slots = lane.get("slots")
if (
    not isinstance(slots, list)
    or not slots
    or any(not isinstance(slot, str) or not slot.strip() for slot in slots)
):
    raise SystemExit(f"{runtime_path}: lane {lane_id!r} needs non-empty string slots")
PY
}

check_boundary() {
  local target
  for target in "${TARGETS[@]}" "${RUNTIME_CONFIG}"; do
    [[ -f "${target}" ]] || fail "required target not found: ${target}"
  done

  require_once 'let lane_id = "board_attention_exact"' "${FLOW_ML}"
  require_once "Exact_output.make_flow_candidate" "${FLOW_ML}"
  require_once "Exact_output.admit_flow" "${FLOW_ML}"
  require_once "Exact_output.start_flow" "${FLOW_ML}"
  require_once "Exact_output.execute_flow_once" "${FLOW_ML}"
  require_once "Exact_flow.prepare" "${WORKER_ML}"
  require_once "Exact_flow.execute" "${WORKER_ML}"
  require_once "Partition.bind_before_dispatch" "${WORKER_ML}"
  require_once "Partition.record_before_advance" "${WORKER_ML}"
  require_present "Partition.Fsync_completed" "${WORKER_ML}"
  require_once "let bind_before_dispatch" "${PARTITION_ML}"
  require_once "let record_before_advance" "${PARTITION_ML}"
  require_once "val bind_before_dispatch" "${PARTITION_MLI}"
  require_once "val record_before_advance" "${PARTITION_MLI}"
  check_lane_declaration \
    || fail "Board attention lane declaration contract failed"

  forbid_pattern \
    'Keeper_provider_subcall|Llm_provider|Provider_config|provider_config|Model_catalog|(^|[^[:alnum:]_])(provider_id|provider_name|selected_provider|model_id|model_name|selected_model|tier_id|tier_name|selected_tier|pricing|price|cost|input_cost|output_cost|endpoint|credential|runtime_id)([^[:alnum:]_]|$)' \
    "Board attention execution must not regain provider, model, tier, pricing, cost, credential, endpoint, or runtime-scalar policy"
  forbid_pattern \
    '(^|[\n])[[:space:]]*(let|and)[[:space:]]+(rec[[:space:]]+)?(provider|model|tier|pricing|price|cost)[[:space:]]*([:=]|$)|(^|[\n])[[:space:]]*(let|and)[[:space:]]+(rec[[:space:]]+)?[[:alnum:]_]+[[:space:]]+(provider|model|tier|pricing|price|cost)([^[:alnum:]_]|$)|[~?](provider|model|tier|pricing|price|cost)([^[:alnum:]_]|$)|\.(provider|model|tier|pricing|price|cost)([^[:alnum:]_]|$)|[{;][[:space:]]*(provider|model|tier|pricing|price|cost)([^[:alnum:]_]|$)|\([[:space:]]*(provider|model|tier|pricing|price|cost)[[:space:]]*(:|\))' \
    "Board attention execution must not regain bare provider, model, tier, pricing, price, or cost code identifiers"
  forbid_pattern \
    '(^|[\n])[[:space:]]*(let|and)[[:space:]]+(rec[[:space:]]+)?[^=]*(^|[^[:alnum:]_])(provider|model|tier|pricing|price|cost)([^[:alnum:]_]|$)[^=]*=|(^|[\n])[[:space:]]*fun[[:space:]]+[^-]*(^|[^[:alnum:]_])(provider|model|tier|pricing|price|cost)([^[:alnum:]_]|$)[^-]*->' \
    "Board attention execution must not regain provider, model, tier, pricing, price, or cost through tuple destructuring"
  forbid_pattern \
    'Keeper_board_attention_failure|attempt_failure|retryable|Retry\.|retry_after|retry_deadline|is_retryable|Partition_deferred|(^|[^[:alnum:]_])defer([^[:alnum:]_]|$)|release_due_provider_retries|next_provider_retry_deadline|recover_claim_after_lane_abort' \
    "Board attention execution must not regain local retry or defer authority"
  forbid_pattern \
    'Exact_output\.(receipt_phase|receipt_dispatch_count)|receipt_(phase|dispatch_count)|dispatch_count|exact_execution_failed_before_dispatch' \
    "Board attention execution must not inspect OAS receipt phase or dispatch count"
  forbid_pattern \
    'Judgment_blocked|Claim_released|Claim_already_transitioned|Legacy_|legacy_failure' \
    "retired Board attention failure or claim-recovery surface returned"
  forbid_pattern \
    'Exact_output\.(admit|admit_target_ref|resolve_target|start_attempt|execute_once|Attempt_already_started|Completion_failed|Not_started|Call_id_generation_failed|receipt_target_identity|receipt_http_status|execution_error_cause)([^_[:alnum:]]|$)' \
    "Board attention must not regain retired exact-output symbols or reconstruct a candidate loop from legacy one-shot APIs"

  check_repo_retired_symbols

  for target in \
    "${REPO_ROOT}/lib/keeper/keeper_board_attention_failure.ml" \
    "${REPO_ROOT}/lib/keeper/keeper_board_attention_failure.mli"; do
    [[ ! -e "${target}" ]] || fail "retired Board attention failure module remains: ${target}"
  done

  printf '[board-attention-exact-flow-boundary] OK\n'
}

self_test() (
  local fixture worker_backup candidate_backup flow_backup runtime_backup injection target relative
  fixture="$(mktemp -d "${TMPDIR:-/tmp}/board-attention-exact-flow-boundary.XXXXXX")"
  trap "rm -rf '${fixture}'" EXIT
  for target in "${TARGETS[@]}" "${RUNTIME_CONFIG}"; do
    relative="${target#"${REPO_ROOT}/"}"
    mkdir -p "${fixture}/$(dirname "${relative}")"
    cp "${target}" "${fixture}/${relative}"
  done
  worker_backup="${fixture}/worker.ml.clean"
  candidate_backup="${fixture}/candidate.ml.clean"
  flow_backup="${fixture}/flow.ml.clean"
  runtime_backup="${fixture}/runtime.toml.clean"
  cp "${fixture}/lib/keeper/keeper_board_attention_worker.ml" "${worker_backup}"
  cp "${fixture}/lib/keeper/keeper_board_attention_candidate.ml" "${candidate_backup}"
  cp "${fixture}/lib/keeper/keeper_board_attention_exact_flow.ml" "${flow_backup}"
  cp "${fixture}/config/runtime.toml" "${runtime_backup}"

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
let _boundary_quoted_string_example = {|
let provider = ignored_quoted_string
let _ = Exact_output.receipt_phase
|}
let _boundary_named_quoted_string_example = {boundary|
let pricing = ignored_named_quoted_string
|boundary}
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
    'let pricing = "forbidden"' \
    'let (provider, keep) = ("forbidden", ())' \
    'fun (model, keep) -> keep' \
    'let (keep, tier) = ((), "forbidden")' \
    'let keep, provider = (), "forbidden"' \
    'fun keep, model -> keep' \
    'let (keep, (tier, rest)) = ((), ("forbidden", ()))' \
    'let defer value = value' \
    'let _ = Exact_output.receipt_phase' \
    'let _ = Exact_output.receipt_dispatch_count' \
    'let _ = Exact_output.admit_target_ref' \
    'let _ = Exact_output.resolve_target' \
    'let _ = Exact_output.receipt_target_identity' \
    'let _ = Exact_output.execution_error_cause' \
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

  printf '%s\n' 'let provider_id = "forbidden"' \
    >>"${fixture}/lib/keeper/keeper_board_attention_candidate.ml"
  if
    MASC_BOARD_ATTENTION_BOUNDARY_ROOT="${fixture}" \
      bash "${BASH_SOURCE[0]}" --check >/dev/null 2>&1
  then
    fail "self-test accepted provider policy on the candidate surface"
  fi
  cp "${candidate_backup}" "${fixture}/lib/keeper/keeper_board_attention_candidate.ml"

  python3 - "${fixture}/lib/keeper/keeper_board_attention_exact_flow.ml" <<'PY'
import pathlib
import sys

flow_path = pathlib.Path(sys.argv[1])
source = flow_path.read_text()
original = 'let lane_id = "board_attention_exact"'
replacement = 'let lane_id = "renamed_board_attention_lane"'
if source.count(original) != 1:
    raise SystemExit("exact lane binding not found exactly once")
flow_path.write_text(source.replace(original, replacement))
PY
  if
    MASC_BOARD_ATTENTION_BOUNDARY_ROOT="${fixture}" \
      bash "${BASH_SOURCE[0]}" --check >/dev/null 2>&1
  then
    fail "self-test accepted a renamed Board attention lane"
  fi
  cp "${flow_backup}" "${fixture}/lib/keeper/keeper_board_attention_exact_flow.ml"

  python3 - \
    "${fixture}/config/runtime.toml" <<'PY'
import pathlib
import sys

runtime_path = pathlib.Path(sys.argv[1])
header = "[runtime.exact_output_lanes.board_attention_exact]"
lines = runtime_path.read_text().splitlines(keepends=True)
in_lane = False
mutated = False
for index, line in enumerate(lines):
    stripped = line.strip()
    if stripped == header:
        in_lane = True
        continue
    if in_lane and stripped.startswith("["):
        break
    if in_lane and stripped.startswith("slots"):
        indentation = line[: len(line) - len(line.lstrip())]
        lines[index] = f"{indentation}slots = []\n"
        mutated = True
        break
if not mutated:
    raise SystemExit("lane slot not found")
runtime_path.write_text("".join(lines))
PY
  if
    MASC_BOARD_ATTENTION_BOUNDARY_ROOT="${fixture}" \
      bash "${BASH_SOURCE[0]}" --check >/dev/null 2>&1
  then
    fail "self-test accepted an empty configured exact lane"
  fi
  cp "${runtime_backup}" "${fixture}/config/runtime.toml"

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
    '[board-attention-exact-flow-boundary:self-test] clean=pass quoted=pass unrelated=pass lane=fail candidate=fail config=fail forbidden=fail pricing=fail legacy=fail missing=fail'
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
