# RFC 0034.v2 — Per-Goal Cap to All Task-Creation Callers (post-#13981)

- **Status**: Draft (loop-iter-5, 2026-05-07)
- **Author**: Vincent + Claude (auto-mode loop)
- **Builds on**: #13981 ("fix(keeper): cap goal-scoped task creation")
- **Sister**: RFC-0026 work-conserving-keeper-admission, RFC-0002 keeper-state-machine
- **Resolves Board Issue**: "taskmaster — Per-goal limit violation: oas-bridge-stabilization has 8 open tasks"
- **TLA+ spec**: `~/me/.tmp/loop-masc-fsm/spec/GoalCapEntrypoint.tla`

## 1. Motivation

#13981이 `Coord_task_create.add_task`에 `?reject_if` optional 파라미터를 추가하고 `keeper_task_create` MCP tool 핸들러에 cap rejection을 wire했다. 이로써 keeper가 `keeper_task_create`로 만드는 task에는 cap이 적용된다.

그러나 [iter-2~5 코드 추적](../iter-2.md) 결과: `Coord_task.add_task`의 **다른 4 caller가 여전히 `?reject_if`를 미전달**, 즉 동일 cap을 우회한다.

| caller | reject_if | 결과 |
|---|---|---|
| `keeper/keeper_exec_task.ml:336` (`keeper_task_create`) | ✅ 전달 (#13981) | cap 작동 |
| `tool_task.ml:485` (`handle_add_task` for `masc_add_task`) | ❌ 미전달 | **cap 우회** |
| `task_dispatch.ml:59` | ❌ 미전달 | cap 우회 |
| `tool_inline_dispatch_coord.ml:103` | ❌ 미전달 | cap 우회 |
| `operator/operator_control.ml:235` | ❌ 미전달 | cap 우회 |

board의 "8 tasks open in oas-bridge-stabilization"는 (2)~(5) 어느 경로로든 들어온 결과로 추정 — 가장 유력한 건 `masc_add_task` MCP tool.

## 2. Non-Goals

- `Coord_task_create.add_task` 시그니처 변경 — 별도 RFC (`?reject_if` non-optional화).
- cap 값 (3) config화 — 별도 RFC.
- 다른 invariants (priority, contract validity 등) 일반화 — 별도.
- `release_stale_claims` agent-side sync — RFC-0034.d (별도).

## 3. Design

**핵심**: 4 caller에 `~reject_if:(Keeper_exec_task.task_create_goal_capacity_rejection ?goal_id)` 명시적 추가.

`Keeper_exec_task.task_create_goal_capacity_rejection`은 `keeper_exec_task.ml:108~114`에 #13981이 정의한 함수. 시그니처:
```ocaml
val task_create_goal_capacity_rejection :
  ?goal_id:string -> Masc_domain.backlog -> string option
```

문제: 이 함수가 `lib/keeper/`에 있어 `lib/coord/`에서 호출은 dependency 위반. 또한 `tool_task.ml`, `task_dispatch.ml`, `operator_control.ml`은 keeper layer 외부.

**해결**: `Keeper_exec_task.task_create_goal_capacity_rejection`을 `Coord_task_capacity` 모듈로 *이전*하고 *re-export*.

### 3.1 신규 모듈 `lib/coord/coord_task_capacity.{ml,mli}` (#13981 코드 이전)

`keeper_exec_task.ml`의 다음 4 항목을 그대로 이전:
- `keeper_task_create_goal_open_limit` → `default_goal_open_limit`
- `goal_task_capacity_error` (record + function) → `check`
- `task_create_capacity_error_json` → `error_to_json`
- `task_create_goal_capacity_rejection` → `rejection_for_add_task`

`.mli` 시그니처:
```ocaml
type capacity_error = {
  goal_id : string;
  open_task_count : int;
  limit : int;
  message : string;
}

val default_goal_open_limit : int
val check : ?goal_id:string -> Masc_domain.backlog -> capacity_error option
val error_to_json : capacity_error -> Yojson.Safe.t
val rejection_for_add_task : ?goal_id:string -> Masc_domain.backlog -> string option
```

### 3.2 `keeper_exec_task.ml` 정리

- `keeper_task_create_goal_open_limit` 등 4 항목 삭제 (38 LOC).
- 호출 사이트(line 322-340의 `goal_task_capacity_error`, `task_create_capacity_error_json`, `task_create_goal_capacity_rejection`)를 `Coord_task_capacity` 호출로 치환.
- 결과: keeper layer가 coord layer 호출 (의존성 정상 방향).

### 3.3 4 caller에 cap 적용

각 caller에 `~reject_if:(Coord_task_capacity.rejection_for_add_task ?goal_id)` 추가.

```ocaml
(* lib/tool_task.ml:485 — handle_add_task *)
Coord.add_task ?contract ?goal_id
  ~reject_if:(Coord_task_capacity.rejection_for_add_task ?goal_id)
  ~created_by:ctx.agent_name
  ctx.config ~title:trimmed_title ~priority ~description

(* lib/task_dispatch.ml:59 *)
Coord.add_task config ?goal_id
  ~reject_if:(Coord_task_capacity.rejection_for_add_task ?goal_id)
  ~title ~priority ~description

(* lib/tool_inline_dispatch_coord.ml:103 *)
Coord_task.add_task active_config ?goal_id
  ~reject_if:(Coord_task_capacity.rejection_for_add_task ?goal_id)
  ~title:task_title ~priority:3 ~description:""

(* lib/operator/operator_control.ml:235 *)
Coord.add_task ctx.config ?goal_id
  ~reject_if:(Coord_task_capacity.rejection_for_add_task ?goal_id)
  ~title ~priority ~description
```

caller 본문에 `goal_id`가 어떻게 전달되는지 확인 필요. 만약 caller 자체가 `goal_id`를 받지 않으면 (예: `task_dispatch`), `?goal_id=None` 으로 자연 우회 (orphan task는 cap 미적용).

`tool_task.ml:485`의 `handle_add_task`는 이미 args에서 `goal_id` 추출 → `Coord.add_task ?goal_id` 전달함. 그러나 *capacity check가 `goal_id`만 보고 cap 적용*하니, `goal_id=None`이면 자연 우회 — 정상.

### 3.4 응답 surface

기존 `keeper_task_create`의 JSON 응답 구조와 동일 (`error_to_json` 그대로). 4 caller 응답 surface 통일:

- `masc_add_task`: 현재 `(false, "Error: ...")` 튜플 반환 → `Error: <message>` 형식 유지. 클라이언트 측 변경 불필요.
- `task_dispatch`: 동일.
- `tool_inline_dispatch_coord`: 동일.
- `operator_control`: 동일.

## 4. Migration

### 4.1 호출 사이트 변경
- 4 caller에 `~reject_if:(...)` 한 줄 추가.
- `keeper/keeper_exec_task.ml` 1 caller은 `Keeper_exec_task` → `Coord_task_capacity` 모듈 호출로 변경.

### 4.2 응답 contract 안정성
JSON 응답 형식 동일 — `error_to_json` 그대로. `keeper_task_create`의 기존 응답 client(autonomous keepers, dashboard 등)는 변경 불필요.

### 4.3 회귀 테스트
- `test_keeper_task_dispatch.ml` 의 기존 `test_create_rejects_fourth_open_task_for_goal` 테스트는 #13981에서 추가됨 — 그대로 유지.
- 신규 테스트 4건 추가:
  - `test_masc_add_task_caps_per_goal` — masc_add_task가 4번째 같은 goal_id 거부
  - `test_task_dispatch_caps_per_goal` — task_dispatch path 거부
  - `test_inline_dispatch_caps_per_goal` — inline dispatch path 거부
  - `test_operator_task_inject_caps_per_goal` — operator path 거부

## 5. TLA+ Spec 매핑

`~/me/.tmp/loop-masc-fsm/spec/GoalCapEntrypoint.tla`:
- 현 main = `GuardedEntrypoints = {"keeper_task_create"}` (1/5)
- RFC-0034.v2 적용 후 = `GuardedEntrypoints = Entrypoints` (5/5)

`SpecBuggy`(현재)에서 `CapInvariant` 위반 1-3 step. `SpecClean`(적용 후) 위반 불가능.

## 6. Risks

- **fixture 의존성**: 같은 goal에 4+ task 만드는 test fixture가 있으면 깨짐. PR 작업 중 발견 시 fixture 수정.
- **autonomous keeper 갑작스러운 거부**: 기존엔 cap 우회로 무한 만들던 keeper가 이제 거부 응답 받음. JSON `error_kind=goal_task_limit_exceeded` 핸들링 필요. 대부분 keeper는 이미 `keeper_task_create` 거부 응답 처리 중.
- **모듈 이전 의존성**: `Keeper_exec_task` ↔ `Coord_task_capacity` 의존성 변경. dune 파일 의존성 그래프 재확인 필요.

## 7. Implementation Plan

| 단계 | 산출물 | LOC 추정 |
|---|---|---|
| S1 | `lib/coord/coord_task_capacity.{ml,mli}` 신설 (#13981 코드 이전) | ~110 |
| S2 | `lib/keeper/keeper_exec_task.ml` 정리 (38 LOC delete + ~5 호출 변경) | -38 / +5 |
| S3 | 4 caller에 `~reject_if` 추가 | +4 lines |
| S4 | 회귀 테스트 4건 | +60 |
| S5 | dune build + 기존 test green | — |
| S6 | Draft PR + RFC 인용 | — |

총 변경: **+~70 LOC, -38 LOC, 단일 PR**.

## 8. Verification

- `scripts/dune-local.sh build`
- 기존 + 신규 회귀 테스트 모두 green
- `bash ~/me/scripts/pr-rfc-check.sh` PASS

## 9. References

- #13981 (이미 머지됨)
- iter-1~5: `~/me/.tmp/loop-masc-fsm/iter-{1..5}.md`
- TLA+ spec: `~/me/.tmp/loop-masc-fsm/spec/GoalCapEntrypoint.tla`
- 모듈 sketch: `~/me/.tmp/loop-masc-fsm/spec/Coord_task_capacity.{ml,mli}`
