# 감사 4/8 전수 판정 — 2026-11-08 (task-3364 취합 문서)

작성: claude-62be833e. 감사 원문: board:p-3bb9d4c029c48387f73839996b27b115 및
jeong-sik/masc#49743. 모든 좌표는 main 2731fb37085d(판정 시점 origin/main)에서
재직독해 판정했다(전용 재검증 에이전트 보고: 수신자·생산자 전수 조사 포함).
수리 커밋은 이 PR 에 실려 있다.

## 항목 1 별칭 키 이중 방출 — 수리 4 + 철회 2

| 좌표 | 판정 | 근거 |
| --- | --- | --- |
| `keeper_runtime_trust_snapshot.ml:999-1005` "phase"+"raw_phase", "active_model"+"selected_model" | **수리** | "raw_phase"·"selected_model" 을 이 스냅샷 수준에서 읽는 곳은 TS 에 없음(TS raw_phase 는 runtime_attention 객체의 별도 방출이 "phase"에서 재생산). 정정: selected_model 은 OCaml 소비자가一处 있었다 — keeper_status_detail_observability.selected_model_of_runtime_trust 가 스냅샷 최상단 "selected_model"을 먼저 읽었다(적대적 리뷰 F2 적발). 살아남은 정식 방출 "active_model"(같은 값)을 읽게 바꾸고 증거 라벨과 시험을 함께 갱신한다 |
| `dashboard_execution.ml` upsert "trust"+"runtime_trust" | **수리** | "trust" 를 우선하는 독자는 없고 나머지 생산자 전부 "runtime_trust" 만 쓴다. "trust" upsert 삭제 + OCaml 독자 2곳(existing_keeper_trust_json·keeper_runtime_trust_json 폴백) + TS `?? .trust` 4곳(keeper-store-normalize·store-normalizers·mission-normalizers·operator-normalizers) + 시험 fixture 7건을 함께 정리(hard cut) |
| `dashboard_execution_builders.ml:201-202` "recent_output_preview"+"recent_event" | **수리** | 같은 값 두 키. TS 는 둘 다 읽지만 렌더는 recent_output_preview 만 사용. "recent_event" 방출·판독·타입 필드(dashboard-execution.ts·dashboard-mission.ts) 제거. ("status"/"tone"/"state" 는 **철회** — 서로 다른 투영: 원본 enum·신선도 유도 상태·색조. state "quiet" 가 Tone_bad·Tone_warn 둘 다 돼서 tone 은 state 의 함수도 아님) |
| `dashboard_http_keeper_trust.ml` "approval"+"approval_state", "execution"+"execution_summary" | **수리** | 스냅샷 정식 이름은 "approval"/"execution"(:786-787/:1015-1016). 별칭 재생산 3곳(http_keeper_trust:77-78 삭제, dashboard_execution compact 103-104 정식 이름으로, operator_control_snapshot_trust:59 정식 이름으로) + TS 폴백 2곳(keeper-store-normalize:400-401, dashboard-goals:299-301) 제거. TS 내부 저장 필드명 approval_state/execution_summary 는 유지 — 내부 이름이지 wire 키가 아님. ("operator_disposition" vs "disposition" 은 **철회** — 스냅샷이 두 쌍을 정식 생산(:280-283): 영수증이 전달하는 운영자 처분 vs trust 모델 자체 처분, 서로 다른 개념) |

## 항목 2 Decoder 다단 폴백 — 해소 1 + 판정 3

| 좌표 | 판정 | 근거 |
| --- | --- | --- |
| `reliable_change_g1.ml:1116-1285` legacy_keys 7종 | **해소 확인** | 현재 코드(1534줄)에 legacy_keys 0건. 잔여 :1124-1129 "repeat_index or run_index" 2키는 별개의 좁은 규칙 |
| `keeper_runtime_trust_snapshot.ml:370-386` latest_turn_id 5단계 | **판정: 유지** | 같은 객체의 별칭이 아니라 서로 다른 증거 원천(decision JSON "turn_id" / tool_call JSON "keeper_turn_id" / receipt JSON "turn_count" / registry_entry turn_id·ct_turn_id)의 우선순위 사슬. 각 키는 각 생산자 포맷의 정식 이름 |
| `telemetry_unified.ml:51-78` extract_ts 7키 | **판정: 유지** | mli:1-14 명시대로 8개 독립 저장소의 읽기 전용 집계기이고 키마다 사는 생산자가 다름(timestamp=Telemetry_eio deriving, ts=turn_record 자기 왕복 형식, ts_unix=그 외). append-only 증거 원장의 판독기지 compat shim 이 아님. 새 쓰기 수렴은 별도 RFC |
| `dashboard_execution.ml` keeper_queue_summary 6단계 | **판정: 유지** | 항목 2 와 같은 구조 — 이기종 증거 원천의 우선순위 사슬(재검증 확인) |

