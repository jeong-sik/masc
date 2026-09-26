# 1주일 변경 감사 — 2026-09-26

[09-23 흐름·Tick 기록](2026-09-23-week-flow-and-tick-closure.md) 뒤를 잇는다.
그 기록이 다룬 09-23 10:40 KST 까지의 결함은 다시 적지 않는다. 여기에는 그 뒤 변경과,
09-23 기록에서 "열림"으로 남은 칸의 지금 상태만 적는다.

이번 기록은 발견마다 세 칸을 채운다.

1. 코드 경로: 그 동작을 만드는 file:line.
2. 라이브 동작: 그 경로가 실제로 돈 기록(로그 줄 수, 상태 파일, 원장).
3. 영향: 주장하는 피해 자체를 잰 값. 못 쟀으면 "추정"이라 적고 심각도를 올리지 않는다.

라이브에서 한 번도 돈 기록이 없는 결함은 "잠복"으로 따로 적는다.

## 공통 헤더

- 날짜(ISO8601): 2026-09-26T10:00:00+09:00
- 작성자: Claude (Opus 5.5), 영역별 감사 에이전트 6개 + 적대적 리뷰 에이전트
- 결정 ID: week-change-proof-20260926
- 적용 대상: MASC `origin/main fe6315aa69`, `<base-path>/.masc` 라이브 파일,
  라이브 서버 바이너리 `6e10ddd9ad`(main 보다 53 커밋 뒤), 로그 `system_log_2026-09-25.jsonl`
- 결정 상태: 추적 필요. "운영자 결정" 절의 다섯 항목은 결정이 있어야 닫힌다

## 1. 날짜별 흐름 (09-23 오후 … 09-26)

| 날짜 | 커밋 | 많이 바뀐 곳 |
|---|---|---|
| 09-23 | 337 | `fix(tui)` 70, `docs(glossary)` 50, `fix(keeper)` 28, `fix(librarian)` 14 |
| 09-24 | 184 | `fix(tui)` 31, `fix(keeper)` 26, `docs(glossary)` 24 |
| 09-25 | 203 | `fix(tui)` 36, `fix(keeper)` 16, `docs(rfc)` 8 |
| 09-26 | 57 (08:00 KST 까지) | `fix(tui)` 8, Muse Code·Stagehand 기능 |

흐름에서 읽히는 것:

