---
status: draft
last_verified: 2026-05-08
code_refs:
  - lib/keeper/keeper_cascade_profile.ml
  - lib/keeper/keeper_health_probe.ml
  - lib/keeper/keeper_supervisor.ml
  - lib/keeper/keeper_unified_turn.ml
---

# RFC-0041: Cascade Routing Architecture — Group/Item Hierarchy with Health-Aware Fallback

**Status**: Draft
**Date**: 2026-05-08
**Scope**: `masc-mcp` cascade selection and fallback mechanism
**One sentence**: cascade를 단순 문자열 이름에서 group/item 계층 구조로 재설계하고, health-aware per-turn routing으로 keeper를 cascade 실패로부터 격리한다.

## Related Documents

- `RFC-0022-cascade-attempt-liveness.md` — cascade attempt lifecycle and liveness probes
- `RFC-0027-capability-typed-cascade.md` — capability-based cascade selection
- `RFC-0002-keeper-state-machine.md` — keeper lifecycle states
- `lib/keeper/keeper_health_probe.ml` — existing health probe (currently dead code)
- PR #14168 — feat(keeper): remove cascade auto-pause, restart with fallback cascade

## Problem Statement

### Current State

현재 `keeper_registry.registry_entry`의 `cascade_name` 필드:

```ocaml
type registry_entry = {
  name : string;
  cascade_name : string;  (* 단순 문자열, 계층 없음 *)
  ...
}
```

이 단순 문자열 기반 설계로 인해 다음 문제가 발생한다.

### Issue 1: Supervisor가 Routing을 침범함

PR #14168은 supervisor가 restart 시점에 `fallback_cascade_for`를 호출하여 cascade를 변경한다.

```ocaml
let meta_with_fallback =
  match Keeper_cascade_profile.fallback_cascade_for meta.cascade_name with
  | Some fallback -> { meta with cascade_name = fallback }
  | None -> meta
```

문제:
- **layering 위반**: supervisor는 keeper lifecycle을 관리해야 하며, cascade 선택은 routing layer의 책임이다.
- **불필요한 restart**: keeper process 자체는 정상인데 cascade(provider)가 문제인 경우에도 restart한다.
- **상태 손실**: restart는 keeper의 컨텍스트, 메모리, 세션 상태를 모두 초기화한다.

### Issue 2: Keeper Failure와 Cascade Failure 신호 혼재

현재 `restart_count`는 keeper crash와 cascade failure를 구분하지 않는다.

- cascade rate limit으로 3번 restart되면 keeper가 Dead 상태로 전이된다.
- 실제로는 keeper는 살아있고 provider가 문제인데, keeper가 죽은 것으로 판단된다.

### Issue 3: Health Probe가 Dead Code

`keeper_health_probe.ml`의 `is_healthy`는 아묘도 호출하지 않는다. probe가 동작하지만 routing layer와 연결되지 않았다.

### Issue 4: Global Shared State로 인한 Keeper 간 간섭

`health_cache`는 `Hashtbl.t`로 global mutex로 보호된다. 한 keeper의 cascade 측정이 다른 keeper의 routing 결정에 영향을 줄 수 있다.

## Design Anchors

사용자 요구사항에서 도출된 6가지 설계 원칙:

| # | 원칙 | 의미 |
|---|------|------|
| 1 | cascade 때문에 Keeper 움직임을 끊기게 하면 안 됨 | cascade failure는 restart 대상이 아님. turn-level fallback으로 해결 |
| 2 | 한 Keeper의 cascade가 다른 Keeper를 막지 않음 | health probe는 per-keeper 격리. global shared state 금지 |
| 3 | 텔레메트리 정보가 분명하게 수집될 것 | 어떤 item/group 사용했는지, fallback 발생 여부가 observability에 잡혀야 함 |
| 4 | cascade는 group과 item을 소유함 | 계층 구조: cascade -> group -> item |
| 5 | item은 설정/전략에 따라 선택되거나 fallback 됨 | group 내 item 순회 전략 존재 |
| 6 | group 낸부 순회가 안 된다면 다른 group으로 시도할 수 있음 | group-level fallback chain |

## Architecture: 3-Layer Defense

