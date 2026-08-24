---
status: active
last_verified: 2026-08-24
code_refs:
  - bin/masc_tui.ml
  - bin/masc_tui_types.ml
  - bin/masc_tui_render.ml
  - docs/TUI-GUIDE.md
  - docs/design/tui/TUI-SPEC.md
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
  + CI 스위트 등록(`scripts/ci-run-focused-tests.sh`) + `docs/TUI-GUIDE.md` 절
  + 라이브 `:8935` tmux 캡처를 PR 에.
- 대시보드 불변식 `INV-DASH-001~006` (`docs/spec/10-dashboard.md`) 을 TUI 도
  그대로 진다: 표시는 typed source fact, 실패는 명시, 스트림 순서 보존.
- 렌더 기반(현 ANSI 직접 vs Notty)은 위 화면들이 붙은 뒤 `masc_tui.ml` 줄
  수와 프레임 시간을 재서 결정한다. 지금은 결정하지 않는다.

## 참고 조사 (2026-08-23 fetch, 세션 기록)

Codex CLI 의 로스터 3분류(`Needs input / Working / Ready`)와 승인 문구의
범위 표현, Orca 의 상태 글리프 5종·Agents feed, OpenClaw 의 "승인 =
게이트웨이 이벤트", Hermes 의 상태바 폭 적응은 채택 대상. Hermes 의 regex
위험 분류·보조 LLM 승인은 문자열 분류기라 채택하지 않는다. 옛 claude-code
에서: 도구 출력 "펼칠 게 있을 때만 안내", 조회성 연속 호출 접기, "디스크가
진실·화면은 창", 스트리밍은 마지막 개행까지만, `ctrl+x` 접두 코드 키.
