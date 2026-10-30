---
title: 툴 종류(tool kind)는 닫힌 합타입으로 선언한다
rfc: "0386"
status: Draft
created: 2026-08-19
author: vincent
related: ["0378", "0179"]
---

# RFC-0386 — 툴 종류(tool kind)는 닫힌 합타입으로 선언한다

## 1. 결정

Keeper 툴 하나가 "단일 실행 단위인지, 합성/배치 실행 단위인지" 를 닫힌
합타입으로 선언한다. 타입은 `Keeper_tool_descriptor.tool_kind` 다.

```ocaml
type tool_kind =
  | Atomic_tool              (* 한 호출 = 한 capability 실행 *)
  | Composition_tool         (* 카탈로그 고정 plan, inline 실행 *)
  | Async_composition_tool   (* durable async 합성 + status/cancel 컨트롤 *)
  | Batch_plan_tool          (* 모델 정의 plan을 하나의 DAG 로 실행 *)
```

실행 기계는 새로 만들지 않는다. 이미 존재하는 것들을 이 분류가 가리킬
뿐이다:

- `packages/agent_core/lib/agent/agent_tool_batch_plan.ml` — Serial /
  Concurrent 배치 계획, `agent_tools.ml` 의 `execute_tools`
- `lib/keeper/keeper_tool_plan.ml` — 닫힌 typed plan IR 과
  `Keeper_tool_plan_executor`
- `lib/keeper/keeper_tool_composition_catalog.ml` — TOML 카탈로그
  (Inline / Async), `keeper_tool_composition_surface.ml` 의
  `keeper_plan_execute`, `keeper_composition_status`, `keeper_composition_cancel`

`execution` 필드(`Ordinary Serial/Concurrent | Terminal`) 와 직교하는
축이다. `execution` 은 호출이 "어떻게" 실행되는지, `tool_kind` 는 호출이
"무엇을" 담고 있는지를 분류한다.

constitution feature_surface 용어와의 1:1 매핑:

| feature_surface | tool_kind | 코드 대응물 |
|---|---|---|
| Multitools | `Composition_tool` | 카탈로그 `keeper_compose_*` (inline) |
| AsyncTools | `Async_composition_tool` | async 카탈로그 엔트리 + `keeper_composition_status` / `keeper_composition_cancel` |
| Batch Tools | `Batch_plan_tool` | `keeper_plan_execute` |
| (기본) | `Atomic_tool` | 나머지 모든 descriptor-backed 툴 |

## 2. 배경

parity matrix B6("Batch/Multitool 실행 개념 부재")의 선행 조사 결론:
실행 기계는 존재하지만, "이 툴이 합성/배치 실행 단위다" 를 선언하는 닫힌
합타입이 descriptor/카탈로그 수준에 없었다. 도구 분류는
discovery 전용 분류라 실행 의미를 얹을 수 없다. 이 RFC 가 그 선언층을
추가한다.

## 3. 선언 위치

- `Keeper_tool_descriptor.t.tool_kind` — descriptor-backed 툴은 전부
  `Atomic_tool` 로 선언된다. 빌더(`descriptor`)의 기본값이며, 문자열
  분류는 없다.
- `Keeper_tool_composition_catalog.tool_kind` — 엔트리의
  `execution : Inline | Async` 에서 타이프드하게 유도한다
  (Inline → `Composition_tool`, Async → `Async_composition_tool`).
  `status_tool_kind` / `cancel_tool_kind` 는 `Async_composition_tool` 다.
- `Keeper_tool_composition_surface.plan_execute_tool_kind` —
  `Batch_plan_tool`.

parse 는 strict 하다. `tool_kind_of_string` 은 알 수 없는 문자열을
`Error` 로 거부하며, 어떤 폴백 분류도 하지 않는다.

## 4. 노출

두 경로가 있다. 어느 쪽도 문자열 매칭으로 분류하지 않는다.

1. **descriptor-backed 툴** — `route_evidence_json` 과
   `discovery_fields` 가 `"tool_kind"` 필드를 실는다(현재 전부
   `"atomic"`).
2. **composition surface 툴** — `keeper_compose_*`,
   `keeper_plan_execute`, `keeper_composition_status/cancel` 은 TOML
   카탈로그에서 구체화되는 `Agent_core.Tool.t` 이며 Keeper descriptor
   registry 에 속하지 않는다(`Keeper_tool_descriptor_resolution` 이
   `None` 을 반환). 따라서 descriptor route evidence 경로는 이 툴들을
   커버하지 않고, kind 는 이 툴들 자신의 관측 경로에 실린다:
   - 실행/제출 결과 payload (`result_of_execution`, `failure_data`,
     async submission, status/cancel 결과) 의 `"tool_kind"` 필드
   - 노드별 tool-call log envelope 의 `"composition_tool_kind"` 필드
     (typed `?composition_tool_kind` 파라미터로 전달)
   - 호출 route evidence: `route_evidence_json_of_tool_io` 가 출력
     payload 의 `"tool_kind"` 를 흡수한다. composition 툴 호출의
     `route_evidence` 에 kind 가 나타난다.

## 5. 범위 밖

- 새 실행 엔진 — 금지. 기존 기계를 재사용한다.
- keeper 툴의 `Concurrent` 선언 확대 — 별도 PR.
- MCP 경로 배치 실행 — 이 RFC 의 대상이 아니다.

## 6. 검증

`test/test_keeper_tool_kind.ml`:

- 4개 생성자의 `tool_kind_to_string` / `tool_kind_of_string` 왕복과 문자열
  유일성.
- unknown 문자열 거부(fail-closed).
- 전체 descriptor 가 `Atomic_tool` 을 선언하고 route/discovery evidence 에
  `"tool_kind": "atomic"` 이 실리는지.
- 카탈로그 inline/async 엔트리와 status/cancel 컨트롤,
  `keeper_plan_execute` 의 kind 태깅.
- composition surface 툴의 실제 관측 경로: status/cancel 결과 payload 에
  `"tool_kind": "async_composition"` 이 실리고, composition/batch_plan 툴
  호출의 route evidence 에 각각 `"composition"` / `"batch_plan"` 이
  나타나는지.
