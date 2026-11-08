# 감사 6/8 전수 판정 — 2026-11-08 (task-3366 취합 문서)

작성: claude-62be833e. 감사 원문: board:p-f0bc86d2386013c41a54932e9fc13500 및
jeong-sik/masc#49745. 모든 좌표는 main 27852676b4b6(판정 시점 origin/main)에서
재직독해 판정했다(전용 재검증 에이전트 보고: 7개 미러 스토어의 캐시·쓰기·회복 정책 전수 대조 + sangsu 6차 분석 재확인). #49965 이후 추가 audit6 작업은 없음(git log 확인).

## 항목 1 JSON+`.last-good`+캐시 스토어 — 수리 1 + 판정 + 등기 (정정: 5개가 아니라 7개)

쓰기 원시자(`Common.recovery_mirror_suffix`, `Workspace_utils.write_json_*`)는 이미 공유. 스토어마다 남는 것은 캐시 계층과 load 분류·회복 정책이다.

| 스토어 | 판정 | 근거 |
| --- | --- | --- |
| goal_store + goal_verification | **수리 — 이 PR** | 두 캐시가 줄 단위 동형(내용 주소형 `(string, string * prepared) Hashtbl` + Mutex + 바이트 동등 hit). Mutex·바이트 동등·적재 역학을 `Mirrored_store_cache.Content_cache`(create/clear/find/replace/memo) 한 곳으로. 각 스토어의 load 분류(goal_store 4분기+mirror_status 5분기+reset_step / goal_verification Primary_undecodable+backend 권한)와 쓰기 꼬리는 도메인 손상 판단이라 흡수하지 않는다 |
| 쓰기 꼬리(primary→미러, 미러 실패 warn) | **판정: 동형이나 유지** | 꼬리 ~12줄씩이지만 삽입점이 다르다 — goal_store 는 미러 전 refuse_symlink_replacement·projection-notify, goal_verification 은 두 경로 캐시 clear·projection_source_changed. 공유 함수는 파라미터가 본문보다 길어진다 |
| workspace_goal_index | **등기(다음 층)** | 캐시 기계는 같으나 권한/관찰 이중 읽기 정책 + 쓰기 후 재검증·롤백이 functor 표면을 넓힘 |
| workspace_backlog | **등기(설계 후속)** | mtime/size 키 캐시 + `==` Atomic fast path + 미러 serving(출처 추적) — 변환 필요 |
| schedule_store | **등기(설계 후속)** | File_version_cache·domain-pool compact 인코딩(4.3MB 원장 107ms→15ms 실측 주석)·2×3 완전 행렬·memory-backend 권한 — 도메인 특수성이 지배 |
| goal_measurement·schedule_runner seen-ledger | **판정: 별개 경량 변형** | 감사가 못 센 2개 — measurement 는 캐시 없음, seen-ledger 는 typed 거부(`seen_primary_failure`) 계약 |

## 항목 2 Verify 쌍둥이 오케스트레이터 — 판정 + 등기

셸(start 의 CAS 4분기·훅 백업/복원·on_release 티어다운·fork_daemon, ~25줄)은 주석까지 동일하다. 그러나 동시성 규율이 다르다: completion_authority 는 `Eio.Semaphore 4`(blocking acquire), goal_verification 은 CAS 유계 목록(비차단, `>= max_concurrent_reviews`면 None). 재시도도 단일 interval 타이머 배치 vs per-claim 예약. **셸만 공유 모듈(single-lane agent shell)로 뽑는 후속을 등기**하고 슬롯·재시도 core 는 합치지 않는다.

## 항목 3 Outbox 2벌 — 판정: 도메인 고유

goal 은 Goal lock 아래 ack-후-삭제·2단계 수신자 확정·별도 notification lock; backlog rejection 은 standing 분류(Current/Obsolete 교차검증)가 본문이고 pending→delivered 보존. 겹선은 "lock 아래 읽기→분할→쓰기" ~10줄뿐 — functor 는 손해.

## 항목 4 Tools vs Skills — 판정: 단일 소스 선언적 파생

keeper_skill_catalog 가 `surface = Instruction | Composition` 을 스킬마다 선언하고, instruction 은 단일 keeper_skill 도구·composition 은 keeper_compose_<name> 파생, 관측도 keeper_effective_tool_surface 로 통합. "6 레지스트리 vs 8 카탈로그" 프레임은 현 코드와 안 맞는다. 두 표면을 한 도구로 합치는 것은 모델에게 보이는 표면을 바꾸는 제품 결정 — 등기하지 않고 판정으로 닫는다.

## 항목 5 큐/커서 원장 — 판정: 해소 (원시자 중앙화 확인)

`Fs_compat.Private_jsonl_cursor`(19파일)·`Cross_context_mutex`(28+파일)가 중앙화돼 있고, 스토어마다 남는 것은 정당한 상태 의미층이다(대표: keeper_approval_queue_registry — compaction_ratio 2, append-only log 물리동일성 차등, "23MB 스냅샷 재작성 12-14GB/4분" 실측 주석, Stdlib.Mutex 불가 근거 문서화).

## 항목 6 Reactive 브리지·Proactive 루프 — 판정: 의도적 차이 (sangsu 6차 재확인)

- 브리지 5종 + schedule seen-ledger 1: 각각 긴급도·enqueue 변형·wake 의미·결과형이 주석으로 문서화된 의도 차이(멘션-커밋 계약, 커서 기반 소유자 회복, Paused 강제 재개 금지 등 스팟체크).
- pulse.ml(다소비자 틱 엔진·Rhythm/Nudge/Demand·quiet hours) vs proactive_refresh.ml(단일 compute 재실행·서킷브레이커·지수 백오프) — 서로 다른 추상화, 통합 대상 아님.

## 선행 수리(타 주체, 병합)

- 실행 레지스트리 3벌 → **PR #49965 병합**(2731fb37085d, 2026-11-08 12:34Z): Run_registry_core 공유 엔진 위의 change-observer 계약·source-error 문구 8케이스 공유화.

## 감사 후속 (이번 전수로 등기)

1. workspace_goal_index 캐시의 Content_cache 편입 + backlog·schedule_store 공유화 설계 검토.
2. 오케스트레이터 셸 공유 모듈(single-lane agent shell) — CAS 설치·4분기 진단·훅 백업/복원·on_release·fork_daemon(~40줄×2). 슬롯·재시도 core 제외.

## 수리 커밋 (이 PR)

1. `refactor(goal)` — goal_store·goal_verification 내용 주소 캐시를 Mirrored_store_cache.Content_cache 로
