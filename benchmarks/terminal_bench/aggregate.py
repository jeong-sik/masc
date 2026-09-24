"""Harbor jobs 디렉터리를 훑어 arm×task 요약 CSV를 만든다.

사용: python aggregate.py <jobs-dir>
행: job(=arm), task, trial, reward(0/1), duration_ms, tokens, tool_calls.
레이아웃은 harbor 0.23.0 의 TrialResult (models/trial/result.py) 기준:
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
    # cost_usd 는 keeper 지출까지 더한 합인데, 원장이 값을 못 매긴 행은 null 로
    # 오고 합에서는 0 처럼 보인다. 그 행 수가 여기 없으면 "값을 모르는 지출" 이
    # 표에서 공짜와 구분되지 않는다. 끝에 붙인다 — 기존 컬럼 위치를 읽는
    # 소비자가 있을 수 있다.
    "keeper_cost_unreported_rows",
    # harbor 의 에이전트 타임아웃이 에피소드를 끊었는지, 그때 keeper 가 실제로
    # 멈췄는지. masc_state 만으로는 "시간 초과로 끊긴 Running" 과 다른 이유의
    # Running 이 구분되지 않는다.
    "interrupted", "keepers_stopped",
    # 어느 arm 이었고 어떤 후보 순서를 선언했는지, 그중 누가 실제로 답했는지.
    # arm l 만 후보가 둘 이상이다. answered_by 는 답한 turn 을, failed_on 은
    # 실패한 turn 을 마지막으로 보낸 후보별로 "runtime=turn 수" 로 ; 로 잇는다.
    # turns_unanswered 는 어느 후보에도 보내지 못하고 실패한 turn 수다.
    # turns_unanswered 가 빈 칸이면 측정되지 않은 것이다(0 이 아니다).
    "arm", "candidates", "answered_by", "failed_on", "turns_unanswered",
    # 도구 호출 중 실패한 수와, 실패가 있었던 도구별 "도구=실패 수" 를 ; 로 이은 것.
    # 벤치 점수가 낮을 때 모델 탓인지 도구 결함(경로 거절 등) 탓인지 가르는 칸이다.
    # 빈 칸이면 측정되지 않은 것이다(0 이 아니다).
    "failed_tool_calls", "failed_by_tool",
]

# 후보 순서를 한 칸에 적을 때의 구분자. 순서가 곧 의미라 정렬하지 않는다.
CANDIDATE_SEPARATOR = " > "
ANSWER_SEPARATOR = ";"


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


def candidates_cell(candidates) -> str:
    return "" if candidates is None else CANDIDATE_SEPARATOR.join(candidates)


def turns_by_runtime_cell(turns_by_runtime) -> str:
    """해당 turn 이 없을 때({})와 미측정(None)은 둘 다 빈 칸이다. 둘은
    turns_unanswered 칸으로 가른다: 측정했으면 숫자, 안 했으면 빈 칸이다."""
    if turns_by_runtime is None:
        return ""
    return ANSWER_SEPARATOR.join(
        f"{runtime}={turns}" for runtime, turns in sorted(turns_by_runtime.items()))


def failed_by_tool_cell(outcomes) -> str:
    """"도구=실패 수" 를 실패가 많은 순서로. 실패가 없는 도구는 뺀다."""
    if not isinstance(outcomes, list):
        return ""
    return ANSWER_SEPARATOR.join(
        f"{row['tool']}={row['failed']}" for row in outcomes
        if isinstance(row, dict) and row.get("failed"))


def main() -> None:
    jobs = Path(sys.argv[1])
    # csv.writer 로 쓴다. task_name 이나 masc_state 에 쉼표가 들어가면 수동
    # join 은 이후 모든 컬럼을 한 칸씩 밀어버린다.
    # Invariant (measured 2026-09-14): every row must go through csv.writer —
    # a manual ",".join(row) silently shifts every later column one cell
    # right the first time a task_name or masc_state contains a comma.
    out = csv.writer(sys.stdout, lineterminator="\n")
    out.writerow(COLUMNS)
    for trial_dir, data, read_error in iter_trials(jobs):
        if data is None:
            out.writerow([
                trial_dir.parent.name, trial_dir.name.split("__")[0],
                trial_dir.name, "", "", "", "", "", "", "", "",
                read_error or "unreadable", "", "", "",
                "", "", "", "", "",
                "", "",
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
            cell((meta.get("keeper_usage") or {}).get("cost_rows_unreported")),
            cell(meta.get("interrupted")),
            cell(meta.get("keepers_stopped")),
            cell(meta.get("arm")),
            candidates_cell(meta.get("candidates")),
            turns_by_runtime_cell(meta.get("answered_by")),
            turns_by_runtime_cell(meta.get("failed_on")),
            cell(meta.get("turns_unanswered")),
            cell(meta.get("failed_tool_calls")),
            failed_by_tool_cell(meta.get("tool_outcomes")),
        ])


if __name__ == "__main__":
    main()
