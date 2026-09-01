---
status: active
---

# MASC TUI Roadmap — 키퍼 작업대 캠페인 (2026-08-24)

> 목표가 바뀌었다. 1기(2026-08-23, P0~P2 15항목)는 대시보드 화면을 터미널로
> 옮기는 일이었고 완료됐다. 2기는 **키퍼 10개에게 일을 맡기고, 그들의 행동
> (도구 호출·생각·승인 요청)을 실시간으로 보고, 결과를 터미널에서 판정하는
> 운영자 작업대**다. 대시보드에 없는 능력이 중심이다.
>
> 1기 로드맵의 "P3 — 구현하지 않음" 판정은 운영자 지시(2026-08-24)로
> 뒤집혔다: 브라우저 렌더링 전용(`lab > performance`, Monaco 편집기)만 빼고
> 대시보드의 모든 section 을 표·피드·상세로 표현한다. `code > ide-shell` 은
> "키퍼가 만든 diff/PR 을 읽고 판정하는 화면"으로 축소해 수용한다.

## 운영자 피드백 20항목 재감사 (2026-09-01)

이 표는 2026-09-01의 `main`과 병합/열린 PR을 다시 읽은 결과다. `병합`은
소스가 `main`에 있다는 뜻이고, `Draft`는 아직 빌드·PTY·병합 전이다. 운영자
요청에 따라 이 캠페인의 후속 PR에서는 빌드를 실행하지 않았으므로, 아래 표를
실행 바이너리 증거로 읽으면 안 된다.

