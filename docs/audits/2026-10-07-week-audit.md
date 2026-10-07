---
status: audit
date: 2026-10-07
base: origin/main fb5344a25a (2026-10-07 14:03 KST)
---

# 1주 감사 — 2026-09-29 ~ 10-07

## 한 줄 결론

기능 대부분은 정상 경로가 돈다.
문제는 끝나지 않는 순환이다.
checkpoint, Board attention 후보 원장, 작업 backlog 는 계속 커지고 줄어드는 길이 없다.
TUI 는 읽기 한 번 실패를 "다른 작업공간"으로 착각해 모든 읽기를 버린다.
같은 증상을 닷새 동안 여섯 번 따로 고쳤다.

## 어떻게 봤나

- 기준: `origin/main` fb5344a25a, 라이브 데이터 `~/.masc` (읽기만).
- 7일 경계(KST 커미터 날짜): D-7 e126a20e72 · D-6 6c10cbab2c · D-5 a66db1a44d · D-4 83d23c96c0 · D-3 0ec18301d0 · D-2 87123f7df9 · D-1 6a9b9ac462. 커밋 1,347개.
- 여섯 영역을 따로 감사했다. 영역별 원본은 [같은 이름 폴더](2026-10-07-week-audit/)에 있다.
  - A 런타임·Keeper, B 기억·Librarian, C 협업·통제, D 경제·Play, E TUI·대시보드, F 횡단(설정·층·용어).
- 판정은 문서가 아니라 코드 경로로 했다.
- "직접 확인" 표시는 합치는 단계에서 코드나 라이브 데이터로 다시 확인한 항목이다. 나머지는 영역 감사의 판정을 그대로 옮겼다.

## 7일 흐름

| 날 | 커밋 | 무슨 일이 있었나 |
|---|---|---|
| D-7 (09-29) | 168 | Candle 이 사실상 이날 들어왔다. 구매 계층을 두 번 고쳤다. TUI 화면 통합 fix 가 줄줄이 들어왔다. |
| D-6 (09-30) | 199 | fix 비율 60%. "기억 전부 주입하지 말고 검색" 도입. 관측 callback 수정 4건 연속. |
| D-5 (10-01) | 540 | 한 주 최대. 스택 PR 을 한꺼번에 합치며 "main 컴파일 안 됨" 복구가 다섯 번 나왔다. recall 방식을 이틀 만에 다시 바꿨다. |
| D-4 (10-02) | 58 | 대부분 스택 rebase. TUI Lane 읽기를 신원 확인 뒤로 미루는 fix 3건. |
| D-3 (10-03) | 118 | Goal 증명 재시도 5건. Candle 등급·분배를 `candle.toml` 로 옮겼다. |
| D-2 (10-04) | 14 | 거의 멈춤. |
| D-1~HEAD (10-05~07) | 290 | Goal 일시정지·차단 복구, Candle 운영자 지급·선물, 반복 감지가 도구 답만 비교. 대시보드 추가분의 68%가 증거 파일이다. |

같은 곳을 여러 번 고친 자리:

