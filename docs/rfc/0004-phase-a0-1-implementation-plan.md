# RFC-0004 Phase A0.1 — implementation plan (`Sse_event` typed envelope)

Status: Completed (2026-05-17)
Companion to: docs/rfc/RFC-0004-shared-contract-ocaml-ts.md §Phase A0
Related: PR #15745 (quick-win null guard), PR #15747 (RFC-0004 body resume), me PR #1125 (research synthesis)

## Completion summary (2026-05-17)

All sub-PRs merged.  Every `Agent_sdk.Event_bus` variant arm in
`lib/runtime/runtime_event_bridge.ml` routes through a typed
`Sse_event` constructor.  The `wrap_event` helper remains live for
the catch-all kind-only fallback (warning 11 idiom, defending the
OAS pin-bump P0 class — see plan §4 row "PR-4" completion criteria).

| Sub-PR | PR # | Merged | Events |
|---|---|---|---|
| PR-1 (atd + lib base + PoC) | #15807 | 2026-05-17 | agent_started |
| PR-2 (AgentStarted arm migrate) | #15811 | 2026-05-17 | (migration only) |
| PR-3 (5 tool/turn arms) | #15824 | 2026-05-17 | tool_called, tool_completed, turn_started, turn_completed, turn_ready |
| PR-4 (8 handoff/context/replacement/slot arms) | #15830 | 2026-05-17 | handoff_requested, handoff_completed, context_compacted, context_overflow_imminent, context_compact_started, content_replacement_replaced, content_replacement_kept, slot_scheduler_observed |
| PR-3b (variable-shape addendum) | #15835 | 2026-05-17 | agent_completed, agent_failed |

### Scope adjustments vs original plan

- **PR-3 split into PR-3 + PR-3b**: `AgentCompleted` / `AgentFailed`
  carry a payload tail produced by helpers that close over
  `Agent_sdk.Types.api_response` and `Agent_sdk.Error.t`.  Pulling
  those into the leaf event library would have re-introduced the
  `Agent_sdk` dependency the migration is meant to localise.  PR-3
  shipped the 5 simple-record arms; PR-3b added the
  caller-supplied addendum pattern
  (`merge_addendum_into_record` + `~result_fields` / `~error_fields`)
  to cover the remaining two arms without leaking the dep.

- **`wrap_event` retained**: The catch-all arm
  (`runtime_event_bridge.ml` near line 831) emits a kind-only
  placeholder for any unmigrated OAS variant.  This path stays on
  `wrap_event` by design — see plan §4 footnote on the warning-11
  catch-all.

### Verification harness

`test/sse_event/test_sse_event.ml` carries one byte-equal test per
event (19 cases total: 14 envelopes + 1 `json_string_opt` regression
+ 4 PR-3b cases including the empty-addendum guard).  The baseline
algorithm is an inline replica of `wrap_event` + `json_string_opt`,
deliberately re-stated in the test file to avoid linking the heavy
`runtime` dependency chain.  Any future change to the wire envelope
must update both the runtime emitter and the inline replica — the
test will diverge until both sides match.

### What this unlocks (next phases)

Phase A0.2 work (TypeScript decoder generation, golden-file replay,
CLI emitter) can now consume `lib/sse_event/sse_event.atd` as a SSOT
without any per-event work on the OCaml side.  The atd file is the
contract; the runtime arms are the publishers; the test harness is
the gate.

## 1. 작업 범위 재정의 (research 후속)

`lib/runtime/runtime_event_bridge.ml` 분석 결과 (2026-05-17):

- `Agent_sdk.Event_bus.payload` 는 **이미 upstream typed variant** (16 case)
- SSE 경계에서 ad-hoc `Yojson.Safe.t` `Assoc` 직접 조립 — typed envelope 부재
- `wrap_event` 함수 (`lib/runtime/runtime_event_bridge.ml:507-531`) 가 모든 event 의 공통 envelope 정의

→ Phase A0.1 의 정확한 작업은 **SSE wire envelope 의 typed 표현** 도입. Upstream variant 새로 만드는 작업 아님.

## 2. atd 통합 결정 (open question — RFC-0004 §8 후속)

원래 RFC-0004 sprint 표:
- A0.1 = typed variant (manual)
- A0.2 = atd schema

**문제**: A0.1 에서 manual variant 작성 → A0.2 에서 atd-generated 로 대체. 같은 코드를 두 번 작성하는 비효율.

**제안**: **A0.1 ⊕ A0.2 통합** — atd 도입을 A0.1 sprint 일부로 흡수.

