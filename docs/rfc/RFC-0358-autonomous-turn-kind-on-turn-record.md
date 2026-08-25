---
rfc: "0358"
title: "자율턴 신원과 exact raw-trace run을 turn record가 소유한다"
status: Implemented
created: 2026-08-04
related: ["0351", "0233"]
---

# RFC-0358 — 자율턴 신원과 exact raw-trace run을 turn record가 소유한다

## 1. 결정

현재 `Turn_record.t`가 다음 사실을 필수 필드로 소유한다.

| 필드 | 타입 | 생산자 |
|---|---|---|
| `turn_kind` | `Autonomous | Direct` | 자율/직접 진입점 |
| `agent_name` | `string` | 실행에 사용한 keeper metadata |
| `generation` | `int` | 실행 generation |
| `raw_trace_run_ref` | exact agent_core run ref option | 완료된 provider dispatch result |

`raw_trace_run_ref`는 `worker_run_id`, `path`, `start_seq`, `end_seq`,
`agent_name`, `session_id`를 보존한다. Record의 `agent_name`은 Keeper identity이고
run ref의 `agent_name`은 agent_core runtime identity이므로 서로 비교하지 않는다. Decoder는
run ref의 session identity가 record의 trace identity와 다르면 현재 record로
인정하지 않는다. Reader는 선택된 raw row의 agent_core runtime/session identity가 run ref와
다르면 해당 turn을 투영하지 않는다.
필드가 없는 과거 row를 읽는 migration이나 fallback은 없다.

## 2. 읽기 경계

`Keeper_autonomous_turn_source`는 최신 current-schema turn record를 index로
사용하고 `turn_kind = Autonomous`인 row만 선택한다. 본문은 그 row가 가리키는
단일 exact run을 `Raw_trace_query.read_run`으로 읽고 허용된 activity field만
투영한다. 한 파일의 여러 provider run을 합치지 않는다.

Thinking 단계의 존재는 `Trace_think`의 `content_withheld = true`로 나른다.
문구가 아니라 flag가 그 사실을 나르므로, 표시 문구는 읽는 쪽이 정하고 서버는
언어를 소유하지 않는다. Encoder와 decoder 양쪽이 `content_withheld = true ==>
text = ""`를 강제해 caller 실수로도 reasoning text가 이 경계를 넘지 못한다.
`thinking_block`의 `redacted`(provider가 signature만 보낸 경우)와는 원인이
다르므로 같은 field로 합치지 않는다.

Public `/chat/history`에는 final text, timestamp, `turn_ref`와 exact run의
content-free activity trace만 투영한다. Activity trace는 thinking 단계의 존재와
timestamp, tool name/status/duration만 포함한다. Raw thinking, assistant blocks,
tool call id, tool arguments, tool results는 이 surface에 존재하지 않는다.

Raw trace path는 해당 keeper의 `raw-traces` directory에 있는 regular JSONL
file이어야 한다. 다른 경로, current window 안에서 예기치 않게 삭제된 file,
incompatible record, summary failure는 명시적으로 log하고 skip한다.
`raw_trace_run_ref = None`은 sink degrade 또는 exact run 생성 전 종료를 뜻하는
typed absence이므로 경고 없이 skip한다.

## 3. 보존과 UI cap

Reader와 retention은 동일한 최근 TurnRecord 200행을 단일 경계로 사용한다.
Retention은 그 window의 exact `raw_trace_run_ref`를 reachability root로 보호한다.
파일 생성 순서나 파일 개수만으로 삭제 대상을 고르지 않는다. Cleanup은 현재
TurnRecord commit 시도 뒤에만 실행하므로 반쯤 작성된 sink를 삭제 대상으로 보지
않는다. Window 밖의 참조와 참조되지 않은 완료/중단 trace만 정리한다. TurnRecord
window를 읽거나 decode할 수 없으면 cleanup은 fail-open으로 아무것도 삭제하지
않으며 Keeper turn을 막지 않는다. 삭제 파일 수, reachability root 불확실성으로
건너뛴 횟수, unlink 실패 수는 각각 typed counter로 노출한다.

Dashboard thread cap 200은 direct conversation에만 적용하며, server에서 별도
bound된 autonomous rows는 direct rows를 축출하지 않는다.

## 4. 저장 경계

자율턴은 `Keeper_chat_store`에 기록하지 않는다. Wake marker와 자율 출력이
keeper의 다음 `recent_direct_conversation` 입력으로 되돌아가는 feedback loop를
RFC-0351 §5가 닫았기 때문이다. Turn record와 raw trace는 read-only dashboard
projection이며 keeper prompt 입력이 아니다.

## 5. 검증 계약

- 직접 사용자가 wake marker와 같은 text를 보내도 `Direct` record는 제외한다.
- 한 trace file에 여러 provider run이 있어도 record가 지목한 run만 투영한다.
- Public autonomous row의 activity trace에는 raw thinking, tool call id,
  arguments, result가 없다.
- Raw row와 run ref의 agent_core runtime/session identity mismatch 및 keeper trace
  directory 밖 path를 거부한다.
- Autonomous row volume은 200개의 direct conversation slot을 소비하지 않는다.
