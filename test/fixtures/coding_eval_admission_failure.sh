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
case_dir="${proof_dir}/case"
mkdir -p "${case_dir}" "${CONFIG_DIR}"
printf '%s' '{"id":"l1-calc-add","timeout_sec":60,"verify":"verify.sh","prompt":"controlled failed admission"}' > "${case_dir}/case.json"
cat > "${case_dir}/verify.sh" <<'VERIFY'
#!/usr/bin/env bash
touch "$1/unexpected-grading"
VERIFY
if [[ "$3" == stale ]]; then
  mkdir -p "${TARGET_DIR}/.masc/playground/docker/coding-eval-fixture-model-l1-calc-add-r1/workspace"
fi
call_mcp_tool() { return 1; }
tool_error_text() { printf '%s' 'controlled admission failure'; }
keeper_tool_call_names() { printf '[]'; }
stop_keeper_best_effort() { :; }
run_one fixture model "${case_dir}" 1
