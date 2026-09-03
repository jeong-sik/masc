---
rfc: "0403"
title: Keeper 별 도구 선택 — 부착 서비스는 provider 단위로만 켜고 끌 수 있다
status: Draft
created: 2026-09-02
updated: 2026-09-03
author: Claude Opus 5 (1M context)
supersedes: []
superseded_by: null
related: ["0363", "0351", "0382"]
---

## 0. 한 줄 요약

Keeper 가 부착 서비스를 하나 붙이면 그 서비스의 도구를 **전부** 받는다. 도구
단위로 고르는 축이 없다. `kidsnote-pr-jira-checker` 는 Confluence 에 한 번도
쓴 적이 없는데 Confluence 쓰기 도구 4종 21.3 KB 를 매 턴 보낸다. Keeper 선언에
정적 허용목록을 추가한다.

## 1. 문제 — 실측 (2026-09-02)

각 Keeper 가 실제로 wire 에 싣는 도구 스키마와, 로그 8일치에서 **한 번도 부르지
않은** 도구의 비중. **미호출 바이트는 이 RFC 가 걷어낼 수 있는 양이 아니다** —
그 안에는 이 축이 건드리지 않는 내장 도구가 섞여 있다. 실제 절감은 §4 를 볼 것:

| keeper | 레인 | 도구 | 스키마 | 미호출 | 미호출 바이트 | 비중 |
|---|---|---|---|---|---|---|
| kidsnote-pr-jira-checker | claude_code | 122 | 140 KB | 84 | **94.4 KB** | **67%** |
| lane-smith | antigravity | 135 | 139 KB | 57 | 48.4 KB | 35% |
| code-reviewer | claude_code | 91 | 89 KB | 26 | 17.5 KB | 20% |
| pr-updater | agent-core | 64 | 66 KB | 43 | 31.6 KB | 48% |
| polisher | agent-core | 65 | 67 KB | 12 | 5.1 KB | 8% |
| sangsu | agent-core | 63 | 63 KB | 11 | 4.7 KB | 7% |
| rondo | agent-core | 69 | 75 KB | 9 | 4.8 KB | 6% |
| analyst | agent-core | 69 | 74 KB | 8 | 3.4 KB | 5% |

측정: `~/.masc/wire-capture/2026-09/02.jsonl` 의 `tools_ref` blob (= `on_the_wire`
가 넘긴 목록) 대 `~/.masc/logs/system_log_*.jsonl` 의 `tool_call tool=` 행.

**주의 — 이름 축이 둘이다.** keeper metrics 의 `tools_used` 는 canonical
(`tool_read_file`), 도구 TOML 과 wire 는 public (`Read`) 이다. 섞으면 `Read`·
`Edit`·`Grep` 이 "한 번도 안 불림" 으로 나온다. 위 표는 전부 public 이름 기준이다.

### 1.1 가장 큰 낭비는 호출 0회짜리다

`kidsnote-pr-jira-checker` 상위 미호출:

| 도구 | 스키마 | `tool_calls` 전체 기록 호출 |
|---|---|---|
| `atlassian_createConfluenceInlineComment` | 6,144 B | **0** |
| `atlassian_updateConfluencePage` | 5,399 B | **0** |
| `atlassian_createConfluencePage` | 5,135 B | **0** |
| `atlassian_createConfluenceFooterComment` | 4,655 B | **0** |

네 개 합 **21.3 KB**. 같은 Keeper 가 31일치 `tool_calls` 전 기록
(2026-08-03 ~ 09-02) 에서 실제로 부른 부착 도구는 다섯 종뿐이고 전부 읽기다:

| 도구 | 호출 |
|---|---|
| `atlassian_searchJiraIssuesUsingJql` | 2,001 |
| `atlassian_getJiraIssue` | 48 |
| `atlassian_getJiraIssueRemoteIssueLinks` | 7 |
| `atlassian_getAccessibleAtlassianResources` | 5 |
| `atlassian_atlassianUserInfo` | 1 |

이 Keeper 는 이름 그대로 checker 이고 Confluence 에 쓰지 않는다.

### 1.2 기존 장치로는 못 막는다

