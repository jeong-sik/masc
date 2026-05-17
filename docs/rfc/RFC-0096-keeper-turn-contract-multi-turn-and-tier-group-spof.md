---
rfc: "0096"
title: "Keeper Turn Contract — multi-turn reasoning + tier-group SPOF root-fix"
status: Draft
created: 2026-05-17
updated: 2026-05-17
author: vincent
supersedes: []
superseded_by: null
related: ["0084", "0085", "0086", "0087", "0089"]
implementation_prs: []
---

# RFC-0096 — Keeper Turn Contract: multi-turn reasoning + tier-group SPOF

> Promote the causal-chain map in issue #15319 to a design-doc level RFC,
> scoped tightly to two root mismatches. Closes the loop on a 17-second
> 4-layer cascade observed in `system_log_2026-05-14.jsonl` seq 52304-52407.

## §1 컨텍스트

`#15319` (meta-issue, 자동 PR 금지로 잠금) 가 Agent Observatory
2026-05-14 의 *표면상 7가지 다른 root* — `Completion contract violated`,
`Cascade exhausted`, `Internal error [masc_oas_error]`,
`stale_turn_timeout`, `stale_fleet_batch`, `api_error_invalid_request`,
"최근 활동 요약 없음" — 이 **단일 keeper turn 의 4 layer × 3 root** 임을
`system_log` evidence + 코드 좌표로 매핑했다.

본 RFC 는 그 매핑의 *Root #1* 과 *Root #3* 에 대한 design proposal 이다.
Root #2 (cascade rotation cap + `alert_exhausted` broadcast spam)
는 amplifier 이지 root 가 아니며, Root #1/#3 가 fix 되면 trigger 자체
가 사라진다. Layer 4 (`stale_fleet_batch` watchdog seal) 는 visibility
의 결과 — 별도 RFC 가 필요 없다.

현재 caller/context 좌표는 `lib/keeper/keeper_tool_disclosure.ml:466`
의 required-tool satisfaction entrypoint, `lib/keeper/keeper_tool_disclosure.ml:483`
의 read-only 불만족 판정, `lib/keeper/keeper_execution_receipt.ml:475`
의 cascade-exhausted → alert disposition 파생이다. Checked-in cascade
profile 쪽 provider surface 는 `config/cascade.toml:57` 에서 시작한다.

```ocaml
(* current contract shape: one turn, one satisfaction decision *)
let required_tool_satisfaction call =
  match effect_of_call call with
  | Some Tool_catalog.Read_only -> false
  | _ -> true
```

## §2 의도된 결과

1. Keeper turn-level `required_tool_use` contract 가 **multi-turn intent
   window** 를 인식해 `board_list` 같은 *읽기 turn* 을 contract violation
   으로 변환하지 않는다.
2. `tier-group.coding_plan` 의 단일-lane 구조 (`tiers =
   ["coding_plan_primary"]`, `members = ["glm-coding.glm-5-1"]`) 가
   **multi-lane** 으로 확장돼 단일 모델 fail 이 fleet 정지로 confluence
   되지 않는다.
3. `cascade rotation cap` (`max_consecutive_rotation_failures`) 가
   amplifier 가 아닌 *근원* 알람만 broadcast 하도록 typed gating 통과
   (RFC-0089 의 string classifier 박멸 흐름과 정렬).

## §3 비결정 영역 / Out of Scope

- `keeper_tool_disclosure.ml::required_tool_satisfaction` 의 `effect_domain`
  분류 자체 — `Tool_catalog.Read_only` ↔ mutating side-effect 분류는
  RFC-0080 + RFC-0084 가 다룬다. 본 RFC 는 contract *enforcement
  scope* (turn vs window) 만 변경.
- `cascade.toml` schema redesign — tier/member 의 schema 자체는
  유지. multi-lane 은 *기존 schema 의 다중 entry* 로 표현.
- `Misc cascade exhausted` 메시지 텍스트 변경 — RFC-0089 의 typed
  variant 흐름에 따라 별도 PR 에서.
- Dashboard `stale_fleet_batch` watchdog 로직 — Layer 4 visibility 의
  cleanup 은 root fix 후 자연스럽게 해소.