## 항목 3 필드 이름 분열 — 판정: 유지 4 (개념이 다르다)

- assignee / worker / wire "submitted_by" / producer: 작업 점유자·검증 제출자·판정 전달 발신자라는 다른 개념이고 각 이름은 durable 저장소(tasks.json·verification 요청·async_request)의 정식 wire 키. 통일은 저장소 마이그레이션 — 비용 대비 이득 없음. "completed_by" 는 현재 부재(Cancelled 의 cancelled_by 만 존재).
- Keeper_meta id/name/keeper_id: 구성 안정 id·표시명·런타임 Uid 라는 다른 정체성 층.
- Keeper_event_queue.stimulus.post_id: 모든 payload 종이 공유하는 dedup/correlation id 로 값이 "task-outcome:<id>" 합성 id. mli 주석이 이미 설명하고 durable 키도 "post_id".
- Board post "body" vs comment "content": 종별 정확히 하나의 wire 키이며 board_tool_post body_or_content_arg 는 #39448 주석 단 의도적 MCP 입력 규칙, tui_decode 양쪽 키 판독은 post/comment 두 종을 한 판독기로 읽는 규칙. 별칭 방출이 아님.

## 항목 4 타임스탬프 타입 분열 — 판정: 문서화된 설계 결정

string ISO(Types_core.task·Goal_store.goal·Keeper_meta) / float(Board_types.post·Verification·Keeper_registry_types·Schedule_domain) / int ns(기동 관측) 는 각 도메인이 자기 durable 저장소와 함께 굳어 있다. 전면 통일은 전 도메인 마이그레이션이므로 기각하고, "다음 hard cut 으로 고치는 도메인부터 Masc_domain 시각 타입으로 통일" 규칙만 후속 RFC 과제로 남긴다. 추가 발견: server_utils.ml:291 이 board wire 에 "created_at_iso"(문자열)+"created_at"(숫자) 이중 방출 — TUI 표시용 파생이라 근거 주석이 있음(loader:729-733). board wire 를 닦을 때 함께 정리할 후보.

## 항목 5 쌍둥이 레코드 — 판정: 5쌍 전부 생산→투영 (즉시 통일 대상 0)

- Verification vs Tui_decode.verification_request: store→wire 단일 매핑(dashboard_verification:173), TUI 행은 투영 필드 포함.
- Types_core.agent vs Tui_decode.agent/client_row: Tui_decode.agent 재수출(masc_tui_types:616) 외 실사용처 조사 후 삭제 가능(잔여 미확인 1건 — 후속 등기). client_row 는 agent+keeper 명단 통합 행.
- Goal_store.goal vs planning_goal/overview_goal: store 문서 vs 화면 투영 2종(필드 집합 상이). lib 내 이중 정의 아님(alias).
- Board_types.post vs Masc_tui_types.board_post: 표시 행. 이중 시각 구조는 항목 4 의 wire 이중 방출에서 파생.
- Tool_registry.call_stats vs Tool_metrics.tool_stats vs Telemetry_eio.tool_usage_stats: 진행 카운터·표본 백분위·영구 로그 집계라는 다른 측정 원천. count 필드명만 우연히 겹침.

## 감사 후속 (이번 전수로 새로 등기하는 것)

0. dashboard_http_keeper.ml:88·:145 의 degraded 행이 여전히 ("trust", …)+("runtime_trust", …) 이중 방출 — 독자가 execution-trust 표면 안에서 닫혀 있어 파손은 없으나(adv-49974b F2 확인) 다음 hard cut 후보.

1. Tui_decode.agent(masc_tui_types:616 재수출)의 실사용처 전수 확인 후 삭제 — 재수출 외 참조가 없으면 Types_core.agent 로 통일.
2. 도메인별 시각 타입 통일 규칙 RFC(항목 4) — 다음 도메인 hard cut 부터 적용.

## 수리 커밋 (이 PR)

1. `refactor(dashboard)` — 별칭 키 hard cut 4건: raw_phase·selected_model·trust·recent_event 방출 제거, approval/execution 정식 이름 통일, OCaml 독자·TS 폴백·시험 fixture 동반 정리