- 기능 쪽 큰 줄기: Keeper 가 직접 Skill 을 발행(#38159), 기억을 supersede(#38122), provider 사용량 창을
  읽고 보여 줌(#38380·#38706·#38671·#39144), exact lane 과 공식 클라이언트 턴 사용량 집계(#39042·#39047),
  Stagehand 브라우저 레인, DOS 레인.
- 4일 동안 `fix(tui)` 가 145개다. 그중 13개가 "푸터가 맨 아랫줄에 앉는다", "머리 줄을 잘못 세어 넘쳤다" 같은
  줄 수 계산 수정이다. 화면마다 머리 줄 수를 손으로 세는 구조라 같은 종류 수정이 화면 수만큼 반복된다.
  `Masc_tui_layout.allocate` 가 생겼지만 쓰는 화면이 적다.
- 운영자 결정 하나가 앞 작업을 덮었다. 09-25 라이브 화면 검토에서 RFC-0464 Overview Team 배치를 버리고
  첫 화면을 Dashboard 로 바꾸기로 했다(#38801, 아직 열림). 그래서 이번 감사에서 연 Team 블록 수정(#39177)은 닫았다.

## 2. 발견과 증명

심각도: P1 = 보통 운영에서 기능이 깨지거나 데이터를 잃음, P2 = 현실적인 경우에 틀림, P3 = 정리.

### P1

| ID | 무엇이 틀렸나 | 코드 경로 | 라이브 동작 | 영향 | 처리 |
|---|---|---|---|---|---|
| B1 | 판정 레인의 provider 가 모두 한도에 걸려 잠시 쉬는 상태를, 다시 해도 안 되는 실패로 보고 Board 판정 후보를 격리한다 | `keeper_board_attention_worker.ml:966-972`(`Providers_exhausted`·`Cli_slots_exhausted` → `Exact_lane_exhausted` → Blocked), drain 이 `Partition_blocked` 뒤에도 계속 돌아 대기 후보를 전부 같은 레인에 던짐(`:1886`) | 후보 원장 마지막 상태: 소비 11,022 · 격리 1,765. 격리 중 `exact_lane_exhausted` 가 09-25 하루 1,459, 09-24 109 | 1,459 개 Board 신호를 Keeper 가 받지 못했다. 되돌리는 길은 운영자가 한 줄씩 `Q` 누르기뿐 | #39186: 모든 slot 이 계정 사정(rate limit·quota·과부하·결제)으로 쉬는 거절일 때만 기다린다. 라이브 행으로 셈하면 1,518 개는 기다리고, Antigravity `RESOURCE_EXHAUSTED`(타입 없음)가 낀 160 개는 여전히 격리된다(#39190) |
| B2 | HTTP slot 이 모두 보내기 전에 거절되고 CLI 꼬리가 답하면, 그 답을 버리고 후보를 격리한다 | `keeper_board_attention_partition.ml:1629-1630` `Advancing` 에서 완료 거절 | `exact_completion_failed` 126 건 모두 `advancing, execution_anchor:null` | 판정은 나왔는데 전달되지 않은 126 건 | #39188 |
| R1 | exact lane 의 CLI slot 이 Codex 사용량 한도 거절을 어디에도 적지 않아, 판정마다 다 쓴 계정을 다시 부른다 | `fusion_official_client.ml:233-241` 은 Claude `Quota_blocked` 만 적음, `:298` Codex 는 적지 않음. `keeper_lane_cli_oneshot.ml:104-128` 은 순서만 뒤로 보냄 | 09-25: Board 판정 CLI slot 실패 codex 1,677 · claude 1,459 · antigravity 402, runtime `quota_blocked` 2,448 · Codex 실패 2,443 | 판정 하나마다 다 쓴 계정 서너 곳에 먼저 부딪힌다. Board 격리(B1)의 앞 원인 | #39173 (Codex 만). Antigravity `RESOURCE_EXHAUSTED` 는 타입이 없어 남음 |

### P2

| ID | 무엇이 틀렸나 | 코드 경로 | 라이브 동작 | 영향 | 처리 |
|---|---|---|---|---|---|
| C1 | 공식 클라이언트 Resume 이 매 턴 조립 맥락(Skills·Memory·briefing·working state) 전체를 다시 보낸다 | `keeper_official_client_host.ml:146-161` `resume_prompt` | e-masc-the-leader Claude Code 세션 하나: 턴 90, 압축 13. 턴마다 약 154k 자 블록, 앞 턴과 텍스트 줄 97% 같음 | 압축 구간마다 창의 79~91% 가 이 사본. 턴 첫 요청 캐시 쓰기 중앙값 117,770 토큰, 90 턴 합계 1,119만 토큰. 압축 뒤 기억 손실은 재지 않음(요약에 요청·PR·sha 는 남아 있었다) | 열린 #38986(Claude Code), #38822(Codex 새 thread). 남은 것은 #39195 |
| L1 | Librarian 연속성 회차가 Memory 를 쓴 범위를 durable 회차가 알아보지 못하고 다시 흡수한다 | `keeper_librarian_queue_refresh.ml:318-320` 이 `durable_range_id` 로 커밋, durable 쪽 `keeper_librarian_durable_consumer.ml:845-881` 은 자기 scope 영수증만 봄 | 영수증 scope 가 다르다(`<keepers>` 대 `<keepers>/<k>/librarian-continuity.json`). 22 Keeper 중 3 명의 마지막 영수증이 겹침(jazz-developer [6416,6455) rev 1444 → 1447 등). 09-25 연속성 커밋 47 건 | 같은 atom 을 모델에 두 번 보낸다. 몇 건이 Memory 까지 썼는지는 로그에 없어 빈도는 일부만 잼. 같은 주장 재추가는 #38317 이 막음 | #39179 |
| R2 | GLM 한도 코드를 exact 경로만 평범한 429 로 읽는다 | `exact_output_execution.ml:202-214`. #38742 가 세 자리 중 두 자리만 고침 | 확인 못 함 | 추정: exact lane 이 GLM 주간 한도를 60 초 휴식으로 다룸 | #39178 |
| R3 | 쉬는 시간이 거의 늘 두 상수다. provider 가 알려 준 리셋 시각은 화면에만 쓰인다 | `env_config_keeper.ml:554`(60 초), `:566-570`(900 초), `keeper_runtime_failure_route.ml:430-449` | 09-25: `waits 60s` 1,402, `waits 900s` 441. ocaml-agent-ic 는 한 후보 레인에서 약 62 초마다 GLM 을 다시 불러 하루 414 번 실패. context-reviewer 는 연속 실패 123 으로 하루를 끝냄 | 5 시간·주간 한도에 60 초 휴식이면 Keeper 하나가 5 시간에 약 300 번 헛돈다 | 운영자 결정(아래), #39190. #38975·#39149 가 Kimi 403 만 다룸 |
| R4 | 이유를 말하지 않은 429 와 날짜 없는 quota 는 성공이 올 때까지 후보를 뒤에 묶어 둔다 | `keeper_turn_driver.ml:213-215`, `runtime_candidate_backpressure_state.ml:44-50`, `runtime_quota_window.ml:62-72` | 확인 못 함 | 추정: 리셋 뒤에도 레인이 fallback 에 머묾 | #39190 |
| H1 | 부팅 때 Keeper meta 를 못 읽으면 그 Keeper 를 지워진 것으로 보고 승인 대기 행을 정리한다 | `keeper_approval_queue.ml:4571,4586`, `keeper_meta_store.ml:289-293` 이 `Meta_not_current` 를 `Ok None` 으로 접음 | 잠복. 열린 #39025 가 배포되면 살아 있는 meta 파일 전부가 거부된다고 그 PR 이 적었다 | 리셋 절차보다 새 바이너리를 먼저 띄우면 승인된 효과가 실행되지 않는다 | #39174 |
| S1 | Schedule 을 취소해도 이미 Keeper 에게 넣은 wake 는 남는다 | `tool_schedule.ml:1223` → `schedule_store.ml:829` | 확인 못 함 | 멈춘 Keeper 가 나중에 취소된 회차를 돈다 | #39189 |
| M2 | Keeper 가 기억을 고치려다 3 분의 1 이 거절된다. 가장 큰 이유는 id 가 아니라 "자기가 쓴 사실만 바꿀 수 있다" | recall 에 id 없음(`keeper_memory_os_render.ml:20-28`), supersede 는 자기 사실만 | 09-25 `supersedes` 호출 339, 성공 217. 09-24~25 거절: `not_authored` 66, `not_current` 48, `invalid` 38, 짧은 id(`m3`) 10 | Librarian 이 쓴 낡은 사실을 Keeper 가 바꿀 길이 없다 | 운영자 결정(아래), #39191 |
| M3 | 파일에 묶인 사실은 같은 경로로 다시 쓰면 앞 사실이 말없이 사라지고, Keeper 가 지울 수도 없다 | `keeper_memory_source_current.ml:580`, 영수증 `keeper_tool_memory_runtime.ml:1590-1614` | 확인 못 함 | 추정 | #39191 |
| G1 | 검증 칸 넷이 다 찬 동안 들어온 Goal 은 칸이 비어도 다시 훑지 않는다 | `goal_verification_agent.ml:733,759` | 확인 못 함 | 추정 | #39192 |

### 잠복 (라이브에서 돈 기록 없음)

| ID | 무엇 | 코드 경로 | 처리 |
|---|---|---|---|
| K1 | Task 가 고정한 Skill 본문이 읽기 한도를 넘으면 턴 준비가 통째로 실패한다(#39138 뒤) | `keeper_skill_catalog.ml:186-199` → `keeper_task_skill_turn.ml:41-42` | #39175 |
| T1 | Gate 대기열을 못 읽는 동안 Approvals 가 화면 띠에서 사라진다 | `bin/masc_tui_types.ml:10583-10588` | #39172 |
| M1 | 관리자 retraction 뒤 journal 에 못 읽는 줄이 하나라도 있으면 그 Keeper 의 이후 기억 쓰기가 전부 막힌다 | `keeper_memory_os_current.ml:1722,1761,1956` | #39191. 라이브 journal 24 개에 옛 형식 줄 0 |
| L2 | 턴 조각 줄 하나를 못 읽으면 공식·atom 읽기가 같이 멈춘다 | `keeper_librarian_durable_consumer.ml:435-460` | #39193. 라이브 조각 파일 48 개에 나쁜 줄 0 |
| D1 | 열린 #39025 를 리셋 없이 띄우면 Keeper meta 가 "거부"되는 게 아니라 park 되고 선언에서 새로 만들어진다. 누적 counter 와 task 연결이 사라진다(#29610) | `keeper_meta_store.ml:288-293` 이 not-current 를 `None` 으로 접음 → `keeper_runtime.ml:571-590` park·재생성. 막는 preflight 는 `deploy.sh` 만 부름(`check-runtime-deployment-preflight.sh:157-166`), `install-local-build.sh` 는 부르지 않음 | #39025 에 코멘트. 라이브 meta 24 개 전부가 지울 키를 가짐 |

### 열린 PR 판정 (이 세션이 쓰지 않은 것)

| PR | 판정 | 이유 |
|---|---|---|
| #38986 Claude Code Resume held set | FAIL(코멘트) | 오늘은 동작한다(Claude Code 2.1.283 `--system-prompt-snapshot` 기본값 `on`). masc 가 이 값을 넘기지 않는데, RFC-official-client-conversation-in-masc §5.4 가 `off` 를 운영자 결정 후보로 올려 두었다. 그 결정이 나면 Resume 이 바뀌지 않은 Memory·Skills 블록을 말없이 뺀다. 플래그를 명시해 고정해야 한다 |
| #38822 Codex 새 thread 범위 | FAIL(코멘트) | 핵심 수정은 맞다. Resume 마다 Librarian working state 를 다시 싣는다(C1 과 같은 모양). 리뷰 뒤 head 가 #38891 을 얹어 파일 37 개가 늘었고 새 head 는 CI 가 없다 |

### 증명하다 뒤집힌 것

- #39188 을 diff 만 읽고 PASS 로 봤다 — CI 새 테스트가 실패했다. 완료 규칙이 `complete` 와 ledger 전이 표
  (`legal_transition`) 두 곳에 있었고 한 곳만 고쳤기 때문이다. 두 곳에 같은 조건을 넣은 뒤 초록이 됐다.
  #39179 도 마지막 수정이 main 규칙("slot 하나의 한도가 다른 provider 를 막지 않는다")을 깨서 기존 테스트가
  빨갛게 됐고, 거절 뒤에만 durable 회차에 넘기도록 고쳐 초록이 됐다.

- B1 첫 설계 "AGENT_CORE 가 advanceable 로 끝낸 walk 는 모두 미룬다" — advanceable 에는 창을 넘는 입력, 거절된 요청 본문,
  401·403·404, 잘못된 출력이 들어 있다. 다시 해도 같은 실패를 미루면 oldest-first drain 이 그 후보에서 멈춰
  그 Keeper 의 Board 판정이 영원히 막힌다. 적대적 리뷰가 잡았고, #39186 은 "계정 사정으로 쉬는 거절" 만 기다리게 좁혔다.

- "Resume 압축 때문에 Keeper 가 10 턴 전 일을 잊는다" — 압축 요약에 요청·PR 번호·sha 가 남아 있었다.
  잰 것은 압축 빈도와 사본 비율이다. C1 으로 낮췄다.
- "Keeper 는 recall 에서 기억 id 를 못 봐서 supersede 를 못 한다" — 검색과 쓰기 영수증에서 id 를 얻어
  하루 217 번 성공한다. 주된 거절은 작성자 규칙이다. M2 로 고쳐 적었다.
- "Librarian CLI slot 이 official client 가 아니라고 920 번 실패" — main 이 설정을 읽을 때 거절하도록 이미
  고쳤고(`runtime.ml` exact lane cli_slots 검증), 라이브 설정도 09-25 05:22Z 에 바로잡혔다.

## 3. Tick 닫힘 (바뀐 칸만)

| 순환 | 1 tick | 2 tick | N tick | 닫힘 |
|---|---|---|---|---|
| Board 판정, 레인 전부 한도 | 후보 하나 격리 | 같은 drain 이 다음 후보도 격리 | 한도가 풀려도 격리된 후보는 돌아오지 않음 | 열림 → #39186 뒤: 후보는 Pending, 다음 신호·재개·재시작에 다시 시도 |
| exact lane CLI slot, Codex 한도 | 판정마다 codex 에 부딪힘 | 같음 | 리셋까지 매번 | 열림 → #39173 뒤: 순서만 뒤로. 건너뛰지는 않음 |
| Keeper 턴, 한 후보 레인 GLM 429 | 60 초 쉼 | 다시 429 | 한도가 풀릴 때까지 60 초마다 | 닫히긴 하지만 헛돈다. 운영자 결정 |
| Librarian durable 실패 뒤 연속성 회차 | 연속성이 [P, cut) 기억을 씀 | durable 이 같은 범위를 다시 모델에 보냄 | 실패가 날 때마다 반복 | 열림 → #39179 |
| 공식 클라이언트 Resume | 맥락 블록 전체 전송 | 97% 같은 블록 다시 전송 | 약 7 턴마다 vendor 압축 | 닫힘(압축으로). 비용이 큼. #38986 |

## 4. 운영자 결정 필요

1. 쉬는 시간: provider 가 알려 준 리셋 시각(Codex `account/rateLimits`, Kimi·Z.AI·Ollama 사용량 읽기)을
   라우팅이 써도 되는가. 지금 용어집 "Provider Usage Window" 는 "라우팅은 읽지 않는다"고 적는다.
   #38975 가 Kimi 403 에서 이미 이 규칙을 넘는다.
2. Keeper 가 자기 Librarian 이 쓴 사실을 supersede 할 수 있어야 하는가(M2, 이틀에 66 번 막힘).
3. Memory recall 블록 상한(#36687). rondo 168,601 B(09-23) → 223,354 B(09-26). 지금 레인의 가장 작은 창은
   272k 토큰이라 당장 넘치지는 않는다.
4. 이미 격리된 Board 판정 후보 1,765 개를 다시 넣을지. #39186 은 새로 생기는 격리만 막는다.
5. #39025 를 배포할 때 meta 리셋을 새 바이너리보다 먼저 한다. `install-local-build.sh` 경로에는 meta 검사가 없다. 리셋 없이 띄우면 거부가 아니라
   Keeper 24 개 meta 가 모두 park 되고 새로 만들어진다(아래 D1). #39174 는 그 창에서 승인 대기 행이 지워지는 것만 막는다.

## 5. 용어집 어긋남

| 항목 | 지금 문장 | 코드 |
|---|---|---|
| Board 판정 격리(`00-glossary.md:319-331`) | 레인 소진도 격리 원인, 재시작으로 끊긴 실행은 "재투입 가능" | 되돌리는 건 운영자뿐. #39186 이 고침 |
| Librarian Round | 연속성 회차는 스냅숏만 만든다 | Memory 도 쓴다. #39179 가 고침 |
| Provider Usage Window(`:631-634`) | 라우팅은 읽지 않는다 | #38975 가 403 뒤 읽기를 라우팅에 쓴다 |
| 닫힌 quota 창(`:131-137`) | provider 는 남은 양을 알려 주지 않는다 | 사용량 창 읽기가 비율을 준다(#38380·#38706) |
| Runtime Candidate Order(`:806`) | 배정 runtime 이 실패할 때 쓰는 순서 | 매 턴 머리부터 걷는 순서 |
| Fact | 모든 Fact 에 Memory ID 가 있다 | 파일에 묶인 사실(`memory-source-current.json`)에는 없다 |
| Team 블록(`:109-114`) | 네 묶음 | 코드는 여섯. #38801 이 블록을 지우면 항목도 지운다 |

## 6. 결합과 분리

09-23 기록 3절 표는 그대로다. 이번에 더한 것만 적는다.

- Board 판정 worker 가 Keeper meta 를 직접 읽어 멈춤 여부를 본다. 수명 판정 함수 하나를 받으면 된다.
- 반응 원장(reaction ledger)이 대기열을 남길지 정하려고 멈춘 작업 영수증 파일 경로를 stat 한다.
  "기다리는 요청자" 집합을 타입으로 넘기면 저장 위치를 몰라도 된다.
- 공식 클라이언트 세 레인이 바뀐 시스템 프롬프트를 다르게 다룬다. Claude Code·Codex 는 Resume 에서 무시하고
  Antigravity 는 새 세션을 연다. 한 규칙이면 된다.

## 근거

- 영역별 감사: Runtime Failover, Librarian, Keeper context, Memory·Skills, Board·Task·Goal·HITL·Schedule, TUI.
  각 보고의 영향 문장은 이 기록에 옮기기 전에 라이브 파일로 다시 확인했다.
- 라이브 측정 명령은 모두 읽기 전용이다(`rg`, `jq`, Python 으로 transcript 분석).
- Claude Code 세션 분석: `~/.claude/projects/-Users-dancer-me/01a0d3fd-496a-7000-a61d-6ffc22a4a7e9.jsonl`.

## 불확실성

- 라이브 서버는 main 보다 53 커밋 뒤다. 로그의 동작 일부는 main 에서 이미 바뀌었을 수 있다.
  그래서 발견마다 main 코드 경로를 따로 확인했다.
- R2·R4·S1·M3·G1 은 코드로만 확인했다. 라이브 빈도는 모른다.
- C1 이 Claude Code 한도 소진(`quota_blocked` 2,448)에 얼마나 보탰는지는 모른다. 구독 한도 계산 방식이 공개돼 있지 않다.

## 적용범위

MASC 저장소와 `<base-path>/.masc` 라이브 운영 파일. 코드 수정은 위 표의 PR 들이 한다. 이 기록은 코드를 바꾸지 않는다.
