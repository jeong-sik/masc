# 2026-10-11 주간 감사 및 기능 매트릭스 (기준: 10-04 ~ 10-11, HEAD origin/main)

베이스라인: `docs/audits/2026-10-07-week-audit-and-feature-matrix.md`. 이번 감사는 10-07 베이스라인 이후
델타와 미해결 항목의 코드 재확인을 병행했다. 판정 기준은 전부 현재 코드(코드 레벨 판독)이며, 라이브
실행 확인이 필요한 항목은 그렇게 표기한다. 10개 영역을 병렬 적대적 리뷰로 감사했다.

## 1. 주간 변경 흐름 (일별)

| 일 | 커밋 | 골자 |
|---|---|---|
| 10-04(일) | 136 | workspace badge, causal Ask fixture 통합 |
| 10-05(월) | 23 | CI release 필수 동작 정리 |
| 10-06(화) | 190 | max-prompt-bytes 제거(#41224), CI |
| 10-07(수) | 321 | keeper FSM follow-up 정리(#41644), autonomous phase GADT(#41617), runtime failure provenance(#41602), 채팅 공백/가독성 3종, chat state 라벨(#41667), native recovery dispatch(#41655), librarian absorb 진실(#41513) |
| 10-08(목) | 104 | local runtime keeper callable(#41639), metric 라벨 정리(#41635), dashboard 텍스트 보존(#41717) |
| 10-09(금) | 125 | deferred explicit admission(#41996), lane addon tool contract(#41984), quiet-final 예외 제거(#41951), TUI approval recovery(#41785), recorded diff(#41938) |
| 10-10(토) | 166 | admission replay/retention(#42011/#42005), Firefox 재시작(#42186), constitution ceiling(#42194) |
| 10-11(일) | 47 | chat delivery turn authority(#41805), docs 정리 |

## 2. 신규 결함 (심각도 순)

### P1

| # | 결함 | 위치 | 요약 |
|---|---|---|---|
| P1-1 | 오버레이 공존 시 숨은 서버 부작용 키 18군 | `bin/masc_tui.ml:24767-26136` | Keeper detail 위 Git-changes 오버레이(`d`키가 뷰를 바꾸지 않고 열림) 아래서 `s`(sandbox 백엔드 변경), `b`/`B`(Board 재큐), `P`/`L`(토큰·GitHub 로그인) 등이 화면과 무관하게 동작. Code 뷰 쪽도 `B`/`K`/`D`/`R`/`b`/`m`/`d`/`H` 7군 가드 누락. 형제 arm(notes/history/`t`/Repositories)에는 가드가 있어 누락만 남음. 구조적 원인: `modal_owns_keys`(`masc_tui_types.ml:9800-9808`)에 `repository_changes_open`이 없어 갈래마다 조각난 가드에 의존 |
| P1-2 | keeper purge가 official-clients 홈·prepare.lock·OAuth 토큰을 남김 | `lib/keeper/keeper_shutdown_types.ml:598-657` | purge 아티팩트 계획 20여 항목에 공식 클라이언트 홈이 없음. 실측 `~/.masc/official-clients` = **74GB**(antigravity leaf 22개), 루트 `*.prepare.lock` 13개. 홈 안에 복사된 OAuth 토큰 잔존. 기존 잔재는 해시 leaf라 코드로 역산 불가 → 운영자 수동 정리 + 코드는 신규 잔재 방지만 커버 |
| P1-3 | context marks 상한 무효 — Librarian 정체 시 컨텍스트 무제한 성장 | `lib/keeper/keeper_turn_driver_try_provider.ml:2786,277` | 세션 보유 턴은 전부 `Some continuity`라 `evict_at_turn_boundary`가 발동하지 않음. 10-07 베이스라인 E-01과 동일 경로, 이번 주 완화 없음 |

### P2

| # | 결함 | 위치 | 요약 |
|---|---|---|---|
| P2-1 | native terminal acknowledge 미연결 | `keeper_direct_native_continuation.ml:382-393` | `Terminal_unacknowledged → No_native_call` 유일 전이(`Acknowledge`)의 호출부가 lib 전체 0건. Retire 종말 작업은 영원히 "awaiting acknowledgement"로 남고 재디스패치 불가 |
| P2-2 | admission 판정 프롬프트 크기 상한 없음 | `keeper_memory_admission_judgment.ml:146-234` | 큐에 쌓인 후보 전체+매칭 은퇴 증거 전체를 한 pass에 실음. capacity refusal 후 분할은 current_memory 전체 재주입이라 비어 있는 반복 |
| P2-3 | admission 큐 O(n²) append + 길이 상한 없음 | `keeper_memory_admission_queue.ml:115-116,87-91` | `pending @ [row]` 매 전체 복사 + 전체 JSON 원자 재작성. 판정 막힘 상태에서 무한 성장 시 턴 지연/디스크 쓰기 폭증 |
| P2-4 | quiet-final 수락 레인 비대칭 | `keeper_turn_driver.ml:2664-2685` vs `keeper_turn_driver_try_provider.ml:600-606` | 빈 최종 텍스트는 Codex만 수락, Claude/Muse/Antigravity/AGENT_CORE는 전 후보 소진 후 턴 실패. 같은 응답이 레인에 따라 정상/실패로 갈림 |
| P2-5 | 기프트 대상 keeper 존재 검증 없음 | `keeper_candle_tools.ml:185-188`, `candle_gift.ml:43-66` | 오타 이름으로 기프트 시 잔액이 영구 고립(clawback 없음). invite 쪽은 `is_keeper_name` 검사 존재 |
| P2-6 | `Duplicate_gift`가 같은 사유의 정상 재기프트를 영구 차단 | `candle_balance.ml:21-30` | reason 키 중복이면 금액 달라도 거부. 이중 지급 방지는 이벤트 append 원자성으로도 보장 가능 |
| P2-7 | play participation이 토큰 해시로 키됨 | `play_participation.ml:8-11,24,36` | 크리덴셜 갱신 시 새 파일이 되고 ENOENT는 `Ok Connected` 처리라 `Departed`가 리셋. `~transaction`은 사용되지 않음 |
| P2-8 | composition evidence stale-writer-wins | `keeper_skill_composition_evidence.ml:331-395` | 파일 락은 직렬화만 하고 순서 보장 없음. 먼저 시작한 실행이 나중에 끝나면 오래된 기록이 신규를 덮음. per-run 스키마인데 저장소는 최신 1걸이라 실행 이력이 매번 파괴 |
| P2-9 | HITL 저널 한 줄 손상 시 late-approval 영구 정지 | `keeper_late_approval.ml:186-188,392-393,652` | 알 수 없는 스키마 행 하나가 전체를 `Corrupt_journal`로 만들고 모든 mutation 거절. 복구 경로 없음. 해당 행만 걸러내고 카운트 노출로 변경 필요 |
| P2-10 | World Curator 브리핑 full text가 상한 없이 매 턴 주입 | `keeper_unified_prompt.ml:1132-1158`, `workspace_memory_briefing.ml` | 소스 누적 → 병합 누적 → 전 Keeper 전 턴 tail 전량 재전송. 크기 관측도 안 됨(exact-lane usage 미기록 E-03과 결합) |
| P2-11 | 도구 스키마 캐시 없이 매 스텝 전량 재직렬화 | `packages/agent_core/lib/agent/agent_turn.ml:26-32`, `base/tool.ml:161-188` | 52개 도구 ≈74KB Yojson 트리 재구축/스텝. 순수 CPU 낭비 |
| P2-12 | 용어집: Play Room 부재 + World Curator 병기 회귀 | `docs/spec/00-glossary.md:3310` | 코드 식별자는 `Workspace_curator`뿐인데 항목 제목이 "World Curator"(`#41920`이 금지된 이름 복원). Play Room(#41668/#41671/#41789 머지)은 용어집에 개념 자체가 없음 |

### P3 (선별)

- 매니페스트 usage 필드가 항상 상수(`Null`/`"unresolved"`) — stub 계열, 실측 연결 또는 삭제 (`keeper_turn_driver.ml:551-561`)
- admission worker가 앞부분 커밋을 소실하고 `Pending`으로 보고 (`keeper_memory_admission_worker.ml:56-67`)
- 저널 쓰기 실패 시 seq 없는 터미널을 그대로 브로드캐스트 (`server_routes_http_keeper_stream.ml:3352-3371`)
- 훅-선-정산과 재시작 정산의 터미널 중복 윈도 (`keeper_owner.ml:1357-1364`)
- `eager_body_bytes`가 항상 0인 죽은 관측 필드 (`keeper_skill_observability.ml:208,230`)
- `projected_entries` 단일 슬롯 캐시 스래싱 (`keeper_skill_catalog.ml:417-430`)
- `keeper_late_approval`의 `reap_locked` 중복 정의 2건 (`keeper_late_approval.ml:120-127` vs `:433-440`)
- Home 결정 라벨이 Gate/운영자 확인을 구분 못함 (`masc_tui_home.ml:24,26`)
- world constitution 렌더 상한이 5일 새 두 번 ratchet(4K→8K→12K) — 거부 유발 시 올리기 패턴 반복 (`keeper_tool_constitution_runtime.ml:9`)
- 용어집이 하루 11.6KB씩 성장(10-07 297KB → 10-11 344KB) — 색인+도메인 파일 분할 시급
- `~/.masc` 수동 백업 잔재에 보존 기간 정책 없음(runbook 문서화 수준 제안)
- File_lock_eio 해제 경로에 unlink 없음 — 해시 이름 lock 영구 축적 (`file_lock_eio.ml:468-478`)

## 3. 베이스라인(10-07) 잔여 확인

고쳐짐: B-01 반복 가드 judged 산수, B-02 브리핑 다이제스트 상한(구조 대체), B-03 seed flush 취소 삼킴, B-04 stale 주석, E-04 8KB 상수 다이제스트, E-07 `drain_board_all` 삭제, E-02 context pass 게이트 부분, H-02/H-03/H-04 용어집 정리, F-03 schedule 수정 시 result_delivery 유지, F-07 goal FSM.

그대로(코드 재확인): A-01 vision 403 usage 미기록(#38061), A-03 unhinted 429 demote 만료(#38471), D2-07 체크포인트 전체 재쓰기(#36690), D2-08 `?recovery_view` 죽은 팔(생산자 0건), D3-04 librarian 판정에 current Memory 전체 재주입, E-01 context marks 무효(P1-3), E-03 exact-lane usage 미기록, E-05 curator 이중 저장, F-02 퇴역 모델 재분류 부재, F-04/F5/F6/F7 candle 미해소 일부, D4-07 skill 발행 근거 publication.json 미구현(RFC Accepted), 강화/반감기 메모리 미구현(RFC-0418 설계).

## 4. 기능 매트릭스 (통합)

| 기능 | 상태 | 근거 |
|---|---|---|
| **Runtime** | | |
| 런타임 장애 감지→페일오버→복구 순환 | 동작(경계 유한) | 후보 1회 순회+deferral 1회 소비, eviction은 매 스텝 엄격 진행 |
| 실패 이유 latch(provenance) | 동작 | `Keeper_runtime_failure_route`→`turn_failure.route` 합타입 턴 경계 전달 |
| context marks(high/low water) | **결함** | P1-3 |
| native terminal acknowledge 소비 | **결함** | P2-1 |
| **Keeper 턴** | | |
| 턴 시작→컨텍스트 준비/조립 | 동작 | 헌법 unreadable 시 미전송 |
| quiet-final 수락 | **결함** | P2-4 레인 비대칭 |
| 반복 가드 in-turn·cross-cycle | 동작 | frontier 워터마크(#41550) |
| cancelled/pending 채팅 저널 | 동작 | #41657/#41687 |
| **Memory/Librarian** | | |
| explicit write→admission/직접커밋 분기 | 동작 | enabled/disabled 양쪽 |
| 큐 지속화·receipt 정산·복구 | 동작 | acknowledge+소비 누락 탐지 |
| 판정 프롬프트 크기 | **결함** | P2-2 |
| 큐 성능·상한 | **결함** | P2-3 |
| 소거/흡수 증거 보존 | 동작 | journal+retraction receipt+원본 행 |
| drain prune/settlement 순서 | 동작 | #42198 핀 |
| recall 크기 상한 | 동작 | notice-only+아티팩트 참조 |
| librarian 판정에 current 전체 재주입 | 결함(잔여) | D3-04 |
| 메모리 강화/반감기 | 미구현(설계) | RFC-0418 |
| **Candle/Economy** | | |
| 원장 append-only·잔액 재계산 | 동작 | gift 폴드 포함 |
| 반감기 투영 | 동작 | tick 없음, 재시작 이중 적용 없음 |
| 논공행상 분배(largest_remainder) | 동작 | 보존 확인 |
| keeper→keeper 기프트 | **결함** | P2-5, P2-6 |
| 구매/장착 | 동작 | `"default"` 문자열 sentinel 잔여(F7) |
| **Play** | | |
| invite 발급/목록/취소 | 동작 | 트랜잭션화(#41604) |
| participation 상태 | **결함** | P2-7 |
| **Skills** | | |
| 발행/로드/주입/본문 읽기 | 동작 | 18.8KB/턴 고정, 본문 on-demand |
| composition evidence 저장 | **결함** | P2-8 |
| 발행 근거 영속화(publication.json) | 미구현 | RFC Accepted, writer 0건 |
| 반복 해결→재생성 루프 | 미구현(프롬프트만) | `config/prompts/keeper.md:58` |
| **Board/Task/Goal** | | |
| Board 게시/댓글/반응/투표 | 동작 | CanVote 토큰 검사 포함 |
| Task claim→제출→verdict | 동작 | typed authority 강제 |
| Goal 생성→검증→확정 | 동작 | FSM 닫힘 |
| Goal 확정→Candle 결합 | 결함(설계 확인) | Candle 쓰기 실패 시 확정 거절(운영자 결정 #11) |
| Task GC/archive | 결함(잔여) | 관리자 도구만, 무일정 |
| **HITL** | | |
| 승인 큐/health/recover | 동작 | CanAdmin 게이트 |
| late-approval 지속화 | 일부 | P2-9 corrupt 시 복구 부재 |
| **Schedule** | | |
| 생성/수정/발화 | 동작 | 놓친 발화 1회 collapse |
| 원장 크기 | 결함(잔여) | notes 56%, 전체 재쓰기 |
| **TUI** | | |
| 채팅 렌더/검색/라벨 | 동작 | #41696/#41667/#41660 |
| 오버레이 키 소유권 | **결함** | P1-1(18군) |
| Home 결정 라벨 | 결함 | P3 — Gate/확인 구분 없음 |
| **컨텍스트** | | |
| 도구 스키마 캐시 | 미구현 | P2-11 |
| exact-lane 토큰 계측 | 미구현 | E-03 |
| 월드 브리핑 크기 | **결함** | P2-10 |
| 도구 결과 상한 | 동작 | 16KB wire/64KB inline |
| **용어집** | | |
| 한 용어-한 의미 | 결함 | P2-12 |
| 코드 식별자 일치 | 동작(회복) | Candle 12종 등 |
| 구조(344KB 단일 파일) | 결함 | 분할 시급 |
| **런타임 데이터** | | |
| jsonl 스토어 내결함성 | 동작 | 구버전 레코드 전수 검사 0 실패 |
| keeper purge 잔재 | **결함** | P1-2(74GB) |
| lock 파일 정리 | 결함 | P3 |

## 5. 금지 패턴 검사 결과

이번 주 신규 코드에서 Stub, `/Users/` 하드코딩, SSOT 위반, 문자열/부분문자열 상태 분기, 근거 없는
상수 조작은 사실상 0건. 발견된 예외는: `keeper_candle_tools.ml:149` `"default"` sentinel(잔여),
constitution render 상한 ratchet(P3), quiet-final의 `String.trim = ""` 매칭(잔재 #28622). 헌법
불변식(persist-before-model, failure-keeps-evidence, strict-parse)은 신규 admission·play·
candle 경로에서 준수 확인.

## 6. 개선 로드맵 (작은 PR 단위)

1. ~~#42237~~ history `d` 가드 + 수집기 two-pass (open)
2. `docs/glossary-play-room-curator-20261011`: P2-12 — World Curator→Workspace_curator hard-cut, Play Room 항목, allowance 코드 명칭 병기
3. `fix/late-approval-dup-reap-20261011`: 중복 `reap_locked` 삭제 (P3)
4. `fix/admission-worker-deferred-committed-20261011`: `Deferred` 분기가 `committed` 보존 + board attention `protect` 패턴 정리 (P3)
5. `fix/skill-eager-body-bytes-removal-20261011`: 죽은 필드 제거 (P3)
6. 이후: late-approval corrupt 복원 완화(P2-9), 기프트 검증+Duplicate 완화(P2-5/6), TUI 오버레이 단일 dispatch(P1-1), purge 계획에 공식 클라이언트 홈 추가(P1-2), admission 배치 예산(P2-2/3), quiet-final 레인 정합(P2-4), participation 키 안정화(P2-7), evidence append-only(P2-8), 도구 스키마 캐시(P2-11)

## 7. 운영자 수동 조치 (코드로 불가)

- `~/.masc/official-clients` 74GB + 루트 `*.prepare.lock` 13개 + 구방식 plain 이름 leaf 12개 수동 정리
  (해시 leaf라 keeper 역산 불가). 삭제 전 각 leaf의 `.gemini/antigravity-cli/antigravity-oauth-token` 포함 여부 확인.
- `verification-runs.jsonl` 옛 `operator_routed` 행이 compaction 차단 — 데이터 정리 필요.
- 수동 백업(`backups-*`, `keeper_chat.backup-*`, `.masc/backups` 45개) 보존 기간 결정.
- `autonomy_stats.jsonl` 고아 파일 삭제.

## 8. 운영자 결정 요청 (제품 방향)

### 8-1. quiet-final 수락 정책 (P2-4)

빈 최종 텍스트로 끝나는 턴을 "정상 종료"로 받을지 여부가 5개 레인에 비대칭 적용 중
(Codex만 수락, 나머지는 전 후보 소진 후 실패 — `keeper_turn_driver.ml:2664-2685` vs
`keeper_turn_driver_try_provider.ml:600-606`).

**업계 사례 조사 (2026-10-11)**: 툴 호출 없는 응답을 종료로 보는 "implicit finish"가
주류다 — Claude Code가 "response without tools이면 루프를 끝내는" 구조(Arize
[Harnesses Have an Expiration Date](https://arize.com/blog/harnesses-have-an-expiration-date/),
"Inngest: Text response means done"). 빈 응답 재시도 관행은 **일시적 API 오류** 대상이며
OpenRouter·Haystack·nanobot 이슈에서 그 대상은 `finish_reason=length`/`content_filter`
등으로 명시적으로 분류된다 — 즉 "모델이 할 일 없음으로 조용히 끝낸 것"과 "프로바이더가
빈 것을 반환한 것"은 별개 케이스이고, 전자를 실패로 번식시키는 건 하네스-모델 결합
안티패턴(Arize eval이 모델별 행동 정규화를 결론으로 꺼낸 것과 동일). MASC는
tool-only 턴을 이미 수락하므로 빈 최종 텍스트 수락과도 계약이 일관된다.

- **(a) 전 레인 typed 헬퍼로 수락 통일 (권장)**: #41747이 만든 `Allow_quiet_final` 타입 정책을
  공통 헬퍼로 복원해 5개 레인에 동일 적용하고, quiet-final 발생 게이지를 추가해 조용한
  종료를 관측 가능하게 한다. 비용: 레인이 조용히 끝나는 실패를 즉시 알기 어려움(게이지로 보완).
- **(b) 전 레인 엄격 수락**: Codex 특례도 제거. 비용: 빈 최종 텍스트 하나가 후보 수 ×
  풀 요청 비용으로 번식, schedule 웨이크 노이즈.

### 8-2. native terminal acknowledge 소비 (P2-1) — 조사 결과로 결정 소멸

**코드 재검증 결과 초기 주장이 부정확함** (탐색 에이전트 전수 조사, 2026-10-11):

- "유일한 전이 Acknowledge"는 거짓 — `Keeper_native_call.transition`
  (`keeper_native_call.ml:67-83`)의 나가는 전이는 `Acknowledge`·`Bind`(새 call
  교체)·`Terminal`(자기 유지) 3개.
- "Retire가 영구 남는다"는 거짓 — Owner settle 경로
  (`keeper_chat_operation_store.ml:2302-2310`, "Retire is acknowledged by the
  operation's actual terminal transaction")가 Retire 종말을 `No_native_call`로
  원자적으로 자동 해소하며, 테스트 3종(`test_keeper_direct_runtime_resume.ml:288-291` 등)이
  이 계약을 검증 중. UI 노출도 settle 완료 전 임시 에러 2곳뿐.

남는 것은 **결정이 아니라 죽은 코드 정리**뿐: 호출부 0건인 exported
`Keeper_direct_native_continuation.acknowledge`(382-393)와 `Acknowledge` change
생성 경로(`keeper_owner.ml:2148-2149`)를 삭제하고, settle이 실제 acknowledge
경로임을 주석·문구로 명시. 에러 문구 "awaiting Owner acknowledgement"는 유지
(settle 대기 중에는 실제 상태이므로). 헌법 legacy_residue 원칙 적용 대상.

## 9. 후속 확인 사항 (이번 감사 이후 발견)

- **#41784 회귀 → #42274 수정**: 빈 시간 구간의 strict 채팅 로드 회귀를 조사로 확정하고
  수정 PR까지 연결. "검토 없는 조합 변경"이 만든 이번 주 3번째 실제 회귀
  (#41793+#41730 조합 → #42255, #41784 → #42274, 이전 #42243 컴파일 P0는 리뷰 선제 차단).
- **P2-10 전제 정정**: "월드 브리핑 full text가 매 턴 주입"은 옛 것 — 현재 본문은
  `keeper_workspace_memory_read` 도구로 지연 주입. 남는 것은 크기 관측 부재뿐 → #42276
  (브리핑 바이트·claim 수 게이지)로 보강.
- **실패 테스트 3종 조정**: curator_lane 29/34·candle 27건·absorb_gate 5건은 전부
  `dune exec` CWD 아티팩트 — 표준 runtest 전부 통과, 코드 결함 아님. 선택적 하드닝
  (프롬프트 디렉터리 미해결 시 fail-fast)은 미착수.
- **클린 체크아웃 기본 빌드 브레이크 → #42281 수정**: plain `dune build`가 클린
  checkout에서 100% 실패(`ocaml-msx` 패키지에 스탠자 0 — vendor/가 gitignore).
  browser_host·cohttp-eio 핀 어긋남(#41914)이 머지 후 미발견된 구조적 원인이었음.
  `allow_empty`으로 처방. 로컬 환경 핀도 locked 상태로 복구 완료(2026-10-11).
