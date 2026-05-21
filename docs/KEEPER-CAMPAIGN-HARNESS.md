---
status: retired
last_verified: 2026-05-21
code_refs:
  - lib/keeper/
---

# Keeper Campaign Harness

이 harness는 retired 되었다. 기존 설계는 keeper가 `masc_autoresearch_*`
도구로 fixture repo 점수를 올리는 기준에 의존했는데, autoresearch
MCP/keeper tool family는 더 이상 callable surface가 아니다.

이 문서는 과거 artifact/FSM 의미를 읽기 위한 historical note로만 남긴다.
실행 entry point는 제거되었고, 새 continuity 검증은 active keeper/code/goal
surface 위에 별도 harness로 작성해야 한다.

v1 범위:

- keeper-only
- hermetic-first
- `team_session` 비의존
- verdict는 harness artifact에만 기록
- 최종 verdict는 `campaign-events.jsonl`을 `keeper_campaign_fsm`으로 replay한 결과가 SSOT

## Entry Point

없음. `scripts/harness_keeper_campaign.sh`와 workload script는 retired tool
surface를 되살리지 않도록 제거되었다.

기본 동작:

1. isolated temp `BASE_PATH`와 server를 띄운다.
2. harness agent가 room에 join한다.
3. fixture git repo를 만들고 metric script를 심는다.
4. keeper를 goal horizons + aggressive compaction/handoff thresholds로 생성한다.
5. campaign task를 추가한다.
6. keeper에게 task claim/current_task bind를 시킨다.
7. retired: keeper에게 fixture repo를 대상으로 autoresearch를 시작시키고 `target_score` 도달을 요구했다.
8. 큰 prompt로 pressure를 걸어 compaction/handoff를 유도한다.
9. pressure 이후에도 같은 `goal`과 `current_task_id`를 유지하는지 확인한다.
10. 최종 verdict를 `reached | stalled | escalated`로 분류한다.

## Verdicts

- `reached`
  - keeper bootstrap 성공
  - task bind 성공
  - retired autoresearch가 `target_score` 도달
  - compaction 또는 handoff 증거가 나타남
  - pressure 이후에도 동일한 `goal`과 `current_task_id` 유지

- `stalled`
  - keeper lane은 생존했지만 target 또는 continuity proof가 validation window 안에 닫히지 않음

- `escalated`
  - keeper가 viable goal-reaching lane을 만들지 못했거나 blocker/error 상태로 멈춤

## Artifacts

출력 디렉터리:

```text
logs/keeper_campaign/<run_id>/
```

주요 파일:

- `summary.json`
- `summary.md`
- `campaign-events.jsonl`
- `campaign-state.json`
- `phases.jsonl`
- `snapshots/*-keeper-status.json`
- retired: `snapshots/*-autoresearch-status.json`
- `raw/msg-*.json`
- `server.log`

## Campaign FSM

하네스는 shell에서 직접 verdict를 계산하지 않는다. 아래 이벤트들을
`campaign-events.jsonl`로 기록한 뒤, pure OCaml sub-FSM인
`Keeper_campaign_fsm`으로 replay해서 `campaign-state.json`을 만든다.

핵심 phase:

- `bootstrapping`
- `claiming_task`
- `task_bound`
- `searching`
- `target_reached`
- `pressure_testing`
- `continuity_verified`
- `stalled`
- `escalated`

핵심 event:

- `bootstrap_ok`
- `task_bound_observed`
- `autoresearch_started`
- `target_reached`
- `pressure_started`
- `compaction_observed`
- `handoff_observed`
- `continuity_observed`
- `window_exhausted`
- `error_observed`

## Dry Run

없음. Synthetic `reached` verdict는 retired autoresearch 기준을 유지하게
만드므로 제거되었다.

## Important Knobs

- `KEEPER_MODELS`
  - required. example: `KEEPER_MODELS='glm:auto'`
- `MAX_PRESSURE_TURNS`
  - compaction/handoff pressure turn count
- `PRESSURE_BYTES`
  - per-turn synthetic context pressure size
- `KEEPER_COMPACTION_RATIO_GATE`
  - compaction trigger gate
- `KEEPER_HANDOFF_THRESHOLD`
  - handoff trigger gate
- retired: `AUTORESEARCH_WAIT_SEC`
  - old target reach timeout

## Notes

- fixture repo는 isolated `BASE_PATH` 아래에서 생성된다.
- v1은 subordinate swarm을 증명하지 않는다.
- old success threshold는 `masc_autoresearch_start(target_score=...)`에 의존했다.
