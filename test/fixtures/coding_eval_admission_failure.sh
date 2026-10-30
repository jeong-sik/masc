#!/usr/bin/env bash
# Exercise the real episode driver, replacing only external transport calls.
set -euo pipefail
repo="$1"
proof_dir="$2"
curl() { return 1; }
# shellcheck source=scripts/harness_coding_eval.sh
source "${repo}/scripts/harness_coding_eval.sh" --models fixture:model --out "${proof_dir}/out"
TARGET_DIR="${proof_dir}/target"
CONFIG_DIR="${proof_dir}/config"
export PORT=0 MCP_TOKEN=fixture-only
EXPERIMENT_DIGEST="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
assert_experiment_inputs() { :; }
# Controlled transport fixtures do not exercise the Docker grader.
grade_case_stages() {
  printf '%s\n' '{"verify":0,"regression":null,"build":null}' > "$3/grading.json"
}
case_dir="${proof_dir}/case"
mkdir -p "${case_dir}" "${CONFIG_DIR}"
printf '%s' '{"id":"l1-calc-add","timeout_sec":60,"verify":"verify.sh","prompt":"controlled failed admission"}' > "${case_dir}/case.json"
cat > "${case_dir}/verify.sh" <<'VERIFY'
#!/usr/bin/env bash
touch "$1/unexpected-grading"
VERIFY
if [[ "$3" == stale ]]; then
  fixture_run_id="$(run_id_of fixture model l1-calc-add 1)"
  mkdir -p "${TARGET_DIR}/.masc/playground/docker/coding-eval-${fixture_run_id}/workspace"
fi
call_mcp_tool() { return 1; }
tool_error_text() { printf '%s' 'controlled admission failure'; }
keeper_tool_call_names() { printf '[]'; }
stop_keeper_best_effort() { :; }
run_one fixture model "${case_dir}" 1