```
┌─────────────────────────────────────────────────────────────┐
│  L1: Proactive Routing (per-turn)                           │
│  ─────────────────────────────────                          │
│  Turn 시작 전 health probe 확인                              │
│  Unhealthy item -> 동일 group 내 다음 item                   │
│  Group 전체 unhealthy -> fallback group                      │
│  파일: keeper_heartbeat_loop.ml (routing 결정 지점)          │
└─────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────┐
│  L2: Reactive Fallback (per-attempt)                        │
│  ───────────────────────────────────                        │
│  Turn 실행 중 오류 발생 시 fallback                          │
│  Provider cooldown, budget exhausted 등                      │
│  파일: keeper_unified_turn.ml (기존, 유지)                   │
└─────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────┐
│  L3: Supervisor Escape (per-keeper)                         │
│  ──────────────────────────────────                         │
│  Storm, fiber crash 등 keeper 자체 문제 시 restart           │
│  PR #14168에서 cascade switching 제거 후 단순화              │
│  파일: keeper_supervisor.ml                                  │
└─────────────────────────────────────────────────────────────┘
```

핵심 불변량: **cascade failure는 L1/L2에서 해결. L3는 keeper 자체 crash만 담당.**

## Data Model

### CascadeRef

```ocaml
type cascade_item = {
  id : string;
  provider : string;
  model : string;
  timeout_ms : int;
  priority : int;  (* 낮을수록 우선순위 높음 *)
}
[@@deriving yojson, show, eq]

type traversal_strategy =
  | Priority  (* priority 순서대로 *)
  | RoundRobin
  | Random
[@@deriving yojson, show, eq]

type cascade_group = {
  name : string;
  items : cascade_item list;
  strategy : traversal_strategy;
  fallback_group : string option;  (* None이면 group chain 종료 *)
}
[@@deriving yojson, show, eq]

type cascade_profile = {
  name : string;
  groups : cascade_group list;
}
[@@deriving yojson, show, eq]

type cascade_ref = {
  group : string;
  item : string option;  (* None이면 strategy에 따라 선택 *)
}
[@@deriving yojson, show, eq]
```

### Registry Entry 변경

```ocaml
type registry_entry = {
  name : string;
  cascade_ref : cascade_ref;  (* 기존 cascade_name 대체 *)
  ...
}
```

Backward compatibility: 기존 `cascade_name: string`은 `cascade_ref`로 migration. 단일 group에 단일 item으로 래핑.

### Health State (per-item, per-keeper)

```ocaml
type item_health_state =
  | Healthy
  | Degraded of { consecutive_failures : int; since : float }
  | Unhealthy of { reason : string; since : float }
[@@deriving show]

(* per-keeper, per-item 격리 *)
type health_cache = {
  mu : Eio.Mutex.t;
  table : (string * string, item_health_state) Hashtbl.t;
  (* key: (keeper_name, item_id) *)
}
```

## Routing Algorithm

### Select Item for Turn

