# RFC-0358 — 자율턴 판별은 prompt 문자열이 아니라 turn record의 typed turn kind로 한다

- Status: Draft
- Created: 2026-08-04
- Related: RFC-0351 §5 (#25462, wake marker를 durable transcript에서 제외), RFC-0233 §7 (`turn_ref` join key)
- Blocks: 없음 — 현재 동작은 `Keeper_unified_prompt.is_autonomous_wake_prompt`로 성립한다. 본 RFC는 그 대체재다.

## 1. 배경

대시보드 채팅은 keeper 자율턴 이력을 표시하지 못했다. 원인은 결함이 아니라 저장 경계다.

- 자율턴은 `Keeper_chat_store`에 행을 남기지 않는다. RFC-0351 §5가 wake marker를 durable transcript에서 제외했고(한 keeper가 동일 147B 메시지를 359회 누적), `Keeper_types_support.turn_effect_record`가 도구 없는 wake를 `Inert_autonomous_turn`으로 분류한다.
- 본문은 `.masc/keepers/<name>/raw-traces/turn-*.jsonl`에만 있다. `Keeper_agent_run`이 쓰고, 본 RFC 이전까지 **reader가 0건**이었다.

`Keeper_autonomous_turn_source`가 그 reader이며, 이 RFC는 그 모듈이 쓰는 판별 방식의 대체를 다룬다.

## 2. 현재 상태 (head-pinned)

1. `lib/keeper/keeper_unified_turn_execution.ml:196` — 자율 사이클이 `Keeper_agent_run.run_turn`을 호출한다.
2. `lib/keeper/keeper_turn.ml:792` — 직접 `masc_keeper_msg` 턴도 **같은** `Keeper_agent_run.run_turn`을 호출한다.
3. 따라서 raw-trace 스토어에는 두 종류가 섞인다. 직접턴은 이미 chat store에 있으므로, 구분 없이 투영하면 대시보드에 **두 번** 렌더된다.
4. raw-trace record에는 turn kind가 없다. 실측 필드(2026-08-04, lane-smith 201 파일): `trace_version, worker_run_id, seq, ts, agent_name, session_id, record_type` + record별 필드(`prompt/model`, `block_kind/assistant_block`, `tool_name/tool_input/tool_execution_mode`, `final_text/stop_reason`). `turn_ref`도 `absolute_turn`도 없다.
5. `lib/keeper/keeper_turn_record_writer.mli:8` — turn record는 `trace_id`/`absolute_turn`/`turn_ref`를 갖지만 **본문이 없고**, raw-trace 파일로의 포인터도 없다.

## 3. 현재 판별과 그 한계

`Keeper_unified_prompt.is_autonomous_wake_prompt`는 기록된 `run_started.prompt`를 `autonomous_wake_marker` 상수와 동등 비교한다. `Keeper_agent_run_finalize_response.ml:79`가 이미 같은 상수를 같은 방식으로 비교하므로 새 분류기가 아니라 기존 SSOT의 재사용이다.

한계는 둘이다.

1. **prompt 구성이 바뀌면 조용히 깨진다.** 마커는 표현이지 신원이 아니다. HITL resolution이 붙는 wake처럼 user turn 내용이 달라지는 경로가 생기면 판별이 빠진다.
2. **retention 밖 구간을 복구할 수 없다.** 본문은 `raw_trace_retained_turn_files`까지만 남는다. 그보다 오래된 자율턴은 turn record에 토큰·지연시간이 남아 있으나, 그 record가 자율턴인지 알 방법이 없어 "이 구간에 자율턴 N건이 있었다"조차 표시하지 못한다.

## 4. 제안

turn record에 두 필드를 추가한다. 둘 다 masc 소유 저장소이므로 OAS 경계를 건드리지 않는다.

| 필드 | 타입 | 근거 |
|---|---|---|
| `turn_kind` | closed variant (`Autonomous` \| `Direct`) | 판별을 표현이 아니라 신원으로. 호출부가 이미 알고 있는 사실(`Keeper_unified_turn` 경로 vs `Keeper_turn` 경로)을 기록만 하면 된다. |
| `raw_trace_run_ref` | `{ path; start_seq; end_seq }` option | turn record(장기)와 본문(retention 내)을 정확히 연결. `Agent_sdk.Raw_trace.run_ref`가 이미 이 shape이고, `keeper_types_support.ml:87` 주석이 "Each turn's run_ref … is the index into this store"라고 명시하나 현재 전파되지 않는다. |

`Keeper_autonomous_turn_source`는 raw-trace 디렉토리 스캔 대신 turn record를 인덱스로 삼고, 본문이 남아 있으면 `run_ref`로 읽고 없으면 메타만 투영한다.

## 5. 검증

- `turn_kind`가 두 진입점 각각에서 기대값으로 기록되는지 turn record 단위 테스트.
- 직접턴이 자율턴 투영에서 제외되는 성질을 prompt가 아니라 `turn_kind`로 재작성 (`test_keeper_autonomous_turn_source.ml`의 "excludes a direct turn").
- retention 경계를 넘긴 turn record가 본문 없이 메타만으로 투영되는 경로 테스트.
- 마이그레이션 코드는 두지 않는다 (projects.md: 레거시 필드/마이그레이션 구현 금지). 필드가 없는 기존 record는 `turn_kind` 부재 = 투영 제외로 처리하고, 새 record부터 정확해진다.

## 6. 범위 밖

- raw-trace 포맷 변경 (OAS 소유). turn kind를 OAS record에 넣는 대안은 경계를 역행하므로 채택하지 않는다.
- 자율턴을 chat store에 기록하는 방안. RFC-0351 §5가 닫은 피드백 루프를 다시 연다: `Keeper_chat_store.load`가 keeper의 `recent_direct_conversation` observation 입력이므로, 자기 출력이 자기 다음 입력이 된다.
