#!/usr/bin/env bash
# Execute the real episode driver with controlled admission/status responses.
set -euo pipefail
repo="$1"
proof_dir="$2"
response="$3"
curl() { return 0; }
# shellcheck source=scripts/harness_coding_eval.sh
source "${repo}/scripts/harness_coding_eval.sh" --models fixture:model --out "${proof_dir}/out"
TARGET_DIR="${proof_dir}/target"
CONFIG_DIR="${proof_dir}/config"
export PORT=0 MCP_TOKEN=fixture-only
case_dir="${proof_dir}/case"
mkdir -p "${case_dir}/workspace" "${case_dir}/solution" "${CONFIG_DIR}"
printf '%s' '{"id":"l1-calc-add","timeout_sec":60,"verify":"verify.sh","prompt":"controlled operation response"}' > "${case_dir}/case.json"
printf '%s' 'controlled artifact' > "${case_dir}/workspace/value.txt"
cat > "${case_dir}/verify.sh" <<'VERIFY'
#!/usr/bin/env bash
test -f "$1/value.txt"
VERIFY
call_mcp_tool() {
  case "$2" in
    masc_keeper_up) LAST_TOOL_RAW='{}' ;;
    masc_keeper_msg) LAST_TOOL_RAW='{"operation_id":"kmsg-accepted","state":"Queued"}' ;;
    masc_keeper_delegate_status)
      printf '%s' "$3" > "${proof_dir}/status-request.json"
      LAST_TOOL_RAW="${response}"
      ;;
    *) return 1 ;;
  esac
}
tool_result_json() { printf '%s' "${LAST_TOOL_RAW}"; }
keeper_tool_call_names() { printf '[]'; }
stop_keeper_best_effort() { :; }
run_one fixture model "${case_dir}" 1