- TUI 작업공간 신원: 닷새 동안 증상 패치 6번 (#40173, #40693, #40696, #40707, #41098, #41478).
- Candle 지급 평가 실패 분류: 8번 이상.
- Board 스냅숏 flush: 3번 (#39989, #40488, #41459).
- 한 주 커밋의 43%가 fix 다.

## 기능 매트릭스

판정: 정상 / 의심 / 결함 / 미확인. 순환: 닫힘(줄어들거나 멈춤) / 열림(계속 커지거나 계속 재시도). 크기: S 한 함수, M 한 PR, L 스택이나 RFC.

### 런타임 · Keeper

| 기능 | 판정 | 순환 | 무엇을 봤나 | 제안 | 크기 |
|---|---|---|---|---|---|
| Runtime failover | 의심 | 열림 | 계정 한도 문구가 `Rate_limited` 로 분류돼 60초 쉬고 다시 두드린다. 10-05~06 6시간 동안 Keeper 3명이 약 350번 실패했다. `keeper_runtime_failure_route.ml:424-440` | 계정 한도를 typed 이유로 분류 | M |
| 계정 admission | 미확인 | - | 큐 구현이 agent core 쪽이라 읽지 못했다 | - | - |
| Window 를 넘지 않는 turn | 정상 | 닫힘 | byte 상한 없이 provider 의 typed 거절에 반응한다. 이유 모르는 400 은 한 번 더 보낸다. `keeper_turn_driver_try_provider.ml:2385` | 둠 | - |
| Keeper context 수명 (checkpoint) | 결함 · 직접 확인 | 열림 | step 마다 checkpoint 정본 전체를 3번 atomic+fsync 로 쓴다. 하루 약 2TB. 정본은 step 마다 커지고 자동으로 줄지 않는다. `keeper_agent_run.ml:1620-1690`, `keeper_checkpoint_store.ml:1572-1660` | 저장 횟수 줄이기, append-only 나 분할. RFC 먼저 | L |
| 끊긴 turn 재개·사용량 정산 | 정상 | 닫힘 | `keeper_unsettled_spend.ml:196-273` | 둠 | - |
| 반복 감지 seed | 결함 · 직접 확인 | - | 아래 "직접 확인한 것" 참고. 공식 클라이언트 lane 에서 이미 판정한 호출을 다시 세고 새 호출을 버린다 | ledger seed 를 최신 순으로, `judged` 를 개수 대신 행 식별자로 | S |
| operation 큐 drain | 의심 | 닫힘 | Board attention drain 1,773번 중 864번이 판정 0건 | 0건 drain 이 permit 이나 요청을 쓰는지 확인 | S |
| 매 step 주입 context | 의심 | 열림 | Claude Code lane 도구 155개, 스키마 약 152KB. AGENT_CORE lane 고정분 약 93KB 가 step 마다 다시 간다. cache 적중 96~99%라 청구는 작다 | 아래 "낭비" 참고 | M |

### 기억 · Librarian · Skill

| 기능 | 판정 | 순환 | 무엇을 봤나 | 제안 | 크기 |
|---|---|---|---|---|---|
| Librarian 사이클 | 의심 | 위치는 닫힘, 비용은 열림 | 공급자 연결 실패를 쉬지 않고 신호마다 다시 보낸다. 장애 때 시간당 최대 965번. 실패 기록은 서버 메모리에만 있다 | 실패 뒤 쉬기 | M |
| 기억 생산 | 의심 | 쓰기 비용 열림 | 같은 claim 을 다시 쓰면 snapshot 전체를 다시 쓰고 revision 이 오른다. `keeper_memory_os_current.ml:2338-2352` | 같은 바이트면 쓰지 않기 | S |
| 합성·파생 (derived, premise) | 의심(과잉) | 닫힘 | 라이브 사실 5,058개 중 derived 4개, 모두 전제 1개. 코드 언급 353곳 | 지울지 결정 필요 | L |
| 삭제 (retract, supersede) | 정상 | 저널은 열림 | 현재 목록에서 뺀다. 저널과 absorbed 파일에는 남는다 | 둠 | - |
| 흡수 (absorb gate, JEV) | 의심 | 열림 | 영역 감사: JEV preflight 의 85%가 400 으로 실패하고 1%만 호출을 아낀다. 같은 질문을 pass 마다 다시 묻는다 | preflight 를 고치거나 끈다 | S |
| 강화 | 미확인(설계상 없음) | - | 감쇠·만료가 없다. 재관측은 `last_seen` 만 바꾼다 | 필요하면 RFC 먼저 | - |
| Recall | 정상 | 닫힘 | turn 마다 약 1.2KB 안내만 넣는다. 그 개수를 내려고 snapshot 전체(평균 94KB)를 읽는다 | 개수 캐시 | S |
| Skill 재생성 | 결함 | 열림 | 기억의 교훈이 Skill 로 이어지는 단계가 없다. 5,615 turn 중 publish 3번, validate 0번 | 루프를 닫을지, 수동으로 둘지 결정 | M |
| 작업 맥락 | 의심 | 쓰기 횟수 열림 | 내용이 같아도 revision 을 올리고 다시 쓴다. revision 합계 60,442 | 같은 내용이면 쓰지 않기 | S |

### 협업 · 통제

| 기능 | 판정 | 순환 | 무엇을 봤나 | 제안 | 크기 |
|---|---|---|---|---|---|
| Board 게시·댓글·투표·flush | 정상 | 닫힘 | `board_votes.ml:169-235`, `board_core_persist.ml:341-365` | 둠. 테스트 뒷문 2곳 지움 | S |
| Board attention 후보 원장 | 결함 · 직접 확인 | 열림 | `not_relevant` 판정 행이 종결되지 않는다. 라이브 642MB, 187,260행. 만료가 없다. `keeper_board_attention_candidate.ml:1756-1766` | 판정 즉시 종결, 종결 행 정리 | M |
| Task 수명주기 | 정상 | 닫힘 | typed 전이. `transitions.ml:86-330` | 둠 | - |
| Task 보관(GC) | 결함 | 열림 | 수동 `masc_gc` 뿐이다. 라이브 1,209건 중 93%가 이미 끝난 작업 | 종결 때 보관하거나 정기 정리에 연결 | M |
| Task Hebbian 훅 | 결함(읽는 곳 없음) | 열림 | 이벤트를 쓰지만 읽는 코드가 없다. 활동 로그의 21.8% | 지움 | S |
| Goal 수명주기 | 정상 | 닫힘 | 7 phase, exhaustive 전이. 문자열 표가 3벌 있다 | 표 합침 | S |
| Goal drop → Task 취소 | 결함 | 열림 | 취소가 실패하면 응답에만 남고, drop 을 다시 불러도 아무 일도 없다. `workspace_goals.ml:867-909` | 다시 부르면 남은 Todo 를 다시 취소 | S |
| Goal 증명·확정 | 정상 | 닫힘 | `workspace_goals.ml:1093-1112` | 둠 | - |
| Schedule | 정상 | 닫힘 | 4종 반복, 자체 cron 파서, 보류 처리 | 둠 | - |
| HITL 승인 큐 · Auto Judge | 의심 | 사람 대기는 열림 | 라이브 모드가 `always_allow` 라 이번 주 HITL 변경은 라이브에서 돈 적이 없다. "Auto Judge" 는 이름이 조언인데 동작은 결정이다 | 라이브 검증, 이름 정리 | S |
| 접근 제어 | 정상 | 닫힘 | Worker/Admin/Player × 권한 10개. 분류 안 된 도구는 Admin 필요 | 권한 표 한 벌로 | S |
| `MASC_AUTH_STRICT` | 결함 | 열림 | `Dry_run` 과 `Strict` 동작이 같다. 측정 카운터만 있다. `mcp_server_eio_caller_identity.ml:167-185` | 거절로 바꾸거나 코드 삭제. 결정 필요 | M |
| 쓰기 요청의 작업공간 묶기 | 결함 | - | 라우트마다 방식이 다르다. TUI 는 네 가지 방식으로 묶고, 일정 쓰기는 아예 묶지 않는다 | 서버 쪽 한 곳에서 처리 | M |
| Multi Lane (add-on 라우팅) | 정상 | 닫힘 | `source_access` 3종 typed | 둠 | - |
| Exact lane 실행 기록 | 의심 | 닫힘 | lane 당 2,000건 보존. curator 실행 하나가 9MB | curator 입력 줄이기 | M |
| Fusion | 미확인 | - | 거의 쓰이지 않는다. 깊이 보지 않았다 | - | - |

### 경제 · Play

| 기능 | 판정 | 순환 | 무엇을 봤나 | 제안 | 크기 |
|---|---|---|---|---|---|
| Candle 원장·잔액 | 정상 | 닫힘 | 발행 − 소각 = 유통이 성립한다. `candle_balance.ml:92-98` | 보존 속성 테스트 추가 | S |
| 반감기 (`Candle_decay`) | 정상(라이브 꺼짐) | - | 구간별 정확 연산. `candle_decay.ml:44-77` | 둠 | - |
| 논공행상 지급 | 의심 | 평가 재시도는 열림 | 라이브 평가 실행이 0건이다. 평가 실패 분류가 불리언 3개와 기본값이다 | 분류를 닫힌 variant 로, 라이브 1건 증명 | M |
| Candle 가용성 | 결함 | 열림 | 평가 lane 이 막히면 구매·선물·장착·잔액 읽기까지 꺼진다. `candle_status.ml:62-66` | 읽기·상점은 평가 lane 과 분리 | S |
| 선물 | 결함 | 닫힘 | 받는 이름이 실제 Keeper 인지 보지 않는다. `candle_gift.ml:58-109` | 받는 Keeper 확인 | S |
| 구매 · Item Slot 장착 | 정상 | 닫힘 | `candle_shop.ml:79-110`, `candle_balance.ml:215-246` | 둠 | - |
| Portrait | 정상 | 닫힘 | 요청마다 원장 전체를 다시 재생한다 | 둠(후순위) | S |
| Play 초대 | 정상 | 닫힘 | 만료 필수 Player 토큰. `play_invite.ml:71-102` | 둠 | - |
| DOS 컨트롤러 인계 | 의심 | 열림 | 계속 Running 인 Keeper 가 쥐면 놓을 시한이 없다 | 운영자 해제로 충분한지 결정 | M |
| World Curator (`Workspace_curator`) | 의심 | 천천히 닫힘 | 약 9분마다 884KB 프롬프트를 보낸다. 97%가 이웃 사실이다. 완료 실행의 22%가 실패한다 | 이웃 사실 상한 | M |

### TUI · 대시보드

| 기능 | 판정 | 순환 | 무엇을 봤나 | 제안 | 크기 |
|---|---|---|---|---|---|
| 작업공간 신원·권한 | 결함 · 직접 확인 | - | 아래 "직접 확인한 것" 참고. /health 한 번 실패에 모든 읽기를 버리고, 다음 성공에 또 버린다 | "읽지 못함"과 "다른 작업공간"을 다르게 처리 | M |
| Gate · Approvals | 결함 | 닫힘 | 행 하나가 틀리면 Gate 목록 전체가 비워진다. 웹은 행 단위로 격리한다 | 행 단위 격리, 실패 때 마지막 행 유지 | M |
| Goal · Planning 화면 | 의심 | 닫힘 | 읽기 한 번 실패하면 열어 둔 Goal 상세가 목록으로 튕긴다 | 실패 때 마지막 값 유지 | S |
| Schedule · Usage 읽기 | 의심 | 닫힘 | tick 마다 요청 약 15개, 그중 7개가 /health | 바뀌지 않는 값은 tick 에서 빼기 | S |
| Memory 전체 보기 | 의심 | 닫힘 | Keeper 마다 facts 를 차례로 읽는다 | 서버가 한 번에 주기 | M |
| 웹 Gate | 의심 | 닫힘 | 서버 불변식 60줄을 클라이언트가 다시 구현하고, 필드를 닫아 둬서 서버가 필드를 더하면 행이 깨진다 | 검증은 서버만 | M |
| TUI ↔ 서버 경로 | 정상 | - | TUI 가 부르는 `/api/...` 143개가 모두 서버에 있다 | 둠 | - |

### 횡단

| 기능 | 판정 | 무엇을 봤나 | 제안 | 크기 |
|---|---|---|---|---|
| 라이브 설정 정합 | 결함 · 직접 확인 | 라이브 `[tui].voice_send_on_stop` 은 코드가 읽지 않는다. 코드는 `[voice.stt].send_on_stop` 을 읽는다. `[health].durable_queue_stale_sec` 도 읽는 곳이 없다 | 운영자가 키 옮기기 | S |
| 운영 코드의 테스트 훅 | 의심 | `lane_addon_broadcast_delivery`, `fs_compat` 가 테스트 훅을 레코드 필드로 들고 다닌다. 이번 주 `For_testing` 모듈 18개 추가 | 테스트 쪽으로 옮기기 | M |
| lib 층 경계 | 의심 | 하나의 dune 라이브러리라 runtime 이 keeper 를 불러도 막지 않는다 | 분할은 별도 RFC | L |
| `lane_addon_runtime` | 의심 | JSON 연관 리스트로 레코드를 흉내 낸다 | 레코드 타입으로 | M |
| 용어집 최신성 | 의심 | Candle 원장 종류를 9종이라 쓰는데 코드는 12종 | 개수 문장 지우고 타입 이름만 | S |

판정 개수(이 표 기준 55행): 정상 17, 의심 21, 결함 14, 미확인 3.
"결함"은 정상 경로가 틀리거나 순환이 닫히지 않는 것이다. 확률 낮은 경합은 넣지 않았다.

## 직접 확인한 것

합치는 단계에서 코드나 라이브 데이터로 다시 본 항목이다.

1. **checkpoint 쓰기량.** step 마다 정본 전체를 3번 쓴다. 10-06 로그 집계로 하루 약 1.96TB.
2. **Board attention 후보 원장.** `~/.masc/board_attention_candidates` 642MB, 187,260행 (10-07 측정).
3. **죽은 데이터.** `~/.masc/exact-lane-runs-v5.jsonl` 779MB. 코드는 v6 를 쓴다. `lane-addons-archive` 514MB.
4. **설정 키.** `[tui].voice_send_on_stop` 을 읽는 코드가 없다. 음성 자동 전송은 꺼져 있다.
5. **반복 감지 seed 순서.**
   - 탐지기(`keeper_agent_run.ml:227`)는 목록 머리를 최신 호출로 보고, 나머지에서 같은 호출을 센다. 세는 쪽은 순서와 상관없다.
   - 순서가 중요한 곳은 `Keeper_repetition_judged.seed_beyond`(`:64`)다. 앞에서부터 `total - judged` 개만 남긴다. 목록이 최신 순이라고 가정한다.
   - history seed 는 `List.rev` 로 최신 순이다. ledger seed 는 `Keeper_tool_call_index.select_locations`(`:416-446`)가 오래된 순으로 돌려준다.
   - 공식 클라이언트 lane(claude_code, codex, antigravity)은 checkpoint 가 없어 history 가 비고 ledger 만 쓴다(`keeper_run_tools_setup.ml:637-651`).
   - 그래서 그 lane 에서 반복으로 한 번 멈춘 뒤에는, 이미 판정한 오래된 호출이 남고 새 호출이 잘린다. #36276 이 막으려던 "판정한 호출을 또 증거로 씀"이 그대로 일어난다.
   - ledger 는 200행 창이 밀리므로, 개수로 경계를 잡는 방식 자체가 맞지 않는다.
   - `test_keeper_turn_outcome.ml:1154` 가 지금 순서를 단언한다.
6. **TUI 신원 철회.**
   - `/health` 읽기가 실패하면 `workspace_identity_of_refresh` 가 `Workspace_identity_unread` 를 돌려준다(`masc_tui_types.ml:141-157`).
   - `apply_server_identity_reading` 의 `same_workspace` 는 Match→Match, 같은 Mismatch 만 참이고 나머지는 `| _ -> false` 다.
   - 그래서 Match→Unread 에서 권한 세대를 올리고, 진행 중 읽기를 모두 취소하고, Keeper 목록을 비운다. 다음 성공(Unread→Match)에서 같은 일을 한 번 더 한다.
   - 타입은 이미 세 경우를 나눠 두었다. 비교 쪽이 "읽지 못함"을 "다른 작업공간"과 같이 다룬다.
   - 같은 파일에 `same_workspace_identity state.server_identity state.server_identity` 처럼 값을 자기 자신과 비교하는 검사가 두 곳 있다(`masc_tui.ml:4476`, `:4494`).

## 고칠 것 (순서)

정상 경로가 틀리거나, 데이터가 계속 커지거나, 같은 증상을 여러 번 고친 곳부터.

| 순서 | 무엇 | 왜 먼저 | 크기 |
|---|---|---|---|
| 1 | TUI 신원: "읽지 못함"은 철회하지 않기 | 증상 패치 6번의 원인. 열린 TUI 수정 PR 여럿이 이것에 기대고 있다 | M |
| 2 | 반복 감지 seed 순서와 경계 | 주력 lane 에서 반복 판정이 틀린다. 작다 | S |
| 3 | Board attention 후보 원장 종결 | 642MB 이고 계속 커진다 | M |
| 4 | checkpoint 저장 방식 | 하루 약 2TB 쓰기. 크고 위험해서 RFC 먼저 | L |
| 5 | Gate 목록 행 단위 격리 | 행 하나가 승인 화면 전체를 비운다 | M |
| 6 | Candle 가용성을 평가 lane 과 분리, 선물 받는 Keeper 확인 | 작고 확실하다 | S |
| 7 | Memory pass 와 JEV preflight 낭비 | 실행마다 139KB 재전송, preflight 85% 실패 | M |
| 8 | Curator 입력 크기 | 9분마다 884KB, 22% 실패 | M |
| 9 | 쓰기 요청 작업공간 묶기 한 곳으로 | 라우트마다 다르다 | M |
| 10 | Goal drop 재시도, Task 자동 보관 | 남은 작업이 쌓인다 | S·M |
| 11 | 계정 한도 분류 | 60초마다 재시도 | M |

## 지울 것

| 무엇 | 이유 | 결정 필요 |
|---|---|---|
| Task Hebbian 훅 | 쓰기만 하고 읽는 곳이 없다 | 아니오 |
| Board 테스트 뒷문 2곳 | 운영 코드에 시험용 진입점 | 아니오 |
| 웹 lane observation 복사본 3개 | 이름만 다른 같은 코드 | 아니오 |
| 대시보드 도달 불가 파일 35개, 호출자 없는 라우트 15개 | 영역 감사 E 목록. 지우기 전에 다시 확인 | 아니오 |
| `MASC_AUTH_STRICT` 측정 코드 | 측정만 하고 거절하지 않는다 | 예: 거절로 바꿀지, 지울지 |
| derived/premise 지지 집합 | 라이브 4건에 코드 353곳 | 예 |
| `exact-lane-runs-v5.jsonl`(779MB), `lane-addons-archive`(514MB) | 코드가 읽지 않는 라이브 데이터 | 예: 운영자 삭제 |

## 낭비

| 무엇 | 크기 | 어디서 |
|---|---|---|
| checkpoint 전체 다시 쓰기 | 하루 약 2TB 디스크 쓰기 | `keeper_agent_run.ml:1620-1690` |
| Memory pass 전체 기억 재전송 | 실행마다 약 139KB, 8시간에 약 495MB | 영역 감사 B D2 |
| Curator 프롬프트 | 약 9분마다 884KB, 하루 약 150MB | 영역 감사 D D6 |
| 도구 스키마 | Claude Code lane step 마다 약 152KB. cache 가 대부분 받는다 | 영역 감사 A |
| TUI 폴링 | tick 마다 요청 약 15개, 그중 7개가 /health | 영역 감사 E W-1 |
| 저장소 증거 파일 | `docs/evidence` 223.6MB, `dashboard/evidence` 13.8MB | 영역 감사 E, F |

## 용어

| 문제 | 제안 |
|---|---|
| "World Curator" 는 코드에서 `Workspace_curator` 다 | 용어집을 코드 이름으로 |
| "반감기" 는 코드에서 `half_life`, `Candle_decay` 다 | 같은 항목으로 묶기 |
| "Lane" 이 다섯 가지 뜻으로 쓰인다 | 뜻마다 이름 나누기. 별도 PR |
| Jev 와 JEV/Noul 표제어가 따로 있다 | 하나로 합침 |
| "Auto Judge" 는 조언처럼 들리지만 결정한다 | 이름이나 설명 고치기 |
| Candle 원장 종류 수가 코드와 다르다 | 개수 문장 지우기 |

## 확인하지 못한 것

- 계정 admission 큐(agent core 쪽 코드).
- JEV preflight 85%, Memory pass 139KB, Curator 884KB 수치는 영역 감사의 라이브 집계를 옮겼다. 합치는 단계에서 다시 재지 않았다.
- Fusion, DOS/MSX lane 내부, Verification 화면.
- 반복 감지 seed 문제의 라이브 재현. 코드 경로로만 확인했다.
