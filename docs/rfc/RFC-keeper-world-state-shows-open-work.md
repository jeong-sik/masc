---
rfc: "keeper-world-state-shows-open-work"
title: "Keeper 의 World State 에 열린 PR 과 할 일을 제목과 함께 보여 준다"
status: Draft
created: 2026-09-27
updated: 2026-09-27
author: dancer + claude
supersedes: []
superseded_by: null
related: ["0465", "keeper-github-apps", "0385", "0462", "connector-ambient-attention-wake", "prompts-and-tool-definitions-outside-ocaml"]
implementation_prs: []
---

# RFC: Keeper 는 World State 에서 열린 일을 본다

## 0. 요약

Keeper 는 자주 깨어난다. 그런데 깨어나서 받는 화면(World State)에 PR 이 한 줄도 없다.
Task 목록은 제목 없는 id 10개이고, 한 달 가까이 된 것부터 나온다.
Goal 은 Task 를 쥔 Keeper 에게만 보인다.
그래서 턴 대부분이 "내 몫 없음"으로 끝나고, 빨간 CI 와 리뷰를 기다리는 PR 은 그대로 남는다.

이 RFC 가 정하는 것:

1. **World State 에 `Pull_requests` 절을 더한다.** 손이 필요한 PR 을 네 묶음(CI 실패, 변경 요청, 충돌,
   초록인데 현재 head 에 리뷰 없음)으로 보여 주고, 묶음마다 상한을 둔다(§4).
2. **원천은 이미 도는 서버 PR 스냅숏(RFC-0465)이다.** webhook 이나 queue-ledger 를 새 원천으로 쓰지 않는다(§3).
3. **GitHub 변화로 깨우는 것은 그 PR 을 쓴 Keeper 한 명뿐이고, 마지막 단계에서 측정 뒤에 정한다(§5).**
4. **Task 행에 제목을 싣고, 순서를 "진행 중인 Goal 에 이어진 것 → 우선순위 → 최근 것"으로 바꾼다.**
   auto-claim 도 같은 순서를 쓴다. 진행 중인 Goal 은 Task 가 없는 Keeper 에게도 보인다(§6).
5. **옛 표시 방식과 쓰이지 않는 variant 를 지운다(§7).**

모두 투영이다. 배정도, 게이트도, 예약 규칙도 아니다. 무엇을 할지는 Keeper 가 고른다.

## 1. 지금 모습

코드 줄 번호는 `origin/main` `b34ab545d1` 기준이다.
측정값은 2026-09-26~27 운영자 런타임(`<base-path>/.masc`)의 로그·원장·턴 기록을 읽은 조사에서 왔다.
공개 저장소라 원본 로그는 싣지 않는다.

### 1.1 Keeper 는 자주 깨지만 PR 을 모른다

| 항목 | 값 | 근거 |
|---|---|---|
| 자율 턴 주기 | 라이브 600초 (기본 300초) | [사실] `lib/config/env_config_keeper.ml:553-554`, 라이브 `runtime_params.json` `keeper.keepalive_interval_sec` |
| 하루 턴 시도 | 5,529회. 깨운 이유: Board 47%, keepalive 26%, 자기 예약 15% | [사실] 09-26 system log `keeper cycle` 줄 |
| GitHub 때문에 깬 턴 | 0회 | [사실] `turn_reason` 에 GitHub variant 가 없다. `lib/keeper_contract/keeper_world_observation_turn_types.ml:64-81` |
| World State 의 PR 정보 | 없음 | [사실] `lib/keeper/keeper_unified_prompt.ml:1607-2082` 의 `text_of` 와 `lib/keeper/keeper_context_layers.mli:15-36` 의 `layer_id` 에 PR 절이 없다 |
| GitHub 이벤트 유입 | 없음 | [사실] `Surface_ref.Webhook` 은 decoder(`lib/keeper/surface_ref.ml:110`)에서만 만들어진다. lib·bin 어디에도 `x-github-event` 처리가 없다 |
| 도구 0회로 끝난 턴 | 완료 턴의 28%, keepalive 턴의 42% | [사실] 도구 호출 원장과 턴 이음 |
| 리뷰 요청이 가는 곳 | 공유 계정 둘. pangyo-preachers(Keeper 7명), anyang-keepers(Keeper 12명) | [사실] 각 Keeper 의 `github-cli/hosts.yml` `user` |
| 초록·Ready·REVIEW_REQUIRED 인데 Keeper 리뷰·댓글 0 | 45건 중 10건 | [사실] GitHub API 대조 |
| CI 빨강·충돌 PR 에 Keeper 가 고친 커밋 | CI 빨강 12건, 충돌 6건 모두 0 | [사실] 09-26 23:49Z GraphQL |
| Keeper 들이 부른 `gh` 조회 (하루) | `pr view` 2,394, `pr checks` 412, `pr list` 245 | [사실, 근사 정규식 집계] Execute 입력 |

Keeper 가 턴 끝에 남긴 말에도 같은 모양이 보인다.
"새 신호 없음, 대기 유지." "제게 온 메시지, 새 Board 이벤트, 맡은 Task, 열린 질문이 모두 없습니다."
공통 프롬프트는 "맡은 일이 없으면 자기 역할에서 쓸모 있는 일을 찾되, 누가 이미 하고 있는지 먼저 본다"고 한다
(`config/prompts/keeper.md:15`). 그런데 World State 에는 찾을 일도, 누가 하는지도 없다.

### 1.2 Task 목록은 id 만, 오래된 것부터

- [사실] 행은 `{"task_id":"task-603"}` 처럼 id 만 나온다(`lib/keeper/keeper_unified_prompt.ml:1769-1777`).
- [사실] 오래된 순 7개와 최신 3개, 모두 10개다(`:1200-1203`, `:1799-1818`).
  최신 3개의 머리말 `"  Newly added (most recent):\n"` 은 OCaml 안에 박힌 영어 문장이다(`:1817`).