| 옵션 | 장점 | 단점 |
|---|---|---|
| **분리 (현 RFC)** | manual variant 가 atd 도입 전 빠른 검증 | 같은 코드 2번 작성, A0.1 산출물 단기 dead |
| **통합 (제안)** | atd schema 가 first-class artifact, manual variant 안 거침 | atd dependency (atdgen) 가 첫 PR 에 들어감 |

근거: ahrefs/atd 활성도 양호 (4.2.0 release 2026-04-26), PR #15747 comment 참조. dependency burden 낮음.

→ **결정 영역** (사용자 합의 필요): 통합 vs 분리. 본 plan 은 통합 가정으로 작성.

## 3. SSE envelope schema (atd 후보)

`wrap_event` (runtime_event_bridge.ml:507) 의 emit 형식 그대로 매핑:

```atd
(* lib/sse_event.atd *)

type sse_envelope = {
  ~type_ <ocaml name="type_field">: string;  (* "oas:<event_type>" *)
  event_type: string;
  ts_unix: float;
  correlation_id: string;
  run_id: string;
  ?agent_name: string option;
  ?task_id: string option;
  ?turn: int option;
  ?tool_name: string option;
  payload: oas_payload;
}

type oas_payload = [
  | Agent_started <json name="agent_started"> of agent_started_payload
  | Agent_completed <json name="agent_completed"> of agent_completed_payload
  | Agent_failed <json name="agent_failed"> of agent_failed_payload
  | Tool_called <json name="tool_called"> of tool_called_payload
  | Tool_completed <json name="tool_completed"> of tool_completed_payload
  | Turn_started <json name="turn_started"> of turn_started_payload
  | Turn_completed <json name="turn_completed"> of turn_completed_payload
  | Turn_ready <json name="turn_ready"> of turn_ready_payload
  | Handoff_requested <json name="handoff_requested"> of handoff_requested_payload
  | Handoff_completed <json name="handoff_completed"> of handoff_completed_payload
  | Context_compacted <json name="context_compacted"> of context_compacted_payload
  | Context_overflow_imminent <json name="context_overflow_imminent"> of context_overflow_imminent_payload
  | Context_compact_started <json name="context_compact_started"> of context_compact_started_payload
  | Content_replacement_replaced <json name="content_replacement_replaced"> of content_replacement_replaced_payload
  | Content_replacement_kept <json name="content_replacement_kept"> of content_replacement_kept_payload
  | Slot_scheduler_observed <json name="slot_scheduler_observed"> of slot_scheduler_observed_payload
]

(* Sample payload definitions *)

type agent_started_payload = {
  agent_name: string;
  task_id: string;
}

type agent_completed_payload = {
  agent_name: string;
  task_id: string;
  elapsed_s: float;
  (* result-specific fields appended at runtime — see §5 schema-vs-runtime drift *)
}

(* ... 14 other payload types *)
```

### Note: `event_type` ↔ `payload` discriminator 일관성

현 envelope 은 **두 곳** 에 event type 정보를 emit:
- `type` field (with `oas:` prefix) — frontend `isSSEEventType` 분기
- `event_type` field (without prefix) — runtime metadata
- `payload` 의 atd polymorphic variant constructor — sum type tag

atd `oas_payload` variant constructor 이름 (`Agent_started` 등) 이 wire `event_type` literal 과 1:1 매핑되도록 `<json name="...">` annotation 명시. atdgen 이 자동 일치 검증.

## 4. Sub-PR sequencing (Wave 1 = 16 runtime events)

| PR | 산출물 | 변경 site | 추정 LOC |
|---|---|---|---|
| **A0.1-PR-0** (이 plan) | docs/rfc/0004-phase-a0-1-implementation-plan.md | docs only | ~150 |
| **A0.1-PR-1** | atd schema + atdgen dune wiring + envelope+payload type 정의 (모든 16 variant skeleton, body=`[]`) | `lib/sse_event.atd`, `dune` rule, no callsite change | ~300 |
| **A0.1-PR-2** | AgentStarted/Completed/Failed migrate (3 events) — `wrap_event` → `Sse_event.to_yojson`. Byte-equal golden test 3개 | `lib/runtime/runtime_event_bridge.ml` (3 arms), `test/test_sse_event_golden.ml` | ~250 |
| **A0.1-PR-3** | Tool/Turn migrate (5 events: ToolCalled/Completed, TurnStarted/Completed/Ready) | 동상 | ~200 |
| **A0.1-PR-4** | Handoff/Context/Content/Slot migrate (8 events) | 동상 | ~350 |

각 PR 의 완료 기준:
- `dune build @check` PASS
- `dune build @runtest` PASS (golden test 포함)
- emit byte-equal vs pre-migration baseline (golden test 강제)
- catch-all `_ -> kind-labelled placeholder` (warning 11 idiom) 유지 — OAS pin-bump P0 방어