| 장치 | 축 | 왜 안 닿는가 |
|---|---|---|
| `defer_loading` (`config/tools/<name>.toml`) | 도구 단위, **전역** | Keeper 별로 다르게 못 준다. 그리고 부착 도구는 TOML 이 없다 |
| `Keeper_identity_switch` | **provider 단위** | Atlassian 을 끄면 Jira 읽기도 같이 꺼진다 |
| `keeper_tool_search` 지연 목록 | agent-core 레인 전용 | official-client 레인은 `built_tools` 를 통째로 받는다 |
| skills (`skills.names`) | composition 축 | descriptor·부착 도구를 안 자른다 |

`Keeper_identity_tools.for_turn` 이 "every attached provider's tools" 를 준다.
그 사이에 필터가 들어갈 자리가 없다.

## 2. 왜 정적 선택인가 — 동적 로딩은 두 번 거부됐다

| 구현체 | 시도 | 결과 |
|---|---|---|
| OpenClaw #23999 | 턴별 동적 도구 로딩 | **NOT_PLANNED** (2026-04-04) |
| OpenClaw #91820 | 잡별 정적 도구 선택 (`--tools "exec,read,message,cron"`) | **COMPLETED** (2026-06-10) |
| Hermes | 같은 것을 "toolsets" 라 부름 (#91820 이 인용) |  |
| Hermes #16104 | on-demand ToolLoader | 아직 열린 feature request |

OpenClaw 의 실측 근거는 우리와 같은 모양이다: 도구 40개 = 약 26,000 토큰 =
시스템 프롬프트 예산의 95%.

MASC 의 official-client 레인 주석도 같은 지점을 짚는다
(`keeper_tools_agent_core_bundle.ml:552`):

> lanes that cannot widen a running turn ... pin their tool set at process spawn
> or thread start ... so a listing would name tools they can never make callable.

**정적 선택은 이 제약과 부딪히지 않는다.** spawn 때 정하는 값이므로 턴 중간
확장이 필요 없다. `runtime_claude_code.ml:1182` 의 `--allowedTools` 는 이미 명단을
받는 자리이고, 지금은 거기에 전부를 넣고 있을 뿐이다.

### 2.1 세션 재시작 경로는 이 RFC 의 근거가 아니다

`Keeper_official_client_session_store.reconcile_tool_surface` (2026-08-28) 는 도구
표면이 바뀌면 세션을 새로 시작한다. 표면 변경이 영구 고정이 아니라는 뜻이지만,
위 주석은 그보다 **나중인** 2026-08-31 에 들어왔다 — 저자는 그 경로를 알고도
"never" 를 썼다. 따라서 이 RFC 는 동적 확장을 되살리자고 하지 않는다. 정적
선언만 다룬다.

## 3. 설계

### 3.1 선언 위치

Keeper 선언 (`config/keepers/<name>.toml`) 에 허용목록 하나:

```toml
[keeper.tools]
# 생략하면 지금 동작 그대로 — 부착 provider 의 전체 목록.
# 선언하면 그 이름만 남는다. 내장 도구는 이 축이 건드리지 않는다.
attached_allow = [
  "atlassian_searchJiraIssuesUsingJql",
  "atlassian_getJiraIssue",
  "atlassian_getJiraIssueRemoteIssueLinks",
  "atlassian_addCommentToJiraIssue",
]
```

부착 도구만 대상으로 한다. 내장 도구에는 이미 `defer_loading` 이 있고, 두 축이
같은 도구를 두고 다투면 어느 쪽이 이겼는지 읽을 수 없게 된다.

### 3.2 적용 지점

`Keeper_identity_tools.for_turn` 의 결과를 `Keeper_run_tools_setup` 이
`identity_surface.offered` 로 넘기기 전에 한 번 거른다. 필터는 순수 함수이고
집합 연산뿐이다 — 점수·문자열 분류·휴리스틱 없음.

두 레인 모두에 같은 값으로 닿는다:

- official-client: `built_tools` 가 작아지고 `--allowedTools` 와 `--mcp-config`
  가 같이 좁아진다.
- agent-core: `deferred` 목록이 작아진다. `keeper_tool_search` 의 한 줄짜리
  항목도 함께 줄어든다.

### 3.3 선언에 없는 이름

**보고하되 턴을 막지 않는다.** 필터는 `unnamed` 를 함께 돌려주고, 호출부가
`keeper_attached_tool_allow_unnamed` 로 WARN 을 낸다.

초안은 부팅 시 typed 거부였다. 바꾼 이유는 두 가지다. 부착 카탈로그는
`Keeper_identity_tools.for_turn` 이 턴마다 디스크에서 읽는 것이라 부팅 시점에
확인할 대상이 아직 없다. 그리고 provider 를 꺼두면 그 이름은 정당하게 사라지는데
(`Keeper_identity_switch`), 그걸 부팅 실패로 만들면 스위치를 끄는 순간 keeper 가
안 뜬다.

같은 파일의 형제 개념이 이미 이 모양이다 — `offering.unusable` 은 provider 가
이름을 댔지만 제공할 수 없는 도구를 담고, 호출부가
`keeper_identity_tool_unusable` WARN 을 낸다. `unnamed` 는 그 거울상이다:
선언이 요구했지만 어느 provider 도 내놓지 않은 이름.

조용히 무시하지 않는다는 초안의 요구는 그대로다. 바뀐 것은 어디서 보고하느냐다.

### 3.4 안 하는 것

- 사용 이력으로 목록을 자동 생성 — "써본 적 없으면 못 쓴다" 는 Keeper 를
  얼린다. 선언은 운영자가 쓴다.
- 턴별 동적 로딩 — §2 에서 두 번 거부된 방향.
- 내장 도구 선택 — `defer_loading` 의 축이다.
- 부착 도구의 스키마 축약 — 별건.

## 4. 검증

### 4.1 실측한 절감 — `kidsnote-pr-jira-checker`

라이브 wire 목록(`tools_ref` blob)에 31일치 호출 기록으로 만든 허용목록을
적용해 계산했다. 배포 전이라 라이브 선언은 넣지 않았다.

| | 도구 | 바이트 |
|---|---|---|
| 현재 wire | 122 | 135,500 |
| 내장 — **이 축이 건드리지 않음** | 91 | 84,010 |
| 부착 | 31 | 51,490 |
| 부착 중 실제 호출됨 (허용목록) | 5 | 4,500 |
| **부착 중 제거 가능** | **26** | **46,990** |
| 적용 후 wire | 96 | 88,510 |

**절감 46,990 B, 35%.**

§1 표의 "미호출 94.4 KB" 는 이 축의 절감량이 아니다. 그 수치는 내장과 부착을
합친 미호출이고, 내장 도구는 `defer_loading` 의 축이라 여기서 안 빠진다.
초안이 둘을 섞어 적었다.

### 4.2 목표

| 지표 | 현재 | 목표 |
|---|---|---|
| `kidsnote-pr-jira-checker` 부착 도구 / 바이트 | 31 / 51,490 | 선언한 수 / 그만큼 |
| 선언 밖 부착 도구 | 26 · 46,990 B | 0 |
| 선언 없는 Keeper | — | **바이트 변화 0** |

필수 회귀 테스트:

1. **선언 없으면 무변화** — 목록이 지금과 바이트 단위로 같다.
2. **선언하면 그 집합** — 부착 도구가 정확히 선언된 이름들이고, 내장 도구는
   영향받지 않는다.
3. **없는 이름은 보고** — `unnamed` 에 그 이름이 담기고 kept 에는 없다.
4. **두 레인 동일** — 같은 선언에 대해 official-client 의 `--allowedTools` 와
   agent-core 의 `deferred` 가 같은 집합을 본다.
5. **provider off 와 구분** — 꺼진 provider 의 이름은 거부가 아니다.

## 5. 리스크

| 리스크 | 완화 |
|---|---|
| 필요한 도구를 빠뜨려 Keeper 가 막힘 | 선언은 opt-in. 미선언이 기본이고 지금 동작 그대로 |
| 선언이 provider 카탈로그 변경과 어긋남 | §3.3 `unnamed` WARN. 턴은 계속 돈다 |
| 두 축(`defer_loading`) 과 겹침 | §3.1 부착 도구만 대상 |
| 운영자가 목록을 유지해야 함 | 실측 표(§1)를 만드는 스크립트를 같이 낸다 |

## 6. 이 RFC 가 풀지 않는 것

- `tool_schemas` 는 캐시가 있는 provider 에서 사실상 공짜다. 이 레인의 캐시
  히트가 0% 인 것은 RFC-0382 §0.4 의 배치 문제이고 그쪽이 근본이다.
- agent-core 레인의 미호출(pr-updater 43개 / 31.6 KB)은 지연이 이미 도는데도
  남은 몫이다. 그 튜닝은 호출 수가 아니라 **필요했던 턴 수**로 판단해야 한다
  (masc #32062 실측).