- [사실] 순서는 우선순위 → `created_at` 오름차순 → id 다(`lib/keeper/keeper_world_observation_inputs.ml:214-226`).
  auto-claim(`keeper_task_claim` 을 task_id 없이 부를 때, `lib/keeper/keeper_tool_task_runtime.ml:781`)이
  쓰는 `Workspace.claim_next_r`(`lib/workspace/workspace_task_schedule.ml:145`)와 같은 순서다.
  "읽는 첫 행이 auto-claim 이 잡을 첫 행"이 되게 맞춘 것이다(#29101).
- [사실] 라이브 todo 595개. 나이 중앙값 28일. 모든 Keeper 가 "Claimable tasks for this keeper: 596" 근처 값을 본다.
- [사실] 하루 `keeper_tasks_list` 1,331회, 새로 잡은 claim 26회.
- [사실] 모든 keepalive 턴(2,290회)에 `task_backlog` 사유가 붙었다. claimable 이 0 보다 크면 붙는다
  (`lib/keeper/keeper_world_observation.ml:1789-1806`). 이 사유는 턴을 열지 말지를 바꾸지 않는다.
  `Periodic_tick` 에서 턴을 여는 조건에 backlog 는 들어가지 않고, 사유 목록에만 붙는다(`:1769-1821`).

### 1.3 Goal 은 Task 를 쥔 Keeper 에게만

- [사실] Active Goals 는 이번 턴의 Task 에 이어진 Goal 만 보여 준다.
  "a turn with no task carries no Goals here" (`lib/keeper/keeper_unified_prompt.ml:1290-1336`).
- [사실] 라이브 executing Goal 9개. 그중 Task 없이 깬 Keeper 의 화면에는 0개다.
- [사실] executing Goal 에 이어진 todo 는 12개다(`tasks/goal_task_links.json`).

### 1.4 이미 있는 것 — 서버 PR 스냅숏(RFC-0465)

- [사실] `Server_repository_pulls` 가 등록 저장소의 열린 PR 을 60초마다 GraphQL 로 읽는다
  (`lib/server/server_repository_pulls.ml:777-800`, 시작은 `lib/server/server_bootstrap_maintenance.ml:544`).
- [사실] 자격은 runtime.toml `[repositories] pr_reader` 가 가리키는 Keeper 의 토큰이다. 라이브는 `pr-updater` 다.
- [사실] 결과는 메모리(`Atomic`)에만 있다. 재시작하면 `Pulls_not_read` 부터 다시 읽는다.
- [사실] 실패는 닫힌 타입이다. `Rate_limited { reset_at }`, `Token_rejected`, `Repository_not_visible` 등이 있고,
  빈 목록으로 접히지 않는다(`lib/server/server_repository_pulls.mli:55-81`).
- [사실] 지금 이 스냅숏을 읽는 곳은 HTTP 두 곳(`GET /api/v1/repositories/pulls`)과 TUI 뿐이다.
  열린 PR #38801 은 TUI 쪽 PR 표시를 걷어내면서 RFC-0465 머리에
  "서버의 PR 조회 API와 Keeper 귀속 규칙은 별도 기능으로 남는다"고 적는다.
- [사실] 라이브 스냅숏(2026-09-27 00:20:58Z, masc): 열린 PR 91개, checks failing 11, changes_requested 13,
  draft 16, 커밋 author 가 Keeper 이름과 같은 PR 8개.

### 1.5 다루지 않는 것 — 기억 recall 비중

프롬프트의 74~96% 가 Memory OS recall 이다. recall 은 자르지도 순위를 매기지도 않는다
(`lib/keeper/keeper_memory_os_recall.mli:6`). 턴마다 먼저 읽는 글이 지금의 기회보다 과거의 보류 기록이 되는 문제다.
이 RFC 는 World State 에 없는 입력을 채운다. recall 설계는 다루지 않는다.
다만 §9 의 측정에서 World State 가 늘어난 바이트를 같이 적어, 두 문제의 크기를 비교할 수 있게 한다.

## 2. 원칙

1. **투영이다.** World State 는 사실을 보여 준다. Keeper 를 배정하지 않고, 턴을 막지 않고, 예약을 만들지 않는다.
2. **닫힌 타입으로 나눈다.** PR 의 묶음, 행의 순서, 깨울 변화는 모두 variant 와 타입 있는 칸으로 정한다.
   제목·본문·판정 댓글의 글자를 읽어 분류하지 않는다.
3. **사실은 한 곳에 있다.** PR 의 원본은 GitHub 이고, 서버 스냅숏은 메모리 투영이다.
   World State 와 도구는 그 스냅숏을 읽기만 한다. 파생 값을 권위 있는 저장소로 다시 쓰지 않는다.
4. **모르는 것은 모른다고 쓴다.** 못 읽은 저장소, 아직 안 읽은 저장소, GitHub 이 계산하지 않은 충돌 여부를
   빈 목록이나 "문제 없음"으로 그리지 않는다(RFC-0462).
5. **문구는 `config/prompts` 에 둔다.** 새 절의 모든 문장은 `config/prompts/keeper.md` 의 `### world.*` 조각이다
   (RFC prompts-and-tool-definitions-outside-ocaml).

## 3. 원천 — 서버 PR 스냅숏을 넓혀 쓴다

### 3.1 세 후보

| 후보 | 좋은 점 | 나쁜 점 | 판단 |
|---|---|---|---|
| A. GitHub webhook → connector attention → `turn_reason` | 변화가 몇 초 안에 온다 | 저장소 설정에 webhook 을 걸 관리자 권한과 서명 비밀이 필요하다. 서버가 꺼져 있을 때 온 전달은 GitHub 이 자동으로 다시 보내지 않는다. 그래서 상태를 맞추려면 어차피 목록을 읽어야 한다. 밖에서 들어오는 입력 경로가 하나 늘어난다 | 쓰지 않는다 |
| B. 서버가 주기적으로 읽은 스냅숏 (RFC-0465 의 읽기) | 이미 라이브에서 돈다. 실패가 닫힌 타입이다. 읽는 계정이 하나라 rate limit 을 한 곳에서 다룬다 | 최대 60초 늦다 | **쓴다** |
| C. `scripts/review/queue-ledger.sh` 재사용 | R1 병합 조건별로 "누구의 결정을 기다리나"를 한 줄로 낸다 | bash 스크립트이고 저장소 clone(`--git-dir`)이 필요하다. 리더가 Board 에 정한 R1 규칙을 코드로 옮긴 것이라, 런타임 사실로 넣으면 운영 규칙이 런타임에 박힌다. verdict 줄을 글자로 읽는다(`queue-ledger.sh:17-27`) | 원천으로 쓰지 않는다. Keeper 가 도구로 돌리는 것은 그대로 둔다 |

B 의 60초 지연은 문제가 아니다. [사실] Keeper 의 자율 턴 주기가 600초이고, PR 의 CI 는 15~20분 걸린다.

Lane add-on(`Lane_addon_subscription`, `docs/design/lane-addon-v0.md`)으로 넣는 방법도 봤다.
Lane add-on 은 기계 lane 의 사건을 구독하는 틀이다. PR 은 lane 이 아니라 저장소의 사실이라 그 틀에 끼우면 겉감싸기만 하나 더 생긴다.
쓰지 않는다.

### 3.2 더 읽을 칸

[사실] 지금 쿼리는 PR 마다 `number isDraft reviewDecision mergeable`, head 의 `statusCheckRollup.state`,
최근 10커밋의 부모 수와 author 이름을 읽는다(`lib/server/server_repository_pulls.ml:227-238`).

[제안] 아래를 더한다.

| 칸 | 쓰는 곳 |
|---|---|
| `title`, `createdAt`, `baseRefName`, `headRefOid`, `author { login }` | 행 내용, 스택 PR 표시, "작성자 말고 누가 손댔나" |
| head 커밋의 `oid`, `committedDate` | head 가 얼마나 오래됐나, "현재 head 이후 손댔나" |
| `statusCheckRollup.contexts(first: 30)` 의 CheckRun `name conclusion status`, StatusContext `context state` | 실패한 check 이름 |
| `reviewRequests(first: 10)` 의 `requestedReviewer` login | GitHub 이 누구의 리뷰를 기다리나 |
| `latestReviews(first: 10)` 의 `author { __typename login } state submittedAt commit { oid }` | 사람별 마지막 리뷰와 그 리뷰가 현재 head 에 달렸는지 |
| `comments(last: 5)` 의 `author { __typename login } createdAt` | 현재 head 이후의 댓글 |

`latestOpinionatedReviews` 는 쓰지 않는다. [사실] 00:27Z 조회에서 이 칸에는 CHANGES_REQUESTED 15건만 있었다.
Keeper 판정은 COMMENTED 리뷰(같은 시각 `latestReviews` 에 34건)와 댓글로 많이 달리므로 이 칸으로는 놓친다.

GitHub 이 모르는 값을 보내면 그 행은 기존처럼 `undecodable` 로 센다. 다른 값으로 접지 않는다.

**비용** [사실, `rateLimit { cost }`, 2026-09-27 00:2xZ, jeong-sik/masc 열린 PR 89개 한 페이지]

| 쿼리 | cost |
|---|---|
| 지금 쿼리 | 2 |
| 위 칸을 모두 더한 쿼리 | 6 |

GitHub 공식 문서(2026-09-27 확인,
[Rate limits and query limits for the GraphQL API](https://docs.github.com/en/graphql/overview/rate-limits-and-query-limits-for-the-graphql-api)):
사용자 토큰은 시간당 5,000점, GraphQL 은 분당 2,000점, 동시 요청 100개가 secondary 상한이다.
쿼리 하나의 최소 비용은 1점이다.

[제안, 추정] 저장소 3개를 60초마다 읽으면 masc 6점 + 나머지 둘 각 1점 이상 → 시간당 약 480점, 5,000점의 약 10% 다.
figma-mcp·wkbl 의 실제 cost 는 재지 않았다.

### 3.3 producer → store → consumer → caller

| 단계 | 무엇 | 위치 |
|---|---|---|
| producer | 60초마다 GraphQL 로 읽는 fiber | [사실] `Server_repository_pulls.start` → `refresh` (`lib/server/server_repository_pulls.ml:582`, `:779`) |
| store | 메모리 투영. 재시작하면 비어 있다 | [사실] 같은 파일의 `projection` (`Atomic`). [제안] 타입과 `current ()` 를 `lib/repository_pulls/` 의 새 모듈 `Repository_pulls` 로 옮긴다. 읽기 fiber 와 자격 처리는 `lib/server` 에 남는다 |
| consumer 1 | World State `Pull_requests` 절 | [제안] `Keeper_context_layers.layer_id` 에 variant 추가, `keeper_unified_prompt.ml` 의 `text_of`·`content_of` 에 arm 추가 |
| consumer 2 | 전체 목록 도구 `keeper_pull_requests_list` | [제안] §4.7 |
| consumer 3 | 기존 HTTP `GET /api/v1/repositories/pulls` | [사실] `lib/server/server_routes_http_routes_repositories.ml:527`. JSON 모양은 새 칸만 더한다 |
| caller | 턴을 조립하는 곳 | [제안] `lib/keeper/keeper_unified_turn.ml:750-805` 가 `repository_freshness`·`lane_updates` 와 같은 자리에서 스냅숏을 읽어 `Keeper_unified_prompt.build_prompt` 에 넘긴다. 대시보드 미리보기(`lib/dashboard/dashboard_http_keeper_snapshot.ml:204`)도 같은 값을 넘긴다 |

모듈을 옮기는 이유: [사실] `lib/keeper` 는 지금 `lib/server/` 아래 모듈을 부르지 않는다.
`Server_` 로 시작하는 이름을 실제로 부르는 곳은 `lib/` 최상위의 `Server_startup_state` 하나다
(`lib/keeper/keeper_tool_surface_ops.ml:140-141`). 나머지 `rg "Server_[a-z_]+\." lib/keeper` 결과는 주석이다.
World State 가 `lib/server/server_repository_pulls.ml` 을 직접 부르면 이 방향이 처음으로 뒤집힌다.
옛 이름을 가리키는 별칭은 두지 않는다. 겉감싸기 위에 겉감싸기를 만들지 않는다.

### 3.4 인증과 rate limit

- [사실] 읽는 자격은 지금 그대로다. `pr_reader` Keeper 의 `hosts.yml` 토큰을 읽을 때마다 새로 읽는다.
  읽는 계정이 쓸 수 없으면 다른 자격으로 대신 읽지 않는다(`server_repository_pulls.mli:1-14`).
- [사실] 403·429 의 `retry-after`, `x-ratelimit-reset` 을 따르고, 기다리는 동안 요청하지 않는다
  (`Rate_limited`, `server_repository_pulls.mli:65-74`). 공유 계정이 secondary limit 에 걸려도 이 경로가 받는다.
- [사실] 라이브 `pr_reader` 는 pr-updater, 곧 anyang-keepers 계정이다. 같은 계정을 Keeper 12명이 `gh` 로 같이 쓴다.
- [제안] World State 와 새 도구는 GitHub 을 부르지 않고 스냅숏만 읽는다.
  Keeper 가 매 턴 `gh pr view`·`gh pr list` 로 확인하던 일 일부를 스냅숏 읽기로 바꿀 수 있다.
  줄어드는지는 §9 에서 잰다. 줄어든다고 미리 단정하지 않는다.
- [제안] 읽는 계정을 anyang-keepers 가 아닌 곳으로 옮길지는 운영자 결정이다(D6).

### 3.5 오래됨 표시

저장소마다 한 줄로 상태를 먼저 쓴다. 행이 있든 없든 쓴다.

| 스냅숏 상태 | World State 에 쓰는 것 |
|---|---|
| `Pulls_read { observed_at }` | 읽은 시각(UTC)과 몇 초 전인지 |
| `Pulls_failed { observed_at; failure }` | 못 읽은 이유와 시각. `Rate_limited` 는 GitHub 이 준 다시 읽을 시각. 행은 그리지 않는다 |
| `Pulls_not_read` | 서버가 뜬 뒤 아직 읽지 않음 |
| `Pulls_not_github` | 그리지 않는다. GitHub 저장소가 아니다 |
| `reader` 가 `Reader_ready` 가 아님 | 이유 한 줄(선언 없음, Keeper 없음, 토큰 없음) |
| `repositories_error = Some _` | 행이 지난 읽기의 것이라는 문장과 이유 |

"몇 초 넘으면 오래됐다" 같은 기준은 두지 않는다. 시각만 보여 주고 판단은 Keeper 가 한다.

## 4. World State 의 `Pull_requests` 절

### 4.1 누구에게 보이나

[제안] 두 가지를 합친다.

1. **자기 PR.** PR 의 가장 최근 부모 하나짜리 커밋 author 이름이 이 Keeper 이름과 정확히 같으면
   (`Server_repository_pulls.keeper_of_author`, RFC-0465 §2.1) 그 PR 은 이 Keeper 에게 늘 보인다.
   [사실] 런타임이 Keeper 도구 프로세스에 `GIT_AUTHOR_NAME`·`GIT_COMMITTER_NAME` 을 Keeper 이름으로 넣는다
   (`lib/exec_ssh_protocol/exec_ssh_protocol.ml:103`).
2. **저장소의 묶음 행.** `repositories.toml` 의 저장소 `keepers` 목록에 든 Keeper 에게만 보인다.
   - [사실] 이 칸은 이미 있다(`lib/repo_manager/repo_manager_types.mli:29`). TUI 는 "Which keepers work in it" 으로 보여 준다
     (`lib/tui_decode.mli:969`). 런타임에서 읽는 곳은 아직 없다.
   - [사실] 라이브 masc 행은 `keepers = []` 다. wkbl 행은 지금 없는 Keeper 이름 넷을 적고 있다.
   - 빈 목록은 "아무에게도 안 보임"이다. "모두에게 보임"으로 넓히지 않는다. 운영자가 목록을 채워야 보인다(D1).

검토했지만 고르지 않은 기준:

| 기준 | 고르지 않은 이유 |
|---|---|
| 모든 Keeper | [사실] GitHub 자격이 없는 Keeper 가 넷이다(geek-scout, msx-retro-mania, rust-hwp-guy, won-chik). 행동할 수 없는 목록을 매 턴 싣는다 |
| `board_interests` | 관심사 문자열과 PR 제목·파일을 맞춰 보는 것은 글자 분류다 |
| GitHub 자격 유무 | 로그인 확인이 `gh api user` 호출이다(`lib/keeper/keeper_github_identity.ml:967`). 턴마다 부를 수 없다. 자격이 있다는 것도 그 저장소에서 일한다는 뜻은 아니다 |

### 4.2 무엇을 보이나

[제안] 묶음은 닫힌 타입이다. PR 하나는 아래 순서로 처음 맞는 묶음 하나에만 든다.

```ocaml
type attention =
  | Checks_failing            (* head 의 statusCheckRollup 이 FAILURE 또는 ERROR *)
  | Changes_requested         (* reviewDecision = CHANGES_REQUESTED *)
  | Conflicting               (* mergeable = CONFLICTING. UNKNOWN 은 여기 넣지 않는다 *)
  | Unreviewed_on_head        (* checks 초록, REVIEW_REQUIRED, 현재 head 에 사람 리뷰 없음 *)

type placement =
  | Needs of attention
  | Not_listed of not_listed  (* 행은 없고 수만 센다 *)
and not_listed =
  | Draft
  | Checks_running
  | Reviewed_on_head          (* 현재 head 에 사람 리뷰가 있고 위 묶음에 들지 않음 *)
  | Mergeability_unknown_only (* 충돌 여부만 모르고 다른 묶음에 들지 않음 *)
```

`placement` 는 PR 의 타입 있는 칸만 보고 정하는 전체 함수다. `_ ->` 로 남은 경우를 한데 묶지 않는다.

**저장소 머리 줄** (행 수와 상관없이 늘 나온다):
읽은 시각, 열린 PR 수, 묶음별 수, draft 수, 충돌 여부를 GitHub 이 아직 계산하지 않은 PR 수.

충돌 여부 수를 따로 세는 이유: [사실] 00:20:58Z 서버 스냅숏에서 91개 중 80개가 `unknown` 이었고,
7분 뒤 직접 조회에서는 89개 중 0개였다. GitHub 이 목록 조회 때 충돌을 늦게 계산한다.
원인은 확인하지 못했다(§13). 그래서 `Conflicting` 묶음은 GitHub 이 CONFLICTING 이라고 말한 PR 만 담고,
나머지는 "모름" 수로 보여 준다.

**행** (한 줄, 폭이 정해져 있다):

| 칸 | 값 |
|---|---|
| 번호·묶음 | `#39401 checks_failing` |
| 실패 check | 이름 두 개까지. 그 이상은 수 |
| 제목 | `Keeper_types_profile.short_preview ~max_len:80` (기존 Board 행과 같은 자르기) |
| 작성자 | PR `author.login` |
| base | `main` 이 아니면 base 이름(스택 PR) |
| head 나이 | head 커밋 이후 흐른 시간 |
| 손댄 사람 | §4.5 |
| 리뷰 요청 | `reviewRequests` 의 login |
| 자기 PR 표시 | 이 Keeper 가 커밋 author 면 `yours` |

**자기 PR 중 묶음에 들지 않는 것**은 한 줄에 번호만 늘어놓는다(예: `#39410 (draft) #39422 (checks running)`).

### 4.3 순서

[제안] 묶음 순서는 위 `attention` 선언 순서다.
같은 모양의 선례가 있다. Repository freshness 는 `Diverged → Behind → Ahead → Current` 순서를 variant 로 정한다
(`lib/keeper/keeper_unified_prompt.ml:1886-1892`).

묶음 안의 순서는 타입 있는 칸으로만 정한 사전식 순서다. 가중치나 점수를 더하지 않는다.

1. 이 Keeper 의 PR 먼저.
2. **현재 head 이후 아무도 손대지 않은 PR 먼저.** "손댐"은 PR 작성자가 아닌 `User` 계정이
   현재 head 에 리뷰를 달았거나, head 커밋 시각 뒤에 댓글을 단 것이다. `Bot` 계정(`author.__typename`)은 세지 않는다.
3. head 커밋이 오래된 것 먼저.

[사실] 00:35Z 조회에서 묶음에 든 57건 중 45건이 2번 조건의 "아무도 손대지 않음"이었다
(failing 5/8, changes_requested 7/10, conflicting 2/2, unreviewed_on_head 31/37).
빨간 CI·리뷰 없는 PR 이 방치되는 문제(§1.1)가 바로 이 행들이다.

Task 목록과 달리 여기서는 오래된 것이 먼저다. [사실] 열린 PR 은 병합·종료로 계속 빠진다(48시간 병합 389건).
오래 열린 PR 은 버려진 것이 아니라 기다리는 것이다.

### 4.4 한도

[사실] 00:27Z 스냅숏으로 모든 묶음 행을 그리면 68행, 평균 187바이트, 합계 약 12.8KB 다.
지금 World State 전체가 Keeper 별 중앙값 11~22KB 다. 열린 PR 수가 늘면 같이 늘어난다.

[제안]

- 묶음마다 행 상한 `pull_request_rows_per_attention` 을 둔다. 기본 5 를 제안한다(D3).
  네 묶음 × 5행 × 약 190바이트 ≈ 3.8KB 다. 넘치는 수는 "N more — keeper_pull_requests_list" 한 줄로 쓴다.
  Task 목록의 `claimable_task_render_budget_rows = 10` 과 같은 성격의 표시 한도다. Keeper 흐름을 제어하지 않는다.
- 이 절은 `Keeper_context_layers.Rows` 로 만들고 `retention` 을 `Trimmable` 로 둔다.
  메시지가 예산을 넘으면 이 절의 행이 `Own_recent_actions` 보다 먼저 빠진다.
  [사실] 지금 `Trimmable` 은 `Own_recent_actions` 하나이고 순위 0 이다(`lib/keeper/keeper_context_layers.ml:114`).
  순위는 겹치면 안 되므로 `Own_recent_actions` 를 1 로 올리고 이 절을 0 으로 둔다.
- 행이 빠지는 순서는 §4.3 순서의 뒤쪽부터다. 머리 줄과 묶음별 수는 빠지지 않는다.
- 절의 자리(`ordered`)는 `Repository_freshness` 바로 뒤, `Autonomous_trigger` 앞이다.
  60초마다 바뀌므로 자주 안 바뀌는 앞쪽 절들의 prefix cache 를 깨지 않는 자리다.

### 4.5 "누가 이미 하고 있나"

keeper.md 는 "누가 이미 하고 있는지 먼저 본다"고 한다(`config/prompts/keeper.md:15`).
[제안] 행마다 아래 사실을 그대로 싣는다. 요약하거나 판정하지 않는다.

| 사실 | 원천 | Keeper 단위로 가를 수 있나 |
|---|---|---|
| 마지막 커밋을 쓴 Keeper | `keeper_of_author` (정확한 이름 비교) | 가를 수 있다 |
| 마지막으로 손댄 계정, 리뷰 상태(APPROVED·CHANGES_REQUESTED·COMMENTED·DISMISSED) 또는 댓글, 시각, 현재 head 에 달렸는지 | `latestReviews`, `comments(last: 5)` | 가를 수 없다. 계정만 안다 |
| GitHub 이 리뷰를 기다리는 계정 | `reviewRequests` | 가를 수 없다 |

[사실] 리뷰와 댓글은 공유 계정 둘로 달린다. 계정 하나를 Keeper 7명·12명이 같이 쓴다.
그래서 "anyang-keepers 가 2시간 전 COMMENTED" 까지는 말할 수 있고, 그게 어느 Keeper 인지는 말할 수 없다.
판정 댓글 첫 줄의 `by: <Keeper 이름>` 을 읽으면 가를 수 있어 보이지만, 댓글 본문을 글자로 읽는 분류라 쓰지 않는다.
Keeper 단위로 가르려면 Keeper 별 GitHub 신원이 먼저다(RFC keeper-github-apps, D7).
이 절의 안내 조각(`world.pull_requests.intro`)은 "계정 하나를 여러 Keeper 가 같이 쓴다"는 사실을 한 문장으로 적는다.

### 4.6 모양 예시

문구는 `config/prompts/keeper.md` 에 둔다. 아래는 구조를 보이려는 예시이고 최종 문구가 아니다.

```text
### Open Pull Requests
jeong-sik/masc — read 00:27:51Z (43 s ago) · open 89 · checks_failing 8 · changes_requested 10 · conflicting 2 · unreviewed_on_head 37 · draft 19 · mergeability not computed 0
One GitHub account is shared by several Keepers; a login below does not name a Keeper.
- checks_failing (8, showing 5)
  - #39247 [dune build @check] "feat(tui): …" by jeong-sik · base feat/tui-wheel-reader · head 20m · no touch since head · requested pangyo-preachers, anyang-keepers
  - #39401 [dune build @check] "fix(keeper): …" by jeong-sik · head 3h · last touch pangyo-preachers COMMENTED 2h (older head)
  - (3 more — keeper_pull_requests_list)
- changes_requested (10, showing 5)
  …
Your other open pull requests: #39410 (draft) #39422 (checks running)
```

### 4.7 전체 목록 도구

[제안] Keeper 도구 `keeper_pull_requests_list` 를 더한다.
- 같은 스냅숏을 읽고, 저장소·묶음·자기 PR 여부로 거른다. 행 모양은 World State 행과 같다.
- GitHub 을 부르지 않는다. 스냅숏이 `Pulls_failed` 이면 그 실패를 그대로 돌려준다.
- 정의는 `config/tools/` 의 TOML 로 둔다.
- World State 의 "N more" 줄이 이 도구 이름을 가리킨다. Task 목록의 `keeper_tasks_list` 와 같은 짝이다.

## 5. GitHub 변화로 깨우나

### 5.1 결정

[제안] **깨운다. 단, 그 PR 의 커밋 author 인 Keeper 한 명만, 세 가지 변화에만.** 스택의 마지막 단계로 두고, 앞 단계의 측정을 본 뒤 운영자가 켤지 정한다(D4).

| 변화 | 깨우나 |
|---|---|
| 자기 PR 의 checks 가 실패로 바뀜 | 깨운다 |
| 자기 PR 의 reviewDecision 이 CHANGES_REQUESTED 로 바뀜 | 깨운다 |
| 자기 PR 의 mergeable 이 CONFLICTING 으로 바뀜 | 깨운다 |
| 리뷰 요청 | 깨우지 않는다. 공유 계정으로 가서 받을 Keeper 가 하나로 정해지지 않는다. 계정의 Keeper 7명·12명을 다 깨우는 것은 턴만 늘린다 |
| 남의 PR 의 CI 실패 | 깨우지 않는다. 다음 keepalive(600초 이내)의 World State 에 보인다 |
| 새 PR | 깨우지 않는다. 같은 이유 |

깨우는 것은 허용되고, 행동을 강제하는 것은 허용되지 않는다(`docs/constitution.xml` 게이트 정책, 원칙 1).
깬 턴은 무엇이 바뀌었는지만 받는다. 무엇을 하라는 문장은 싣지 않는다.

### 5.2 왜 작성자만인가

- [사실] `On_demand` Keeper 는 owner 는 되살리지만 자발 턴은 없다
  (`lib/keeper/keeper_activation_mode.ml:3-4`, `lib/keeper/keeper_lifecycle_gate_env.ml:28-29`). 자극이 없으면 깨지 않는다.
  이런 Keeper 의 PR 이 빨개지면 지금은 아무것도 그 Keeper 를 부르지 않는다. 이 틈은 World State 만으로는 안 메워진다.
- `Autonomous` Keeper 는 600초 안에 World State 로 보게 된다. 깨우기가 더해 주는 것은 최대 10분이다.
  CI 가 15~20분 걸리는 것에 비하면 작다. 그래서 측정을 먼저 한다(§9 M3).
- 작성자 판정은 이름 비교 하나다. 이름은 누구나 커밋에 적을 수 있으므로 권한의 근거로 쓰지 않는다
  (`server_repository_pulls.mli` `keeper_of_author` 주석). 잘못 붙으면 한 Keeper 가 한 번 더 깰 뿐이다.

### 5.3 경로

[제안]

1. **producer**: `refresh` 가 같은 저장소의 직전 `Pulls_read` 와 새 `Pulls_read` 를 비교해 변화를 만든다.
   재시작 뒤 첫 읽기(직전이 `Pulls_not_read`)는 변화를 만들지 않는다. 재시작이 깨우기 폭주가 되지 않게 한다.
2. **store**: 변화마다 그 Keeper 의 event queue 에 `Pull_request_changed` 자극을 넣는다.
   event queue 는 durable 이다(모델 호출 전에 영속한다, constitution `persist_before_model_call`).
   ```ocaml
   type pull_request_change =
     | Checks_became_failing
     | Changes_became_requested
     | Became_conflicting

   (* Keeper_event_queue.payload 에 추가 *)
   | Pull_request_changed of
       { repo_slug : string; number : int; head_oid : string; change : pull_request_change }
   ```
   자극 id 는 `repo_slug`, `number`, `head_oid`, `change` 로 만든다. 같은 head 의 같은 변화는 한 번만 들어간다.
3. **consumer**: `Keeper_heartbeat_stimulus_intake.event_queue_trigger_of_stimulus`
   (`lib/keeper/keeper_heartbeat_stimulus_intake.ml:210-251`)에 arm 을 더해 새 trigger 를 낸다.
4. **turn_reason**: `Own_pull_request_changed_pending` 을 더한다. `turn_reason_to_string` 과 모든 exhaustive match 가 따라온다.
   Autonomous Trigger 절이 이 사유를 보여 주고, World State 의 `Pull_requests` 절이 그 PR 을 담는다.

## 6. Task 목록과 Goal

### 6.1 Task 행에 제목

[제안] 행은 한 줄이고 폭이 정해져 있다.

| 칸 | 값 |
|---|---|
| id, 우선순위, 나이(일) | `task-1787 P2 3d` |
| 제목 | `short_preview ~max_len:80`. [사실] 라이브 todo 제목 중앙값 98바이트, p90 135바이트 |
| 만든 이 | `created_by` |
| 이어진 Goal | 진행 중인 Goal 에 이어져 있으면 그 Goal 제목(짧게) |
| 마지막 반납 | `handoff_context` 가 있으면 `updated_by` 와 `reason`(짧게). [사실] todo 84개에 있다 |

"누가 이미 하고 있나"는 claimable Task 에는 해당하지 않는다(맡은 사람이 없는 Task 만 claimable 이다).
대신 누가 왜 놓았는지가 같은 물음에 답한다.

### 6.2 "관련 있는 것 먼저"의 뜻

[제안] 관련은 **Keeper 와 Task 사이에 타입으로 기록된 관계**로만 정한다. 제목이나 관심사를 글자로 맞춰 보지 않는다.
지금 기록된 관계로 만든 사전식 순서:

1. 진행 중인 Goal(`Goal_phase.admits_self_directed_progress`, `lib/goal/goal_phase.ml:54-57`)에 이어진 Task 먼저.
   Goal 은 운영자와 Keeper 가 "지금 이것을 진전시킨다"고 선언한 것이다.
2. 우선순위 높은 것 먼저. Task 작성자가 선언한 값이다.
3. **최근에 만든 것 먼저.** [사실] 48시간 안에 만든 Task 35개 중 27개가 끝났거나 진행 중이다.
   14일 넘은 todo 는 94% 이고, 최근 7일 done 102건 중 만든 지 14일 넘은 것은 2건이다.
   오래된 것부터 보이면 늘 같은 막힌 머리가 보인다.
4. id.

Keeper 한 명에게만 해당하는 관계는 지금 없다.
- [사실] `task.skills`(Task 가 요구하는 Skill)는 Keeper 의 Skill 과 타입으로 맞출 수 있는 유일한 칸인데, todo 595개 모두 비어 있다.
- 역할·관심사로 맞추는 것은 글자 분류라 하지 않는다.
- Task 를 만들 때 Skill 을 붙이게 할지는 운영자 결정이다(D5). 붙기 시작하면 "이 Keeper 가 가진 Skill 을 요구하는 Task"를
  1번 앞에 두는 것을 따로 제안한다.

### 6.3 auto-claim 도 같은 순서

[제안] 비교 함수 하나(`Task_claim_order.compare`)를 World State 목록과 `Workspace.claim_next_r` 이 같이 쓴다.
#29101 이 맞춰 둔 "읽는 첫 행 = auto-claim 이 잡을 첫 행"을 지킨다.
Goal 링크는 `Workspace_goal_index` 로 두 곳 모두에서 읽을 수 있다.
외부 에이전트의 `masc_claim_next` 도 같은 함수를 지나므로 같이 바뀐다.

다른 방법으로, Keeper 의 `keeper_task_claim` 에서 task_id 없는 호출을 없애 Keeper 가 늘 행을 골라 부르게 할 수도 있다.
[사실] 48시간 동안 Keeper 가 공용 대기열에서 스스로 다음 일을 집은 `task_claim_next` 는 2번이었고, 둘 다 몇 분 안에 반납됐다.
어느 쪽으로 갈지는 D2 로 둔다. 이 RFC 는 비교 함수 공유를 기본으로 제안한다.

### 6.4 Goal 은 모두에게

[제안] Active Goals 절은 진행 중인 Goal 을 모든 Keeper 에게 보여 준다. "Task 가 없으면 Goal 도 없음"을 지운다.

| 칸 | 값 |
|---|---|
| 제목, 성공 조건 | 지금과 같다(`world.active_goals.row`, `.criterion`) |
| 이어진 Task 수 | 상태별(todo, 진행 중) |
| 하고 있는 Keeper | 이어진 Task 를 `Claimed`·`InProgress` 로 쥔 Keeper 이름 |
| 표시 | 이 Keeper 가 쥔 Task 가 이 Goal 에 이어져 있으면 `yours` |

### 6.5 한도

- Task 행은 지금처럼 10행(`claimable_task_render_budget_rows`)이다. 7+3 으로 나누던 것은 한 목록으로 합친다.
  행 약 200바이트 × 10 ≈ 2KB.
- Goal 행도 10행까지 보이고, 넘치면 "N more — masc_goal_list" 한 줄이다.
  [사실] 라이브 진행 중 Goal 9개, 제목 70~131바이트. 행 약 250바이트 × 9 ≈ 2.2KB.

## 7. 지우는 것 (hard cut)

호환 reader, 옛 이름 별칭, "예전에는" 주석을 남기지 않는다.

| 지우는 것 | 위치 | 이유 |
|---|---|---|
| Task id 만 싣는 JSON 행 | `lib/keeper/keeper_unified_prompt.ml:1769-1777` | §6.1 행으로 바뀐다 |
| 오래된 7 + 최신 3 나누기, `claimable_task_newly_added_rows`, OCaml 안의 `"  Newly added (most recent):\n"` | `:1201-1203`, `:1799-1818` | 순서가 최근 것 먼저라 따로 뽑을 필요가 없다. 문장은 OCaml 에 있으면 안 된다 |
| claim 순서 정렬 두 벌 | `lib/keeper/keeper_world_observation_inputs.ml:214-226`, `claim_next_r` 안의 정렬 | §6.3 의 비교 함수 하나로 바뀐다 |
| Task 에 이어진 Goal 만 고르는 거르기 | `lib/keeper/keeper_unified_prompt.ml:1290-1336` `active_goal_summaries_for_task` | §6.4 |
| `turn_reason.Task_backlog` | `lib/keeper_contract/keeper_world_observation_turn_types.ml:79-82`, `lib/keeper/keeper_world_observation.ml:322`, `:1790-1806` | 모든 keepalive 에 붙고 턴 여부를 바꾸지 않는다. backlog 는 Namespace State 에 사실로 남는다 |
| `claimable_drives_wake`, `failed_drives_wake`, `actionable_signal_present` 중 위를 지운 뒤 부르는 곳이 없는 것 | `lib/keeper/keeper_world_observation.ml:1608-1620` | [사실] `actionable_signal_present` 는 지금도 lib 안에서 부르는 곳이 없다 |
| `Surface_ref.Webhook`, `Keeper_external_attention.Webhook` | `lib/keeper/surface_ref.ml:24`, `:110`, `lib/keeper/keeper_external_attention.ml:49` 와 이를 매치하는 곳 | 만드는 곳이 없다. 이 RFC 는 GitHub 을 읽기로 받는다. [사실] 라이브 저장소 JSON·JSONL 에 `webhook` 값 0건(tool_calls·logs·raw-traces·tool_blobs·turn-records 제외 검색). Telegram RFC-0384 도 webhook 방식을 빼고 있다 |

`Task_backlog` 를 지우면 system log 의 `keepalive turn scheduled` 사유에서 `task_backlog` 가 사라진다.
이 문자열을 세는 대시보드나 스크립트가 있으면 같은 PR 에서 고친다.

RFC-0465 는 대체하지 않는다. 그 RFC 의 서버 읽기와 Keeper 귀속 규칙에 소비자를 하나 더 붙이는 것이다.
TUI 표시 부분은 열린 #38801 이 이미 다른 RFC 로 넘긴다.

## 8. 구현 스택

작은 PR 로 나눈다. 앞 PR 이 병합된 뒤 다음 PR 을 main 기준으로 연다.

| # | 내용 | 확인 |
|---|---|---|
| S1 | `Repository_pulls` 모듈로 타입과 `current ()` 를 옮긴다. 읽기 fiber·자격은 `lib/server` 에 남긴다. 동작 변화 없음 | 기존 `server_repository_pulls` 테스트가 그대로 통과한다. HTTP JSON 이 옮기기 전과 바이트 단위로 같다(기록한 스냅숏 fixture 로 비교) |
| S2 | GraphQL 에 §3.2 칸을 더하고 decoder·타입·JSON 을 넓힌다 | 실제 응답을 줄여 만든 fixture 가 기대한 타입 행으로 decode 된다. 모르는 enum 값 하나를 넣은 fixture 는 `undecodable` 1 이 된다. PR 본문에 `rateLimit { cost }` 측정값을 적는다 |
| S3 | `layer_id.Pull_requests`, `placement`·순서·한도, `config/prompts/keeper.md` 의 `### world.pull_requests.*` 조각, `keeper_unified_turn.ml` 과 대시보드 미리보기 배선, `Repository.keepers` 로 대상 고르기 | fixture World State: CI 빨강 PR, CR PR, head 에 리뷰 없는 초록 PR, draft, `Pulls_failed` 저장소, 이 Keeper 가 쓴 PR 을 담은 스냅숏. 확인하는 것은 구조다(묶음 머리, 행 번호, 순서, `yours`, 실패 줄). 문구는 고정하지 않는다. 목록에 없는 Keeper 는 자기 PR 줄만 받는다. 예산을 줄이면 이 절의 행이 `Own_recent_actions` 보다 먼저, 순서의 뒤쪽부터 빠진다 |
| S4 | `keeper_pull_requests_list` 도구 | 도구 결과가 같은 스냅숏의 행과 같다. `Pulls_failed` 는 실패로 돌아온다. World State 의 "more" 줄이 이 도구 이름을 담는다 |
| S5 | Task 행 칸, `Task_claim_order.compare` 공유, Goal 을 모두에게 | fixture backlog: 진행 중 Goal 에 이어진 P3 Task, 오래된 P1, 새 P1. 목록 순서가 §6.2 대로다. `claim_next_r` 이 목록 첫 행을 잡는다. Task 없는 Keeper 의 World State 에 진행 중 Goal 이 나온다 |
| S6 | §7 의 `Task_backlog`, 쓰지 않는 함수, `Webhook` 제거 | exhaustive match 가 컴파일을 통과한다. 지운 이름이 `rg` 로 0건이다 |
| S7 | (D4 가 켜면) `Pull_request_changed` 자극과 `Own_pull_request_changed_pending` | 두 스냅숏에서 Keeper K 가 쓴 PR 의 checks 가 passing→failing 이면 K 에게 자극 1개. 재시작 뒤 첫 읽기는 0개. 같은 head 의 같은 변화 두 번은 1개. 다른 Keeper 에게는 0개 |

S1·S2·S3 은 서로 의존한다. S5 는 main 기준으로 따로 갈 수 있다. S6 은 S5 뒤, S7 은 S3 뒤다.

## 9. 배포 뒤 확인

코드 확인은 §8 이 맡는다. 여기는 라이브에서 확인하는 것과 효과를 재는 것이다.
잰 값은 판단 재료다. 어떤 값도 런타임 기준값이 되지 않는다.

**L1 — 빨간 PR 이 World State 에 보인다 (S3 배포 뒤)**

1. `GET /api/v1/repositories/pulls` 에서 `checks = failing` 인 masc PR 번호 하나를 고른다.
2. `repositories.toml` masc `keepers` 에 든 Keeper 하나의 다음 턴 기록(turn-records 의 `dynamic_context` 블록)을 읽는다.
3. 그 번호가 `checks_failing` 묶음 아래 있거나, 묶음 상한을 넘었으면 "more" 줄의 수에 들어 있다.
4. 목록에 없는 Keeper 의 같은 시각 턴 기록에는 이 절의 묶음 행이 없다.

**L2 — 아직 못 읽었을 때 말한다**
배포 재시작 직후 첫 읽기(최대 60초) 전에 돈 턴의 기록에서, 이 절이 "서버가 뜬 뒤 아직 읽지 않음" 줄을 내고
묶음 행을 그리지 않는지 본다. 라이브 설정을 바꾸지 않고 확인할 수 있는 실패 모양이 이것이다.
나머지 실패 모양(`Pulls_failed`, reader 없음)은 S3 fixture 가 맡는다.

**측정 (배포 전 7일과 배포 뒤 7일)**

| # | 무엇 | 어디서 |
|---|---|---|
| M1 | 묶음에 든 PR 중 24시간 안에 작성자 아닌 사람 리뷰·댓글이 달린 비율 | GraphQL, 매일 같은 시각 |
| M2 | CI 빨강·충돌 PR 에 Keeper 계정 커밋이 달린 수 | GraphQL `commits` |
| M3 | Keeper 가 쓴 PR 이 빨개진 뒤 그 Keeper 의 다음 커밋까지 걸린 시간. activation mode 별로 나눈다 | 스냅숏 변화 시각 + 커밋 시각 |
| M4 | 하루 `keeper_task_claim` 수와 claim 뒤 반납까지 걸린 시간 | task events |
| M5 | World State 바이트 중앙값 변화, memory recall 바이트와 비교 | turn-records |
| M6 | Keeper 가 부른 `gh pr view`·`gh pr list`·`gh pr checks` 하루 수 | 도구 호출 원장 |

D4(깨우기)는 M3 을 보고 정한다. `Autonomous` Keeper 가 이미 한 keepalive 안에 반응하면, 깨우기는 `On_demand` Keeper 몫만 남는다.

## 10. 열린 PR 과 겹치는 곳

2026-09-27 00:2xZ 열린 PR 90개의 파일 목록으로 확인했다.

| PR | 겹치는 파일 | 영향 |
|---|---|---|
| #38801 TUI measured home | `bin/masc_tui_repository_pulls.ml` 삭제, `docs/rfc/RFC-0465-…` 머리 수정, `lib/server/server_bootstrap_maintenance.ml` | S1 은 OCaml 타입을 옮기지만 HTTP JSON 은 그대로라 TUI decode 와 부딪히지 않는다. 이 RFC 는 RFC-0465 파일을 고치지 않는다. #38801 이 먼저 병합되면 스냅숏 소비자는 World State·도구·HTTP 만 남는다 |
| #39377 official client turns | `lib/keeper/keeper_unified_turn.ml` | S3 이 같은 파일의 입력 모으는 자리에 인자를 더한다. S3 은 #39377 뒤에 main 기준으로 연다 |
| #39401 unrenderable prompts | `lib/keeper/keeper_prompt.ml` | 병합되면 조각이 안 그려질 때 턴을 거절한다. S3 의 새 조각이 모두 그려지는지 테스트에 넣는다 |
| #39239 event queue persistence | `lib/keeper_runtime/keeper_event_queue_persistence.ml` | S7 이 payload variant 를 더하므로 저장 codec 과 부딪힌다. S7 은 #39239 뒤다 |
| #39244 취소 대기열 제거 2/3 | `lib/task/tool_task.ml`, `test/test_workspace_goal_index.ml` | S5 가 claim 정렬과 Goal 인덱스를 같이 쓴다. S5 는 #39244 뒤다 |
| #39392 backlog snapshot 인코딩 | workspace backlog | S5 와 파일이 가깝다. 파일 목록상 직접 겹침은 없다 |
| #39301 board attention 복구 | `lib/keeper/keeper_board_attention_*` | 이 RFC 는 Board attention 을 고치지 않는다. 겹침 없음 |
| #39320 provider resets | `lib/keeper/keeper_heartbeat_loop.ml` | S6·S7 은 heartbeat loop 를 고치지 않는다. 겹침 없음 |

`config/prompts/keeper.md`, `lib/keeper/keeper_context_layers.*`, `lib/keeper/keeper_unified_prompt.ml`,
`lib/server/server_repository_pulls.*` 를 고치는 열린 PR 은 없었다.

## 11. 운영자가 정할 것

| # | 물음 | 이 RFC 의 제안 |
|---|---|---|
| D1 | masc 저장소 `keepers` 목록에 누구를 넣나. 빈 목록이면 묶음 행은 아무에게도 안 보인다 | masc PR 에 판정·수리를 하는 Keeper. 예: e-masc-the-leader, masc-pro-builder, code-reviewer, context-reviewer, ocaml-agent-ic, rondo, simplifyer, pr-updater, tui-developer, polisher, indie-geek-blue, lane-smith, glossary-maniac, goo-yang-bong, jazz-developer. wkbl 행의 없는 이름 넷도 같이 고친다 |
| D2 | auto-claim 을 새 순서로 바꾸나, Keeper 의 task_id 없는 claim 을 없애나 | 비교 함수를 같이 쓴다(§6.3) |
| D3 | 묶음당 행 상한 | 5 (≈3.8KB) |
| D4 | 자기 PR 변화로 작성자 Keeper 를 깨우나 (S7) | M3 측정 뒤 결정 |
| D5 | Task 를 만들 때 Skill 을 붙이게 하나 | 붙기 시작하면 Skill 관계를 순서 맨 앞에 둔다 |
| D6 | PR 을 읽는 계정을 Keeper 공유 계정(anyang-keepers)에서 떼나 | 지금 계정 유지. rate limit 은 기존 `Rate_limited` 경로가 받는다 |
| D7 | Keeper 별 GitHub 신원(RFC keeper-github-apps)을 진행하나 | 이것 없이는 "누가 손댔나"가 계정 단위에 머문다. 이 RFC 는 계정 단위로 동작한다 |

## 12. 하지 않는 것

- PR 을 Keeper 에게 배정하지 않는다. 묶음·순서는 보여 주는 순서일 뿐이다.
- R1 초록 차선, HOLD, 병합 보류 같은 운영 규칙을 런타임에 넣지 않는다. 그 규칙은 Board 와 Keeper 가 가진다.
- PR 제목·본문·댓글·판정 줄을 글자로 읽어 분류하지 않는다.
- 새 cooldown, cap, 예약, "몇 시간 넘으면" 같은 시간 기준을 두지 않는다.
- 서버가 PR 을 만들거나 고치거나 병합하지 않는다. 읽기만 한다.
- Memory OS recall 의 크기와 순위는 다루지 않는다(§1.5).
- Board attention 의 관심사 판정은 다루지 않는다.

## 13. 확인하지 못한 것

- `mergeable` 이 한 시점에 80/91 이 `unknown` 이고 7분 뒤 0/89 인 이유. 서버 읽기 계정과 직접 조회 계정이 다르다는 점,
  main 이 자주 움직인다는 점이 후보다. 재지 않았다.
- figma-mcp·wkbl 저장소의 쿼리 cost. masc 만 쟀다.
- event queue 가 같은 자극 id 를 두 번 받을 때 하나로 합치는지. S7 에서 확인한다.
- `Manual` Keeper 가 event queue 자극으로 깨는지. `Manual` 은 owner 를 되살리지 않는다(`keeper_activation_mode.ml:3`).
  `On_demand` 는 owner 를 되살리므로 자극으로 깬다고 읽었지만, 턴까지 이어지는 경로를 끝까지 따라가지는 않았다.
- World State 를 읽은 Keeper 가 실제로 PR 을 더 고르는지. 이것은 §9 의 M1·M2 로만 알 수 있다.
- 측정값 일부(`gh` 명령 수, "없음·기다림" 문구 비율)는 정규식 집계라 과다·과소가 있다.