| # | 요구 | 현재 근거 | 판정 |
|---|---|---|---|
| 1 | Repositories와 Code에서 등록/미등록 Git Changes 보기 | #32110은 저장소 범위, #32124는 현재 프로젝트 범위 Changes를 연다. | 병합 |
| 2 | Repositories의 불필요한 Keeper 비교 열 제거, 전체 경로 표시 | #32104 이후 목록은 Name/Branch/Status/Sync/Path이고, 선택 상세는 resolved absolute `Path`와 상대 `Stored as`를 줄바꿈한다. Keeper는 비교 열이 아니라 선택 상세에만 남는다. | 병합 |
| 3 | Runtime lane/all rows의 잘린 상세 보기 | #32123의 identity-bound detail이 전체 runtime id/provider/model/lane/probe/error를 페이지로 표시한다. | 병합 |
| 4 | Config runtime.toml PageUp/PageDown과 값 행 탐색 | #32113이 `j/k`를 assignment 행에만 착지시키고 PgUp/PgDn을 보이는 페이지 단위로 연결한다. | 병합 |
| 5 | Models effort/temperature/max-token의 빈 값 의미와 개별 spec/추가 경로 | #32113과 #32191이 `-`를 실제 key 부재로 정의하고 `[models.NAME]`/`[PROVIDER.NAME]` 소유 섹션과 API model을 표시한다. `e`는 기존 preview-checked runtime.toml 편집 경로로 이동한다. | 병합 |
| 6 | Config Params를 실제로 설정 | typed registry 행에서 `Enter`는 친화적 값, `E`는 JSON, `x`는 등록 기본값 복원으로 동작한다. | main 소스 |
| 7 | Prompt 분류 축소, 한국어화, 낡은 내용 정리 | #32133이 본문/설명을 한국어로 맞추고, #32155가 낡은 Librarian 규범을 제거했으며, #32158이 6개 완성 prompt를 기본 목록으로 축소하고 14개 assembly fragment는 `a` 뒤로 옮겼다. | 병합 |
| 8 | Theme 확장·대비·정렬·긴 이름 | #32184가 cell-width 열 정렬과 대비 의미를 표시한다. #32202는 37개 번들 중 native-pass를 먼저, lift cost와 이름순으로 정렬하고 개수를 표시한다. | 병합 + Draft #32202 |
| 9 | Resources 설명, pretty/syntax-highlight detail, `[/]` 이동 | #32130과 #32136이 inventory 의미, metadata, pretty JSON/Markdown, syntax highlight, 인접 resource 이동을 추가했다. | 병합 |
| 10 | Tools의 surface/async/activations/usage/catalog 차이와 사용 여부 | #32130 이후 5개 pane을 분리하고 각 pane의 질문·원천·빈 상태를 설명한다. effective Keeper surface와 activation/usage evidence가 사용 여부를 구분한다. | 병합 |
| 11 | Logs 폭·category·verbose·상세 | #32138은 폭 적응 목록/정확한 상세를, #32148은 level floor/category를 추가했다. #32203은 `v`로 DEBUG verbose를 직접 켜고 끄며 헤더에 상태를 표시한다. | 병합 + Draft #32203 |
| 12 | Overview Attention/Events/Tasks의 의미·색·Goal 계층 | #32134가 Tasks를 Goal 묶음과 상태색으로 표시하고 #32137이 Attention age와 `TUI Session Events` 이름을 추가했다. Attention은 producer의 현재 condition이며, timestamp가 없으면 condition 해소까지 남는다는 경계를 화면에 유지한다. | 병합 |
| 13 | Acting 분류·event type·회색/composite/internal 의미 | #32177이 turns/actions/everything scope와 회색/Composite/Internal Agent Run 설명을 화면/가이드에 추가했다. | 병합 |
| 14 | Keeper와 Lanes 중복, A/P/S·Turns·lifecycle/runtime 혼동 | #32140이 누적 Turns를 마지막 turn age로 바꾸고 #32174가 Keeper operations와 4개 standalone LLM lane을 중복 없이 분리했다. 합쳐 그리는 대신 소유 authority를 분리한 결정이다. | 병합 |
| 15 | Standalone lane slot 설정·fallback·전체 Input/Output·Verifier/tool/approve 결과 | #32185가 JSON highlight/64KiB 경계를, #32189가 Verifier Task/Goal verdict와 tool evidence를 추가했다. #32194는 4개 lane 목적, TOML schema, catalog→CLI fallback, drop/error, `e` 설정 이동, tool-less exact flow와 Verifier evidence 차이를 펼쳐 표시한다. | 병합 + Draft #32194 |
| 16 | Board/Planning 정렬 기준과 시각적 흐름 | #32180이 정렬 기준을 화면에 표시하고 #32186이 Planning을 Goals→Task Review→Evaluator Verdicts로 묶으며 Goal detail의 linked Task/actor/handoff flow를 추가했다. | 병합 |
| 17 | ASCII/움직임/조명 효과 | 현재 source는 긴 Keeper 이름 왕복 marquee, 실행 중 activity pulse, 완료 후 60초 glow를 갖고 있으며 비활성 화면에서는 animation frame을 멈춘다. | main 소스 |
| 18 | Schedule 마지막 동작·실행 기록·생성/수정 | #32139/#32141/#32171이 create/modify/cancel을 한 경로로 정리하고 last wake/queue/reaction/turn-start를 표시한다. #32204는 버려지던 Keeper/stimulus/occurrence/timestamp/reason을 표시하고 schedule receipt가 tool/result를 인과 귀속하지 못한다는 경계를 명시한다. | 병합 + Draft #32204 |
| 19 | Fusion outcome 요약·rich text·live progress·tool trace | #32144가 stage/progress/summary, #32146이 durable tool trace, #32147이 Markdown detail과 tool execution evidence를 추가했다. | 병합 |
| 20 | IDE file별 Keeper 작업 기록 | #32192가 Code file detail에 durable Keeper edit activity를 연결했고 #32196이 병합 직후 남은 컴파일 오류를 수리했다. | 병합 |

### 남은 완료 게이트

- Draft #32194, #32202, #32203, #32204를 운영자가 빌드한 exact HEAD에서
  compiled tests와 PTY 화면으로 확인한다.
- 확인된 PR만 `main`에 병합하고, 병합 뒤 실행 바이너리 identity와 영향을 받은
  화면을 다시 확인한다. 소스 존재나 Draft 생성만으로 이 캠페인을 완료 처리하지
  않는다.

## 2기의 새 능력 (대시보드에도 없는 것)

| # | 능력 | 상태 | 근거 |
|---|---|---|---|
| N1 | 일 맡기기 — composer `/task` 가 `masc_add_task` 를 부르고 키퍼에게 id 를 붙여 전달 | PR #29923 | 라이브로 task-504 생성 실측 |
| N2 | Acting 화면 — 전체 키퍼의 도구 호출·턴 경계·정산을 한 화면에 실시간 | PR #29857(observer SSE 구독) + #29863 | 조사한 Hermes·OpenClaw·Orca·Codex CLI 모두 터미널 하나에 세션 하나 — 이 자리가 비어 있었다 |
| N3 | 키퍼별 도구 호출 이력 — 명부/상세 `t` | PR #29928 | `/api/v1/keepers/:name/tool-calls` 는 브라우저만 그리던 경로 |
| N4 | 채팅 이력의 자율 턴 trace 표시 | #29841 병합, 후속 #29859 | 빈 행 32건 뒤에 도구 스텝 1,333개가 있었다 |
| N5 | 멀티 키퍼 동시 스트림 (`msg_live` map) | 미착수 — task-470/#29818(fence 제거) 뒤 | |
| N6 | 폴링 → observer 스트림 대체 | 미착수 — N2 안착 후 측정으로 결정 | |
| N7 | 합성 실행 트리 (`parent_event_id` 들여쓰기) | 미착수 — `keeper_plan_execute` 사용이 생기면 | |