```ocaml
let select_item_for_turn ~keeper_name ~cascade_profile ~health_cache ~last_used_item =
  let rec try_group group_name visited =
    if List.mem group_name visited then
      Error `No_available_item  (* cycle 방지 *)
    else
      match find_group cascade_profile group_name with
      | None -> Error (`Unknown_group group_name)
      | Some group ->
          let items = order_items group.strategy group.items in
          match find_healthy_item ~keeper_name ~health_cache items with
          | Some item -> Ok item
          | None ->
              match group.fallback_group with
              | Some next -> try_group next (group_name :: visited)
              | None -> Error `No_available_item
  in
  try_group cascade_ref.group []
```

### Health Update

```ocaml
let record_item_result ~keeper_name ~item_id ~success ~health_cache =
  Eio.Mutex.use_rw ~protect:true health_cache.mu (fun () ->
    let key = (keeper_name, item_id) in
    let current = Hashtbl.find_opt health_cache.table key in
    let new_state =
      match current, success with
      | _, true -> Healthy
      | Some (Degraded { consecutive_failures; _ }), false
        when consecutive_failures >= threshold ->
          Unhealthy { reason = "consecutive_failures"; since = now () }
      | _, false ->
          Degraded { consecutive_failures = 1; since = now () }
      | Some (Unhealthy _), false ->
          Unhealthy { reason = "consecutive_failures"; since = now () }
    in
    Hashtbl.replace health_cache.table key new_state)
```

Recovery: 성공 시 즉시 Healthy로 전이. Degraded/Unhealthy에서 한 번이라도 성공하면 Healthy.

## Telemetry

### Prometheus Metrics

```ocaml
(* 새로 추가 *)
let metric_cascade_item_used_total =
  Counter.v_label ~label_name:"item_id" ~help:"..." "cascade_item_used_total"

let metric_cascade_fallback_triggered_total =
  Counter.v_label ~label_name:"reason" ~help:"..." "cascade_fallback_triggered_total"

let metric_cascade_group_exhausted_total =
  Counter.v_label ~label_name:"group_name" ~help:"..." "cascade_group_exhausted_total"

let metric_keeper_cascade_health_state =
  Gauge.v_label ~label_name:"state" ~help:"..." "keeper_cascade_health_state"
```

### Registry Logging

```ocaml
Log.Keeper.info "%s: turn=%d selected_item=%s (group=%s, fallback=%b)"
  keeper_name turn_number item.id group_name is_fallback;
```

### Dashboard 표시

- Keeper detail: 현재 사용 중인 item, group, fallback 횟수
- Fleet overview: group별 health 비율, fallback 빈도

## TLA+ Model

### State Space

```tla
VARIABLES
  keeper_state,      (* "running" | "turning" | "restarting" *)
  item_health,       (* item_id -> "healthy" | "degraded" | "unhealthy" *)
  selected_item,     (* 현재 turn에 선택된 item *)
  fallback_count     (* fallback 발생 횟수 *)
```

### Actions

```tla
TurnStart(keeper) ==
  /\ keeper_state[keeper] = "running"
  /\ LET group == cascade_profile[keeper].primary_group
         item == SelectItem(group, item_health)
     IN  /\ selected_item' = [selected_item EXCEPT ![keeper] = item]
         /\ keeper_state' = [keeper_state EXCEPT ![keeper] = "turning"]

ItemExecute(keeper) ==
  /\ keeper_state[keeper] = "turning"
  /\ IF item_health[selected_item[keeper]] = "healthy"
     THEN /\ item_health' = item_health  (* 성공, 변화 없음 *)
          /\ keeper_state' = [keeper_state EXCEPT ![keeper] = "running"]
          /\ UNCHANGED <<fallback_count, selected_item>>
     ELSE /\ item_health' = DegradeItem(item_health, selected_item[keeper])
          /\ fallback_count' = fallback_count + 1
          /\ keeper_state' = [keeper_state EXCEPT ![keeper] = "running"]
```

### Invariants

```tla
(* 핵심: cascade 때문에 keeper가 멈추지 않음 *)
KeeperNeverBlockedByCascade ==
  \A keeper \in Keepers :
    keeper_state[keeper] \in {"running", "turning", "restarting"}
    => keeper_state[keeper] /= "paused_due_to_cascade"

(* 핵심: healthy item이 있으면 turn은 반드시 실행됨 *)
TurnAlwaysProceedsIfHealthyItemExists ==
  \A keeper \in Keepers :
    (\E item \in Items : item_health[item] = "healthy")
    => <>(keeper_state[keeper] = "turning")
```

## Migration Plan

### Phase 1: Type Migration (backward compat)

- `cascade_name: string` -> `cascade_ref: CascadeRef.t`
- 기존 toml 설정: 단일 문자열은 단일 group/단일 item으로 래핑
- `ppx_deriving_yojson`으로 JSON serialization 유지

### Phase 2: Health Probe Reconnect

- `keeper_health_probe.ml` 수정: per-keeper, per-item health cache
- `is_healthy` -> `is_item_healthy ~keeper_name ~item_id`
- `keeper_heartbeat_loop.ml`에서 turn 시작 전 호출

### Phase 3: Routing Layer Integration

- `select_item_for_turn` 구현
- `keeper_unified_turn.ml`의 L2 fallback과 통합 (double defense)
- Group fallback chain 테스트

### Phase 4: Telemetry + TLA+ Validation

- Prometheus metric 추가
- Dashboard UI 업데이트
- TLA+ model checker 실행 (TLC)

### Phase 5: PR #14168 수정

- Supervisor에서 cascade switching 제거
- L3는 keeper crash만 담당하도록 단순화
- Fallback은 L1/L2에서 처리

## Open Questions

1. **Group cycle 방지**: fallback_group이 cycle을 형성하면? -> `visited` set으로 탐지, max_hops 제한.
2. **Degraded -> Unhealthy threshold**: 연속 실패 횟수. 기본값 3? configurable?
3. **Health probe interval**: item-level probe는 기존 cascade-level probe보다 더 자주 실행 필요?
4. **Registry migration**: 기존 `cascade_name` 필드를 어떻게 migration? dual-read period?

---

## Decision Log

| Date | Decision | Rationale |
|------|----------|-----------|
| 2026-05-08 | cascade_name: string 제거 | 단일 레벨로는 group/item 계층 표현 불가 |
| 2026-05-08 | per-keeper, per-item health cache | 요구사항 2: 한 keeper의 cascade가 다른 keeper 막지 않음 |
| 2026-05-08 | supervisor에서 cascade switching 제거 | 요구사항 1: layering 위반, 불필요한 restart |
| 2026-05-08 | 3-layer defense 유지 | L1/L2/L3 각각의 책임 명확화 |
