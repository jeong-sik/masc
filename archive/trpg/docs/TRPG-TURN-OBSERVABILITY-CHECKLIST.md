# TRPG Turn Observability Checklist (7-Step)

`trpg.round.run` 1턴을 아래 7단계로 관측한다.

1. `dm`:
`narration.posted` (role=`dm`)가 있어야 한다.

2. `discuss`:
플레이어별 `turn.action.proposed`가 있어야 한다.

3. `action`:
플레이어/DM 액션 적용 이벤트가 있어야 한다.
예: `combat.attack`, `combat.defense`, `flag.set`, `scene.transition`, `quest.update`, `narration.posted`.

4. `dice`:
전투 액션(`attack`, `defend`)이면 `dice.rolled`가 있어야 한다.
`round_run`은 원본 응답에 주사위가 없어도 관측용 `dice.rolled`를 합성한다.

5. `outcome`:
각 액션 처리 후 `turn.action.resolved`가 있어야 한다.
`resolved_effects`에 실제 적용 이벤트 타입이 기록된다.

6. `update`:
상태 변경 이벤트(`hp.changed`, `flag.set`, `memory.signal`, `bdi.updated` 등)가 있어야 한다.
최소 1개 이상 상태 변화가 관측되어야 유효 턴으로 본다.

7. `move`:
턴이 진행되면 `turn.started`(next turn)와 `join.window.opened`가 있어야 한다.
진행 실패 시 `turn.started`는 없어야 하며, `summary.progress_reason`으로 원인을 확인한다.

## Quick Verification

다음 이벤트를 `trpg.stream`으로 순서대로 조회하면 된다.

- `turn.action.proposed`
- `combat.attack` / `combat.defense` / `flag.set` / `scene.transition` / `quest.update`
- `dice.rolled`
- `turn.action.resolved`
- `turn.started`

최종 판정은 `trpg.round.run` 응답의 `summary`와 `events`를 함께 확인한다.
