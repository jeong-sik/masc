"""Harbor jobs 디렉터리를 훑어 arm×task 요약 CSV를 만든다.

사용: python aggregate.py <jobs-dir>
행: job(=arm), task, attempt, reward(0/1), duration_ms, tokens, tool_calls.
Harbor trial 결과 파일 레이아웃은 Phase 0 첫 실행 산출물로 확정한다
(trial 디렉터리의 result/config json을 재귀 탐색).
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
        yield result.parent, data


def main() -> None:
    jobs = Path(sys.argv[1])
    print("job,task,attempt,reward,duration_ms,input_tokens,output_tokens,"
          "cache_tokens,cost_usd,tool_calls,duplicate_tool_calls,masc_state")
    for trial_dir, data in iter_trials(jobs):
        verifier = data.get("verifier_result") or {}
        meta = (data.get("agent_context") or {}).get("metadata") or {}
        ctx = data.get("agent_context") or {}
        reward = (verifier.get("rewards") or {}).get("reward", "")
        row = [
            str(data.get("job_name", trial_dir.parts[-3] if len(trial_dir.parts) > 2 else "")),
            str(data.get("task_name", trial_dir.name)),
            str(data.get("attempt", "")),
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
