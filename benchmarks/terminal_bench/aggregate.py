"""Harbor jobs 디렉터리를 훑어 arm×task 요약 CSV를 만든다.

사용: python aggregate.py <jobs-dir>
행: job(=arm), task, trial, reward(0/1), duration_ms, tokens, tool_calls.
레이아웃은 Phase 0 실측으로 확정 (harbor 0.22.0):
  <jobs>/<job-name>/<task>__<suffix>/result.json  (trial-level, task_name 있음)
  <jobs>/<job-name>/result.json                    (job-level, task_name 없음 — 스킵)
  trial 필드: task_name, trial_name, agent_result(AgentContext),
              verifier_result.rewards.reward. job_name/attempt 필드는 없다.
"""
from __future__ import annotations

import json
import sys
from pathlib import Path


def iter_trials(jobs: Path):
    for result in sorted(jobs.rglob("result.json")):
        try:
            data = json.loads(result.read_text())
        except json.JSONDecodeError:
            continue
        if "task_name" not in data:
            continue  # job-level result.json
        yield result.parent, data


def main() -> None:
    jobs = Path(sys.argv[1])
    print("job,task,trial,reward,duration_ms,input_tokens,output_tokens,"
          "cache_tokens,cost_usd,tool_calls,duplicate_tool_calls,masc_state")
    for trial_dir, data in iter_trials(jobs):
        verifier = data.get("verifier_result") or {}
        ctx = data.get("agent_result") or {}
        meta = ctx.get("metadata") or {}
        reward = (verifier.get("rewards") or {}).get("reward", "")
        row = [
            str(trial_dir.parent.name),
            str(data.get("task_name", "")),
            str(data.get("trial_name", trial_dir.name)),
            str(reward),
            str(meta.get("duration_ms", "")),
            str(ctx.get("n_input_tokens") or ""),
            str(ctx.get("n_output_tokens") or ""),
            str(ctx.get("n_cache_tokens") or ""),
            str(ctx.get("cost_usd") or ""),
            str(meta.get("tool_calls", "")),
            str(meta.get("duplicate_tool_calls", "")),
            str(meta.get("masc_state", "")),
        ]
        print(",".join(row))


if __name__ == "__main__":
    main()
