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
| `raw_trace_run_ref` | exact OAS run ref option | 완료된 provider dispatch result |

`raw_trace_run_ref`는 `worker_run_id`, `path`, `start_seq`, `end_seq`,
`agent_name`, `session_id`를 보존한다. Decoder는 run ref의 agent/session
identity가 record의 agent/trace identity와 다르면 현재 record로 인정하지 않는다.
필드가 없는 과거 row를 읽는 migration이나 fallback은 없다.

## 2. 읽기 경계

`Keeper_autonomous_turn_source`는 최신 current-schema turn record를 index로
사용하고 `turn_kind = Autonomous`인 row만 선택한다. 본문은 그 row가 가리키는
단일 exact run을 `Raw_trace_query.summarize_run`으로 읽는다. 한 파일의 여러
provider run을 합치지 않는다.

Public `/chat/history`에는 final text, timestamp, model, stop reason,
`turn_ref`, agent identity, generation만 투영한다. Raw thinking, assistant
blocks, tool arguments, tool results는 이 surface에 존재하지 않는다.

Raw trace path는 해당 keeper의 `raw-traces` directory에 있는 regular JSONL
file이어야 한다. 다른 경로, 삭제된 file, incompatible record, summary failure는
명시적으로 log하고 skip한다.

## 3. 보존과 UI cap

Writer와 reader의 bound는 모두 200이다. Disk retention 밖의 본문을 UI가 볼
수 있다고 주장하지 않는다. Dashboard thread cap 200은 direct conversation에만
적용하며, server에서 별도 bound된 autonomous rows는 direct rows를 축출하지 않는다.

## 4. 저장 경계

자율턴은 `Keeper_chat_store`에 기록하지 않는다. Wake marker와 자율 출력이
keeper의 다음 `recent_direct_conversation` 입력으로 되돌아가는 feedback loop를
RFC-0351 §5가 닫았기 때문이다. Turn record와 raw trace는 read-only dashboard
projection이며 keeper prompt 입력이 아니다.

## 5. 검증 계약

- 직접 사용자가 wake marker와 같은 text를 보내도 `Direct` record는 제외한다.
- 한 trace file에 여러 provider run이 있어도 record가 지목한 run만 투영한다.
- Public autonomous row에는 thinking/tool block field가 없다.
- Agent/session identity mismatch와 keeper trace directory 밖 path를 거부한다.
- Autonomous row volume은 200개의 direct conversation slot을 소비하지 않는다.