## 5. Byte-equal golden test 프로토콜

마이그레이션 안전성의 핵심. 각 PR 에서:

1. Pre-migration baseline 캡처:
   - `lib/runtime/runtime_event_bridge_capture.ml` 도구 — fixed `Agent_sdk.Event_bus.event` 입력 → 현 `wrap_event` 가 emit 한 JSON string 을 `test/golden/sse_event_<name>.json` 으로 저장
   - **PR-1 머지 *전*** baseline 캡처 (PR-1 머지 직후 frozen)
2. Post-migration 검증:
   - 새 `Sse_event.to_yojson` 가 동일 입력에 대해 *바이트 동일* JSON emit
   - `Alcotest.check string` 으로 비교 (whitespace/key-order 포함)
3. atdgen 의 `_j.ml` 출력 형식이 hand-written `Assoc` 과 다를 가능성:
   - **검증 단계**: PR-1 안에서 1 event 만 골라 차이 측정
   - 차이 시: atdgen `<json>` adapter 또는 post-process step. **이 결과가 A0.1 의 *go/no-go* gate**

### Wave 1 진입 사전 검증

본 plan 의 가장 큰 risk = atdgen 의 JSON 출력이 현 hand-coded `Assoc` 와 byte-different. 그래서:

- **PR-1 의 첫 commit** = `AgentStarted` 1개 event 만으로 round-trip 검증 (atdgen → JSON → frontend SSEMessageSchema parse PASS)
- 차이 발견 시 PR-1 close + risk RFC 작성 후 재시작
- Pass 시 PR-1 의 나머지 15 variant skeleton 추가

## 6. Dependencies & dune wiring

```
+-------------------------------+
|  lib/sse_event.atd            |    <-- single source
+-------------+-----------------+
              |
              v
   atdgen -t -j   (build rule)
              |
              v
+-------------------------------+
|  lib/sse_event_t.ml/.mli      |    <-- type only
|  lib/sse_event_j.ml/.mli      |    <-- JSON ser/deser
+-------------+-----------------+
              |
              v
+-------------------------------+
|  lib/sse_event.ml             |    <-- convenience wrappers, to_envelope
+-------------+-----------------+
              |
              v
+-------------------------------+
|  lib/runtime/runtime_event_bridge.ml   <-- callsite
+-------------------------------+
```

`(rule (alias gen) (deps sse_event.atd) (action (...atdgen...)))` 패턴. atdgen 의존성 `(libraries atd atdgen-runtime)`.

## 7. 비범위 (out of scope for A0.1)

- 다른 emitter (`lib/keeper/keeper_approval_queue.ml`, `lib/keeper/keeper_gate.ml`, `lib/server/server_dashboard_http*.ml`) 의 ad-hoc Yojson — **Wave 2 이후**
- Frontend TS gen (atdts) — **A0.3**
- `SSEMessageSchema` 교체 — **A0.4**
- OAS event passthrough 정책 — **A0.2 또는 별 RFC**

본 plan 은 *runtime_event_bridge.ml 한정* (16 event, 49 site 중 11+5 site, 약 33%).

## 8. 사용자 결정 필요 항목

| # | 결정 영역 | 옵션 |
|---|---|---|
| 1 | atd 통합 (§2) | (a) A0.1+A0.2 통합 / (b) RFC 원안대로 분리 |
| 2 | catch-all warning 11 idiom | (a) atd-generated 에선 제거 (exhaustive 강제) / (b) wrapper layer 에 유지 (OAS pin-bump 방어) |
| 3 | Wave 1 시작 시점 | (a) 본 plan PR 머지 즉시 PR-1 / (b) RFC body (PR #15747) 머지 후 |

각 항목 사용자 합의 후 PR-1 진입.

## 9. Open follow-ups

- frontend SSEEventType 68 vs backend distinct emit 39 = gap 29. 별도 inventory 필요 (`lib/keeper/`, `lib/server/server_dashboard_http*.ml` 분포 — Wave 2 작업)
- IDE crash root cause = `AnchoredThread` 가공 layer (research §6 별 트랙). A0.4 에서 nested 검증 도입 시 자동 해결 예상
- atd schema repo 위치 — `lib/sse_event.atd` (lib 내부) vs `schema/sse_event.atd` (top-level). 본 plan 은 lib 내부 가정

## 10. 다음 step

본 PR (A0.1-PR-0) 머지 후:

1. 사용자 §8 3개 결정
2. atdgen 의존성 dune 검증 (`opam list atdgen` + masc dune-project)
3. PR-1 진입 — atd schema + AgentStarted 1 event round-trip 검증 → 16 variant skeleton