- `operator_broadcast_required` 264 events/24h 별도 이슈 (#11083) —
  Root #1 fix 의 부수 효과로 감소 측정.

## §4 Root #1 — turn-level contract vs multi-turn reasoning mismatch

### §4.1 증상

`system_log seq 52304` (2026-05-14):

```
INFO  oas:agent  turn completed turn=16
  stop=error:Completion contract [require_tool_use] violated:
  model called [keeper_board_list], but no call satisfied
  (keeper_board_list: read-only/passive cannot satisfy)
```

Model 이 `keeper_board_list` 로 *상황 파악* 후 다음 turn 에 mutating
action 을 호출하려는 자연스러운 reasoning 이 turn-level enforcement
에 의해 *그 turn 자체* 가 contract violation 으로 변환됨.

### §4.2 위치 + 현재 동작

`lib/keeper/keeper_tool_disclosure.ml:395-417`:

```ocaml
let required_tool_satisfaction (call : Agent_sdk.Completion_contract.tool_call) =
  if is_completion_tool_name tool_name then Ok ()
  else
    let mutates = match Tool_catalog.effect_domain tool_name with
      | Some Tool_catalog.Read_only -> false
      | _ -> Keeper_exec_tools.has_mutating_side_effect_with_input ~tool_name ~input:call.input
    in
    if mutates then Ok ()
    else Error "tool '%s' is read-only/passive and cannot satisfy a required-tool contract"
```

Contract 가 *turn-level* — 한 turn 안에서 mutating 호출이 없으면 fail.

### §4.3 제안 모양

`required_tool_satisfaction` 의 enforcement window 를 *turn → intent
window* 로 확장:

```ocaml
type satisfaction_window =
  | Within_turn                      (* legacy strict — fallback *)
  | Within_intent_window of { max_turns : int }

val required_tool_satisfaction
  :  window:satisfaction_window
  -> history:keeper_turn list
  -> Agent_sdk.Completion_contract.tool_call
  -> (unit, satisfaction_error) result
```

기본값: `Within_intent_window { max_turns = 2 }`. `Within_turn` 은
legacy 시뮬레이터 / 백테스트 용도로만 노출.

### §4.4 결정 필요

- intent window max_turns 의 적정값 (2 / 3 / N) — 측정 필요. 본 RFC
  는 default=2 로 시작하고 telemetry (#11083 operator_broadcast_required
  감소율) 로 조정.
- `keeper_board_list` 같은 read-only tool 을 "intent fulfillment 의
  prerequisite" 으로 인정할지 vs "intent 미시작" 으로 볼지 — 전자가
  더 안전 (default).

## §5 Root #3 — tier-group SPOF (single lane)

### §5.1 증상

`system_log seq 52316`:

```
WARN  Keeper operator_broadcast_required emitted disposition=alert_exhausted
WARN  Keeper rotation retry on cascade=cli_manual reason=cascade_exhausted
WARN  Keeper rotation retry on cascade=direct_api_manual
```

3개 cascade lane (`coding_plan_primary`, `cli_manual`, `direct_api_manual`)
가 *모두* 같은 model 패턴 (`glm-coding.glm-5-1`) 로 fail. fleet 18/19
route SPOF.

### §5.2 위치 + 현재 동작

`.masc/config/cascade.toml`:

```toml
[tier-group.coding_plan]
tiers = ["coding_plan_primary"]

[tier.coding_plan_primary]
members = ["glm-coding.glm-5-1"]
```

단일 tier × 단일 member. quota fail / 5xx / 네트워크 차단이
fleet 정지로 직결.

### §5.3 제안 모양

multi-lane:

```toml
[tier-group.coding_plan]
tiers = ["coding_plan_primary", "coding_plan_secondary"]

[tier.coding_plan_primary]
members = ["glm-coding.glm-5-1"]

[tier.coding_plan_secondary]
members = ["kimi-k2-coding", "qwen3-coder-72b"]
```

Schema 변경 없음. RFC-0086 의 keeper namespace bulk promotion 흐름
과 정렬.

### §5.4 결정 필요

- secondary lane 의 model 선택 — provider 가용성 + cost trade-off.
  Kimi / Qwen 후보는 메모리 노트 (`reference_kidsnote_*`) 의 fleet
  capability 와 cross-check.
- secondary lane 의 trigger 조건 — primary 가 *모든* member 실패한
  후 vs *N consecutive* 실패 후. 후자 (N=3) 가 cooldown amplification
  방지 (RFC-0088 telemetry-as-fix 안티패턴과 정렬).

## §6 구현 phase

| Phase | 산출물 | 통과 조건 |
|-------|--------|----------|
| 1 | `keeper_tool_disclosure.ml` window param + history scan | unit test: 2-turn intent window 에서 read-only → mutating sequence 가 contract violation 일으키지 않음 |
| 2 | `cascade.toml` secondary lane 추가 + provider health probe | integration test: primary lane forced fail 시 secondary 로 rotation 성공 |
| 3 | Telemetry — `keeper_intent_window_satisfaction` counter + `cascade_lane_rotation_total{tier}` | dashboard panel 가시화, RFC-0088 result-propagation 규칙 준수 |
| 4 | #15319 close + #15113 + #15171 + #15526 + #15542 follow-up close | 각 issue 에 measurable resolution comment |

## §7 닫히는 이슈 (예상)

- #15319 (meta) — 본 RFC 가 Root #1/#3 매핑을 design-doc 으로 promote, scope 확정 → close-by-RFC
- #15113 — tier-group SPOF → Phase 2 로 직접 해소
- #15171 — post-claim OAS turn stall → Phase 1 로 직접 해소
- #15526 — cascade exhausted after health/cooldown → Phase 2 + 3 trigger 정렬로 해소
- #15542 — `require_tool_use` violated → Phase 1 로 직접 해소

## §8 Non-goal

- `lib/keeper/keeper_tool_disclosure.ml` 의 전체 redesign — 본 RFC 는
  enforcement window 한 축만 수정.
- `cascade.toml` 의 schema 자체 변경 — multi-lane 은 *기존 schema 의
  다중 entry* 로 표현, schema 변경 없음.
- watchdog `stale_fleet_batch` 의 별도 cleanup — root fix 의 부수 효과로
  해소되며 측정만 한다.
