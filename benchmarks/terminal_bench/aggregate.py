"""Harbor jobs 디렉터리를 훑어 arm×task 요약 CSV를 만든다.

사용: python aggregate.py <jobs-dir>
행: job(=arm), task, trial, reward(0/1), duration_ms, tokens, tool_calls.
레이아웃은 Phase 0 실측으로 확정 (harbor 0.22.0):
  <jobs>/<job-name>/<task>__<suffix>/result.json  (trial-level, task_name 있음)
  <jobs>/<job-name>/result.json                    (job-level, task_name 없음 — 스킵)
  trial 필드: task_name, trial_name, agent_result(AgentContext),
              verifier_result.rewards.reward. job_name/attempt 필드는 없다.

이 파일은 분모를 정직하게 유지하는 것이 일이다. 읽을 수 없는 trial 을 조용히
빼면 성공률이 살아남은 trial 위에서 계산되고, 0 을 빈 칸으로 쓰면 "0 토큰" 과
"측정 안 됨" 이 구분되지 않는다. 둘 다 벤치 결과를 실제보다 좋게 만드는
방향이라 명시적으로 다룬다.
"""
from __future__ import annotations

import csv
import json
import sys
from pathlib import Path

COLUMNS = [
    "job", "task", "trial", "reward", "duration_ms",
    "input_tokens", "output_tokens", "cache_tokens", "cost_usd",
    "tool_calls", "duplicate_tool_calls", "masc_state",
]


def iter_trials(jobs: Path):
    """(trial_dir, data, read_error) — 읽기 실패도 흘려보내지 않고 넘긴다."""
    for result in sorted(jobs.rglob("result.json")):
        try:
            data = json.loads(result.read_text())
        except json.JSONDecodeError as exc:
            # 쓰다 만 result.json 은 trial 이 없었다는 뜻이 아니다. 행 없이
            # 건너뛰면 그 arm 의 분모만 줄어든다.
            yield result.parent, None, f"unparseable: {exc.msg}"
            continue
        except OSError as exc:
            yield result.parent, None, f"unreadable: {exc.strerror}"
            continue
        if "task_name" not in data:
            continue  # job-level result.json
        yield result.parent, data, None


def cell(value) -> str:
    """0 과 0.0 은 값이고 None 만 미측정이다."""
    return "" if value is None else str(value)


def main() -> None:
    jobs = Path(sys.argv[1])
    # csv.writer 로 쓴다. task_name 이나 masc_state 에 쉼표가 들어가면 수동
    # join 은 이후 모든 컬럼을 한 칸씩 밀어버린다.
    out = csv.writer(sys.stdout, lineterminator="\n")
    out.writerow(COLUMNS)
    for trial_dir, data, read_error in iter_trials(jobs):
        if data is None:
            out.writerow([
                trial_dir.parent.name, trial_dir.name.split("__")[0],
                trial_dir.name, "", "", "", "", "", "", "", "",
                read_error or "unreadable",
            ])
            continue
        verifier = data.get("verifier_result") or {}
        ctx = data.get("agent_result") or {}
        meta = ctx.get("metadata") or {}
        out.writerow([
            trial_dir.parent.name,
            data.get("task_name", ""),
            data.get("trial_name", trial_dir.name),
            cell((verifier.get("rewards") or {}).get("reward")),
            cell(meta.get("duration_ms")),
            cell(ctx.get("n_input_tokens")),
            cell(ctx.get("n_output_tokens")),
            cell(ctx.get("n_cache_tokens")),
            cell(ctx.get("cost_usd")),
            cell(meta.get("tool_calls")),
            cell(meta.get("duplicate_tool_calls")),
            cell(meta.get("masc_state")),
        ])


if __name__ == "__main__":
    main()
