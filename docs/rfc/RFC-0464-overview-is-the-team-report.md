---
rfc: "0464"
title: "Overview 는 팀 업무 보고다 — 누가 무엇을 하고, 무엇이 막혔고, 얼마나 끝냈나"
status: Draft
created: 2026-09-23
author: dancer + claude
supersedes: []
superseded_by: null
related: ["tui-operator-ia", "0462"]
---

# RFC-0464: Overview 는 팀 업무 보고다

## 0. 결정

`RFC-tui-operator-ia` §3.1 J 항("Overview fleet home")을 실행한다.
Overview 한 화면이 세 질문에 답한다.

1. **누가 무엇을 하고 있나** — Keeper 한 명당 한 줄. 상태, 잡은 Task, 마지막 턴 나이.
2. **무엇이 막혔나** — 막힌 Keeper 는 원인과 함께 맨 위에 모인다.
3. **얼마나 끝냈나** — 최근 14일 완료·생성 막대와 오늘 완료 수.

새 서버 API 는 만들지 않는다. 필요한 값은 이미 TUI 가 받고 있다.

## 1. 기준선 (2026-09-23, main `0936c2bb97`, 132×40 실측)

| 자리 | 지금 화면 | 문제 |
|---|---|---|
| Tasks 머리줄 | `687 · 0 done · 17 active · 8 awaiting · 662 todo` | `state.tasks` 는 끝난 Task 를 담지 않는다. `0 done` 은 항상 0 이다 |
| Tasks 목록 | todo 662개가 23줄을 채운다 | 지금 일하는 17개·검증 대기 8개가 그 사이에 섞여 묻힌다 |
| Attention | 7줄이 같은 문장 `turn failed N cycle(s); inspect the last runtime error` | 원인이 없다. 132열에서는 `runtime…` 에서 잘린다 |
| TUI Session Events | `TUI started`, `feed open` 3줄 | TUI 프로세스 자기 로그다. 팀 상태와 무관하다 |
| briefing `keeper_briefs` | 16행을 받지만 개수만 센다 | phase, current_work, last_turn_ago_s, context_ratio 가 버려진다 |
| `state.task_flow` | Metrics 화면에 숫자 격자로만 | 14일 추이를 그리는 곳이 없다 |

Attention 원인 누락은 서버 쪽 문제다(부팅 때 저장된 실패 횟수만 되살리고 원인은 버린다).
별도 PR 에서 고친다. 이 RFC 는 그 원인 문장이 도착하면 Team 행에 그대로 싣는다.

## 2. 화면

```
 Team  9 working · 3 need you · 4 paused                    Done today 5 · 14d ▁▂▁▅█▃▁▂▄▆▂▁▃▅
  ! tui-developer    failing  4m   rate limited on claude_code.claude-opus-5-medium
  ! ocaml-agent-ic   failing  12m  turn failed 2×
  ● glossary-maniac  running  1m   task-1519 최근 5일 일자별 diff 전수 리뷰          2 awaiting
  ● geek-scout       running  58s  (no task)
  ○ lane-smith       paused   2d
```

- 행 순서: 막힘(failing·keepalive 멈춤) → 일하는 중 → 쉬는 중 → paused·offline.
  같은 무리 안에서는 이름순. 가중치나 점수로 정렬하지 않는다.
- 막힌 행의 설명은 서버가 준 blocker 문장이다. TUI 가 원인을 추측하거나 문자열을 해석하지 않는다.
- 일하는 행의 설명은 그 Keeper 가 담당한 InProgress/Claimed Task 제목이다.
  검증 대기 Task 는 개수로 붙인다.
- `Done today` 는 `task_flow.recent.completed` 다. 14일 막대는 `task_flow.daily` 의 완료 수다.

Tasks 목록의 순서는 바꾸지 않는다. 지금 순서(Goal 묶음, 가장 급한 우선순위 순)는
`Tui_decode.active_tasks_of_domain` 이 정하고 다른 화면과 커서가 같이 쓴다.
"지금 누가 무엇을 하나" 는 Team 패널이 답한다.

## 3. 스택

| # | 내용 | 파일 |
|---|---|---|
| 1 | Tasks 머리줄의 늘 0 인 `done` 을 24시간 완료 수(`task_flow.recent.completed`)로 바꾼다 | render.ml |
| 2 | briefing `keeper_briefs` 를 디코드해 Team 패널을 그린다. TUI Session Events 자리를 대신한다 | types/loader/새 모듈 |
| 3 | 14일 완료 막대와 `Done today` 를 Team 머리줄에 싣는다 | 새 모듈 |
| 4 | 런타임 quota 소진·재개 시각과 Keeper 24시간 비용 줄 (`/runtime/resolved`, `/dashboard/keeper-costs`) | http/loader/새 모듈 |
| 5 | `[tui] overview_panels` 로 패널 순서와 on/off 를 TOML 에서 고른다. 모르는 이름은 로드 오류 | config |
| 6 | GitHub PR 동기화 — 서버에 PR 목록 수집기가 없다. 별도 RFC 로 설계한다 | — |

## 4. 트레이드오프

- TUI Session Events 는 기본 화면에서 빠진다. 5번에서 켤 수 있다.
  `RFC-tui-operator-ia` §3.1 은 "Overview 에 남긴다"고 적었다. 이 RFC 가 그 결정을 바꾼다.
  근거: 132×40 실측에서 3줄 모두 TUI 자기 기동 로그였다.
- Team 행은 오른쪽 roster pane(`Changes`)과 Keeper 이름을 같이 쓴다.
  roster 는 도구 호출 단위이고, Team 은 Task 와 막힘 단위다. 묻는 질문이 다르다.
- 계정별 남은 사용량은 provider 가 알려주지 않는다(`server_dashboard_runtime_resolved_json.ml` 주석).
  4번은 "소진됨, 재개 시각" 만 말하고 퍼센트를 지어내지 않는다.
