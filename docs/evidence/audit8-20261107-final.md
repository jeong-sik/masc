# 감사 8/8 전수 판정 — 2026-11-07 (task-3348 취합 문서)

작성: sangsu. 감사 원문: board:p-5c03a567286d1c9a3a4fa5fce382aee5 (범주 1) 및
jeong-sik/masc#49747과 부문별 board 글. 모든 좌표는 main c5c6420a94에서 재직독해
판정했다 (evidence/category2-recon.md·category3-recon.md 상세).

## 범주 1 동시성 — 수리 완료 (5 PR, 전원 착지+MMB 녹색)
| 항목 | 수리 | 근거 |
| --- | --- | --- |
| flush_announcements + 게이트 poisoning | #49876 병합 | MMB 등기 |
| lsp spawn lock | #49888 병합 | MMB 등기 |
| flush_ring unflushed 카운트 보존 | #49898 (8ae09afd) | MMB 42414043794 success |
| 동시 파이버 Lazy.force 3점 (kfcss process_epoch·msetp declared_title_table·prg dune_sourceroot_markdown_dir) | #49899 (8d63ab0b) | MMB 42418892083 success |
| 무락 Hashtbl 공유 4점 (backend_memory get_or_create 실수리 + warn 테이블 가드 2건; kcp는 store_cache 이미 보호로 무변경 직독 확인) | #49900 (7f9da246) | MMB 42421229471 success |

## 범주 2 영구 장부·전역 스토어 — 수리 3 + 판정
| 항목 | 판정 | 근거 |
| --- | --- | --- |
| McpSessionStore 영구 먹통 (session.ml:611-614·694-713) | **수리** #49901 (6523333a) | registry 복구 패턴(on_release loop_started 복구 + mailbox drain + fork_daemon) 이식 + 회귀 시험 test_mcp_session_store_loop; MMB 42423638789 success |
| 검증 전 전역 선변 레이스 (keeper_runtime_config.ml:644-668) | **수리** #49902 (c5c6420a) | apply 시퀀스 apply_sequence_mutex(Eio_guard.with_mutex) 직렬화; config_boot_overrides 테이블 자체는 CAS Atomic이라 무변경 |
| 첫 base_path 영구 고정 (keeper_transition_audit.ml:25-90, tool_usage_log.ml:18·137-151) | **수리(링 가드) + 문서화** #49903 (검증 중) | transition_audit 링 2개 가드(실수리); get_default_store CAS 패자·tool_usage_log init last-wins는 Dated_jsonl 공개 close API 부재(.mli val 직독)로 문서화 — release API 추가는 감사 후속 |
| completion_authority_agent.ml:64 · goal_verification_agent.ml:685 | **무변경** | 직독: 단일 부팅 경로 설정 / 올바른 CAS 재시도 루프 |
| workspace_hooks.ml:39-408 (30+ Atomic 콜백) | **판정: 설계 과제** | 설치 슬롯 부류(부팅 시 Atomic.set, 호출 시 Atomic.get) — DI 리팩터링은 별도 설계 과제, 경합 결함 아님 |
| lane_addon_runtime.ml:28-37 (14개 ref/Hashtbl) | **무변경** | owner_subscriptions는 Stdlib.Mutex 보호, tool_change_handler는 단일 등록 last-writer-wins |
| masc_tui.ml:1722 (msx_poll_view) | **판정: 설계 부류** | TUI 내부 폴 캐시 ref(이중 ref), 단일 UI 루프 내부 상태 |

## 범주 3 숨겨진 I/O·순수성 — 문서화 1 + 무변경 2
| 항목 | 판정 | 근거 |
| --- | --- | --- |
| runtime_blocker_surface 숨겨진 I/O (keeper_status_bridge_blocker.ml:39-43·120-261) | **문서화(이 PR)** | summary Lazy가 강제 시점에 durable store 읽기(turn-failure arm의 latest_receipt thunk) — 타입에 I/O 계약 주석 추가; 설계 자체는 :47-58 주석으로 방어됨 |
| 뷰 렌더러 전역 ref 변이 (masc_tui_render_prim.ml:89-104) | **판정: 설계 부류** | 프레임 위치 ref 5개 모두 주석으로 루프 소유 규약 명시 ("Only the main loop can publish") |
| 인코더 전역 카운터 변이 (keeper_chat_store_row_codec.ml:98-145) | **무변경** | Atomic.fetch_and_add — 원자 증가, 설계 주석 존재 |

## 범주 4 대규모 로컬 ref — 전원 무변경 (스타일 플래그)
5사이트 전원 직독: bin/masc_tui.ml:23881-23945(state 레코드 필드 변이, 루프 소유)·
packages/agent_core/lib/llm_provider/complete_stream.ml:503-518(함수 지역 스트리밍
누산기 15개)·lib/keeper/keeper_reaction_ledger.ml:1473-1580(함수 내 지역 ref)·
bin/masc_tui_markdown.ml:1389-1399(함수 지역 ref 10개)·
packages/agent_core/lib/agent/agent_tools.ml:264-326(함수 지역 누산기).
**전원 함수 지역 변수 또는 루프 소유 상태 — 정확성 결함 0건.** ref-heavy 스타일
리팩터링은 별도 품질 과제.

## 감사 후속 (이번 전수로 새로 등기된 것)
1. Dated_jsonl 공개 close/release API 부재 — 전역 store 캐시 교체·폐기 시 핸들이
   process 종료까지 남는 바운드 아티팩트 (#49903 주석 기록).
2. workspace_hooks 콜백 슬롯의 명시적 주입(DI) 리팩터링 — 설계 과제.
3. TUI ref-heavy 함수들(masc_tui·markdown 등)의 스타일 리팩터링 — 별도 품질 과제.
