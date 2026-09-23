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

`RFC-tui-operator-ia` 의 "Overview 개편"(§3.1 끝 항목, §4 표의 J 행)을 실행한다.
Overview 한 화면이 세 질문에 답한다.

1. **누가 무엇을 하고 있나** — Keeper 한 명당 한 줄. 상태, 맡은 Task, 마지막 턴 나이.
2. **무엇이 막혔나** — 막힌 Keeper 는 원인 문장과 함께 Team 맨 위에 모인다.
3. **얼마나 끝냈나** — 최근 24시간 완료 수와 14일 완료 막대.

새 서버 API 는 만들지 않는다. 필요한 값은 이미 TUI 가 받고 있다.

## 1. 기준선 (2026-09-23, main `0936c2bb97`, 132×40 실측)

| 자리 | 지금 화면 | 문제 |
|---|---|---|
| Tasks 머리줄 | `687 · 0 done · 17 active · 8 awaiting · 662 todo` | `state.tasks` 는 끝난 Task 를 담지 않는다. `0 done` 은 항상 0 이다 |
| Tasks 목록 | todo 가 대부분인 23줄 | 지금 일하는 17개·검증 대기 8개가 Goal 묶음 사이에 흩어진다 |
| Attention | 7줄이 같은 문장 `turn failed N cycle(s); inspect the last runtime error` | 원인이 없다. 132열에서는 `runtime…` 에서 잘린다 |
| briefing `keeper_briefs` | 16행을 받아 `status` 단어로 상태별 개수만 센다 (`keeper_liveness_of_briefs`) | 행마다 있는 phase, last_turn_ago_s, context_ratio 가 화면에 오지 않는다 |
| `keeper_briefs[].health` | 16행 모두 `null` | 서버가 `diagnostic.health_state` 를 읽는데 그 키가 없다. 별도 PR 로 고친다 |
| `keeper_briefs[].current_work` | 16행 모두 `null` (진행 중 Task 17개) | Keeper 의 `current_task_id` 가 비어 있다. Team 은 Task 의 assignee 로 일을 찾는다 |
| `state.task_flow` | Metrics 화면에 숫자 격자로만 | 14일 추이를 그리는 곳이 없다 |

Attention 원인 누락도 서버 문제다. 부팅할 때 저장된 실패 횟수만 되살리고 원인은 버린다.
별도 PR 에서 고친다. Team 은 서버가 보낸 문장을 그대로 싣는다.

## 2. 화면

Attention / TUI Session Events 띠와 Tasks 사이에 전체 폭 Team 섹션을 넣는다.

```
 Team  6 working · 5 need you · 1 idle · 4 parked
  ! tui-developer    failing   8m  Keeper turn failed 2 consecutive cycle(s); …
  ● glossary-maniac  running   1m  [task-1519] 최근 5일 일자별 diff 전수 리뷰   +1 · 2 awaiting
  · geek-scout       running   8m  no open task
  ○ parked: lane-smith, rondo, rust-hwp-guy, sangsu
```

- **무리(닫힌 합타입)**: `Needs_you`(Failing·Crashed, 또는 paused 가 아닌데 phase 가 없는 offline)
  → `Working`(Running 이고 맡은 열린 Task 가 있음) → `Idle`(그 밖의 살아 있는 phase)
  → `Parked`(Paused·Stopped·Offline). 같은 무리 안은 이름순이다. 점수나 가중치로 정렬하지 않는다.
- **막힌 행의 설명**: Attention 항목 중 `target_type = keeper` 이고 `target_id` 가 그 Keeper 인
  첫 항목의 summary 다. 없으면 phase 단어만 쓴다. TUI 가 원인을 추측하거나 문장을 해석하지 않는다.
- **일하는 행의 설명**: 그 Keeper 가 assignee 인 Claimed/InProgress Task 중 목록 순서상 첫 Task.
  더 있으면 `+N`, 검증 대기 Task 는 `N awaiting` 으로 붙인다.
- **Parked**: 한 줄에 이름만 모은다. 운영자가 멈춘 Keeper 는 매 턴 읽을 필요가 없다.
- 행 예산: Attention 패널 → Tasks 1줄 선점 → Team(제목 + 행 + 구분선) → 남는 줄은 Tasks.

Tasks 목록의 순서는 바꾸지 않는다. 순서는 `Tui_decode.active_tasks_of_domain` 이 정하고
커서가 같이 쓴다. `RFC-tui-operator-ia` 는 Task 목록을 Planning 으로 옮기자고 했지만,
Overview 의 Task 커서·상세 흐름을 옮기는 건 이 RFC 범위 밖이다. 목록은 남긴다.

## 3. 스택

| # | 내용 | 파일 |
|---|---|---|
| 1 | Tasks 머리줄의 늘 0 인 `done` 을 24시간 완료 수(`task_flow.recent.completed`)로 바꾼다 | render.ml |
| 2 | briefing `keeper_briefs` 를 행으로 디코드하고 Team 섹션을 그린다 | types/loader/schedule/새 모듈 |
| 3 | 14일 완료 막대(`task_flow.daily`)를 Team 제목 줄 오른쪽에 싣는다 | 새 모듈 |
| 4 | 닫힌 quota 창과 재개 시각을 Team 첫 줄에 (`/runtime/resolved`). 비용은 뺀다 — keeper-costs 가 모르는 비용을 0 으로 합친다(#38083) | types/masc_tui/render |
| 5 | `[tui] overview_panels` 로 섹션 순서와 on/off 를 TOML 에서 고른다. 모르는 이름은 로드 오류 | config |
| 6 | GitHub PR 동기화 — 서버에 PR 목록 수집기가 없다. 별도 RFC 로 설계한다 | — |

## 4. 트레이드오프

- TUI Session Events 는 그대로 둔다. `RFC-tui-operator-ia` 의 결정과 같다.
  132×40 실측에서 3줄 모두 TUI 기동 로그였으므로 5번에서 끌 수 있게 한다.
- Team 행은 오른쪽 roster pane(`Changes`)과 Keeper 이름을 같이 쓴다.
  roster 는 도구 호출 단위이고, Team 은 Task 와 막힘 단위다. 묻는 질문이 다르다.
- `done 24h` 는 지금부터 24시간 전까지다. 달력의 "오늘"이 아니다. 달력 날짜는 14일 막대가 말한다.
- 계정별 남은 사용량은 provider 가 알려주지 않는다(`server_dashboard_runtime_resolved_json.ml` 주석).
  4번은 "소진됨, 재개 시각" 만 말하고 퍼센트를 지어내지 않는다.
