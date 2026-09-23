#!/usr/bin/env bash
# usage: ./run_matrix.sh [arms-csv] [attempts]
#
# Every arm over the whole Terminal-Bench 4.0.0 dataset.
#
# env: BENCH_MODEL  <masc provider>/<model> (default anthropic/claude-fable-5-1)
#      BENCH_FALLBACK_MODELS  comma-separated <provider>/<model> after
#                   BENCH_MODEL in arm l's candidate order (same provider,
#                   different models); required by arm l, read by no other arm
#      BENCH_ENV    harbor environment: docker (default) or modal
#      CONCURRENCY  trials at once (default 2)
set -euo pipefail
cd "$(dirname "$0")"

DATASET="terminal-bench/terminal-bench@4.0.0"
ARMS_CSV="${1:-a,b,c,e,f,h}"
# The attempts Terminal-Bench's own leaderboard runs use (-k 5 in the
# terminal-bench README).
K="${2:-5}"
MODEL="${BENCH_MODEL:-anthropic/claude-fable-5-1}"
FALLBACK_MODELS="${BENCH_FALLBACK_MODELS:-}"
ENVIRONMENT="${BENCH_ENV:-docker}"
CONCURRENCY="${CONCURRENCY:-2}"
TS="$(date +%Y%m%d-%H%M%S)"

# Before the dataset download and any arm, so a missing list does not stop
# the job after hours of earlier arms.
if [[ ",${ARMS_CSV}," == *",l,"* && -z "${FALLBACK_MODELS}" ]]; then
  echo "arm l needs BENCH_FALLBACK_MODELS (e.g. openrouter/deepseek/deepseek-v4-pro)" >&2
  exit 2
fi

# Read the dataset before running it. On docker, the GPU tasks would stop the
# whole job at trial creation, and a task asking for more CPUs or memory than
# the daemon has would fail for a reason unrelated to the agent; dataset_plan.py
# names the first and refuses the second (see its docstring).
DATASET_DIR="results/datasets/terminal-bench-4.0.0"
# harbor extracts tasks in place, so the directory exists from the first task
# on; only a download that exited 0 leaves the mark.
if [[ ! -e "${DATASET_DIR}/.complete" ]]; then
  uv run harbor datasets download "${DATASET}" -o "${DATASET_DIR}" --overwrite
  touch "${DATASET_DIR}/.complete"
fi
EXCLUDE_ARGS=()
excluded="$(uv run python dataset_plan.py \
  --tasks-dir "${DATASET_DIR}/terminal-bench" --env "${ENVIRONMENT}" \
  --concurrency "${CONCURRENCY}")"
while IFS= read -r t; do
  [[ -n "$t" ]] && EXCLUDE_ARGS+=( -x "$t" )
done <<<"${excluded}"

# Arm A is the same model through harbor's own agent for that provider: the
# comparison that attributes a difference to MASC rather than to the model.
# The MASC arms take the masc provider id (render_configs.PROVIDERS); harbor's
# agents name some providers differently.
case "${MODEL%%/*}" in
  anthropic) BASELINE_AGENT=claude-code; BASELINE_MODEL="${MODEL}" ;;
  # kimi-for-coding answers with a reasoning-only payload whose empty assistant
  # message the coding endpoint rejects with 400 under terminus-2 (3 recorded
  # attempts); kimi-cli, Moonshot's reference CLI, is the baseline that runs.
  # harbor's kimi-cli calls the provider `kimi`.
  kimi_coding) BASELINE_AGENT=kimi-cli; BASELINE_MODEL="kimi/${MODEL#*/}" ;;
  *) BASELINE_AGENT=""; BASELINE_MODEL="" ;;
esac

for arm in ${ARMS_CSV//,/ }; do
  job="arm-${arm}-${TS}"
  # No --agent-timeout-multiplier: every trial gets the task's own 28800s, and
  # the MASC episode has no deadline of its own. The setup multiplier covers
  # bootstrap's package installs, which harbor's 360s default does not fit.
  common=( -d "${DATASET}" --env "${ENVIRONMENT}"
           -k "$K" -n "${CONCURRENCY}" --agent-setup-timeout-multiplier 5
           -o results/jobs --job-name "$job" )
  if [[ "$arm" == "a" ]]; then
    if [[ -z "${BASELINE_AGENT}" ]]; then
      echo "no same-model harbor agent known for ${MODEL}; skipping arm a" >&2
      continue
    fi
    uv run harbor run "${common[@]}" --agent "${BASELINE_AGENT}" \
      --model "${BASELINE_MODEL}" \
      ${EXCLUDE_ARGS[@]+"${EXCLUDE_ARGS[@]}"}
  else
    # Arm l walks a candidate order; every other arm renders one model and
    # refuses fallbacks (render_configs.candidate_runtime_ids).
    FALLBACK_ARGS=()
    if [[ "$arm" == "l" ]]; then
      FALLBACK_ARGS=( --ak "fallback_models=${FALLBACK_MODELS}" )
    fi
    uv run harbor run "${common[@]}" --agent agents.masc_agent:MascAgent \
      --model "${MODEL}" --ak "arm=$arm" ${FALLBACK_ARGS[@]+"${FALLBACK_ARGS[@]}"} \
      ${EXCLUDE_ARGS[@]+"${EXCLUDE_ARGS[@]}"}
  fi
done
uv run python aggregate.py "results/jobs" > "results/summary-${TS}.csv"
echo "wrote results/summary-${TS}.csv"
