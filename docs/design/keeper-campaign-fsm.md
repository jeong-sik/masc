# Keeper Campaign FSM

**Status**: Draft  
**Date**: 2026-04-15  
**Scope**: keeper-only goal-reaching campaign harness sub-FSM  
**One sentence**: separate mission progress from keeper runtime lifecycle, then make the harness verdict replayable and machine-checkable.

## Why This Exists

기존 keeper lifecycle FSM은 keepalive, failure, compaction, handoff 같은
런타임 생명주기를 설명한다. 하지만 keeper campaign harness가 증명하려는 것은
다른 축이다.

- goal을 잃지 않고 bootstrap했는가
- task를 실제로 claim/bind 했는가
- autoresearch로 target score에 도달했는가
- 이후 compaction 또는 handoff pressure를 견뎠는가
- 마지막 continuity check에서 goal/task lineage가 살아 있었는가

이건 runtime FSM에 상태를 더 붙여서 해결할 문제가 아니다.

## Separation Rule

`Keeper_state_machine.phase`는 계속 runtime lifecycle만 소유한다.

`Keeper_campaign_fsm.phase`는 mission progress만 소유한다.

즉 이 둘은 직교한다. 예를 들어 아래 조합이 동시에 가능해야 한다.

- runtime = `Running`, campaign = `Searching`
- runtime = `Compacting`, campaign = `Pressure_testing`
- runtime = `HandingOff`, campaign = `Pressure_testing`
- runtime = `Running`, campaign = `Continuity_verified`

## Campaign Phases

- `bootstrapping`
  - keeper keepalive/status surface가 살아나기 전
- `claiming_task`
  - keeper가 campaign task를 claim/bind 하는 중
- `task_bound`
  - `current_task_id`가 확정된 상태
- `searching`
  - autoresearch loop가 목표 점수로 수렴 중
- `target_reached`
  - score 목표는 달성했지만 continuity pressure 전
- `pressure_testing`
  - compaction 또는 handoff evidence를 기다리는 중
- `continuity_verified`
  - 최종 성공 terminal
- `stalled`
  - timeout/window exhaustion terminal
- `escalated`
  - explicit blocker, lineage loss, replay failure 같은 hard-fail terminal

## Event Contract

Replay input은 `campaign-events.jsonl` 한 줄에 이벤트 하나다.

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

이벤트는 append-only이며 하네스 phase log와 별도다.

## Verdict Rule

verdict는 terminal phase에서만 나온다.

- `continuity_verified` -> `reached`
- `stalled` -> `stalled`
- `escalated` -> `escalated`

하네스 summary는 이 verdict를 그대로 사용한다. shell heuristic은 보조 정보로만 남는다.

## Continuity Rule

`continuity_verified`로 들어가려면 모두 참이어야 한다.

- `target_reached = true`
- `compaction_count > 0` 또는 `handoff_count > 0`
- `goal_matches = true`
- `current_task_id == baseline task_id`

이 조건이 깨진 continuity observation은 `escalated`로 간주한다.
반대로 continuity phase까지 갔지만 lifecycle evidence가 아예 없으면
`window_exhausted`로 `stalled` 처리한다.

## Harness Mapping

keeper campaign harness는 이제 세 레이어 아티팩트를 남긴다.

- `phases.jsonl`
  - 사람이 읽는 shell phase timeline
- `campaign-events.jsonl`
  - FSM replay용 canonical mission event log
- `campaign-state.json`
  - replay 결과 snapshot + verdict

즉 운영자가 보는 phase log와 판정 SSOT를 분리한다.

## Non-Goals

- `team_session` 복구 또는 재도입
- subordinate swarm orchestration
- runtime keeper lifecycle 대체
- multi-keeper campaign

v1은 오직 **leader keeper 하나가 task를 들고 목표에 도달한 뒤 continuity까지 버티는가**만 다룬다.