## 사실 표시 결함 (새 기능보다 먼저)

| 결함 | 상태 |
|---|---|
| 미읽음을 빈 결과로 그림 (`empty_page_of` 3구분, 9곳) | PR #29844 |
| 행 시각 UTC vs 헤더 로컬, `Agents: 2` 오독 | PR #29847 |
| briefing 이 같은 사실을 두 목록에 실어 Attention 이중 표시 | PR #29936 |
| Keepers 첫 로드 `? unknown` | PR #29844 (`- unread`) |

## 화면 매트릭스 (2026-08-24 기준)

TUI 에 있는 것: Overview(+task detail), Acting(#29863), Keepers(list/detail/
logs/calls#29928/chat), Approvals, Board(list/read/compose/vote/comment),
Planning(list/detail+전이), Schedules(#29814, 목록+취소), Verification,
Harness, Repositories, Connectors, Tools, Autonomy, System Logs.

키퍼에게 backlog 로 배정된 것 (task 본문이 원천 API·템플릿·계약을 지정):

| task | 화면 | 원천 |
|---|---|---|
| task-500 | Lanes | `GET /api/v1/keepers/composite` |
| task-501 | Fusion (목록+상세) | `GET /api/v1/dashboard/fusion-runs` |
| task-502 | Command (digest+action) | `GET /api/v1/operator/digest`, `POST /api/v1/operator/action` |
| task-503 | Runtime | `GET /api/v1/dashboard/runtime-probe` |
| task-504 | Fleet-health | `GET /api/v1/dashboard/telemetry` |
| task-505 | Internal-agents | exact-lane/fusion/verification runs |
| task-506 | Keeper-memory-health | `GET /api/v1/dashboard/keeper-memory-health` |

남은 미등록: observatory, registry(`dashboard/execution`), settings(읽기,
`dashboard/config`·`runtime/resolved`·`providers`), journey 심화(turn-records
·trajectory 뷰), diff 리뷰(`GET /api/v1/git/diff?path=&base_ref=` 활용).

## 규약

- 화면 추가 = 폴링 화면 템플릿 복제(Harness 가 본보기), surface variant 삽입
  위치를 task 가 고정한다(같은 줄 충돌 방지). 빈 본문은 `empty_page_of` 세
  구분.
- 모든 PR: Alcotest(디코더) + PTY 프레임 테스트(`test/test_tui_keyboard_input.py`)
  + `docs/TUI-GUIDE.md` 절 + 라이브 `:8935` tmux 캡처를 PR 에. 테스트를 어딘가에
  따로 등록할 필요는 없다. `test/dune` 에 스탠자를 추가하면 CI 가 `@test/runtest`
  로 같이 돈다 — 894개를 손으로 나열하던 목록 파일은 #30010 이 걷어냈다.
- 대시보드 불변식 `INV-DASH-001~007` (`docs/spec/10-dashboard.md`) 을 TUI 도
  그대로 진다: 표시는 typed source fact, 실패는 명시, 스트림 순서 보존, 대기 중인
  HITL 을 키퍼나 작업 공간이 멈춘 것으로 그리지 않는다.
- 렌더 기반(현 ANSI 직접 vs Notty)은 위 화면들이 붙은 뒤 `masc_tui.ml` 줄
  수와 프레임 시간을 재서 결정한다. 지금은 결정하지 않는다.

## 참고 조사 (2026-08-23 fetch, 세션 기록)

Codex CLI 의 로스터 3분류(`Needs input / Working / Ready`)와 승인 문구의
범위 표현, Orca 의 상태 글리프 5종·Agents feed, OpenClaw 의 "승인 =
게이트웨이 이벤트", Hermes 의 상태바 폭 적응은 채택 대상. Hermes 의 regex
위험 분류·보조 LLM 승인은 문자열 분류기라 채택하지 않는다. 옛 claude-code
에서: 도구 출력 "펼칠 게 있을 때만 안내", 조회성 연속 호출 접기, "디스크가
진실·화면은 창", 스트리밍은 마지막 개행까지만, `ctrl+x` 접두 코드 키.
