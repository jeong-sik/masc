---
rfc: "keeper-world-state-shows-open-work"
title: "Keeper 의 World State 에 열린 PR 과 할 일을 제목과 함께 보여 준다"
status: Draft
created: 2026-09-27
updated: 2026-09-28
author: dancer + claude
supersedes: []
superseded_by: null
related: ["0465", "keeper-github-apps", "0385", "0462", "connector-ambient-attention-wake", "prompts-and-tool-definitions-outside-ocaml", "every-durable-store-has-one-boot-policy"]
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
   현재 head 에 리뷰 없음)으로 보여 준다. 묶음마다 행 상한이 하나 있다(§4).
2. **원천은 이미 도는 서버 PR 스냅숏(RFC-0465)이다.** webhook 이나 queue-ledger 를 새 원천으로 쓰지 않는다(§3).
3. **묶음 행은 그 저장소를 checkout 해 두었거나, keeper TOML 의 `watch_repositories` 에 그 저장소를 적은 Keeper 에게 보인다.**
   자기가 커밋한 PR 은 둘과 상관없이 늘 보인다(§4.1). 이 기준은 2026-09-28 운영자가 정했다(D1).
4. **GitHub 변화로 깨우는 것은 그 PR 에 마지막으로 커밋한 Keeper 한 명뿐이다.** 한 번 보낸 깨우기는 durable 기록으로 남겨
   중복과 유실을 막는다. 스택의 마지막 단계이고, 켤지는 측정 뒤에 정한다(§5).
5. **Task 행에 제목을 싣고, 보여 주는 순서만 "진행 중인 Goal 에 이어진 것 → 우선순위 → 최근 것"으로 바꾼다.**
   task_id 없이 부르는 claim 이 고르는 순서(`claim_next_r`)는 바꾸지 않는다. 진행 중인 Goal 은 Task 가 없는 Keeper 에게도 보인다(§6).
6. **옛 표시 방식과 쓰이지 않는 variant 를 지운다(§7).**

모두 투영이다. 배정도, 게이트도, 예약 규칙도 아니다. 무엇을 할지는 Keeper 가 고른다.

## 1. 지금 모습

코드 줄 번호는 `origin/main` `b34ab545d1`(2026-09-27) 기준이다. 그 뒤 main 에 병합된 PR 로 줄이 조금 밀렸을 수 있다.
측정값은 2026-09-26~27 운영자 런타임(`<base-path>/.masc`)의 로그·원장·턴 기록을 읽은 조사에서 왔다.
공개 저장소라 원본 로그는 싣지 않는다.

### 1.1 Keeper 는 자주 깨지만 PR 을 모른다

| 항목 | 값 | 근거 |
|---|---|---|
| 자율 턴 주기 | 라이브 600초 (기본 300초) | [사실] `lib/config/env_config_keeper.ml:553-554`, 라이브 `runtime_params.json` `keeper.keepalive_interval_sec` |
| 하루 턴 시도 | 5,529회. 깨운 이유: Board 47%, keepalive 26%, 자기 예약 15% | [사실] 09-26 system log `keeper cycle` 줄 |
| GitHub 때문에 깬 턴 | 0회 | [사실] `turn_reason` 에 GitHub variant 가 없다. `lib/keeper_contract/keeper_world_observation_turn_types.ml:64-81` |
| World State 의 PR 정보 | 없음 | [사실] `lib/keeper/keeper_unified_prompt.ml` 의 `content_of` 와 `lib/keeper/keeper_context_layers.mli:15-36` 의 `layer_id` 에 PR 절이 없다 |
| GitHub 이벤트 유입 | 없음 | [사실] `Surface_ref.Webhook` 은 decoder(`lib/keeper/surface_ref.ml:110`)에서만 만들어진다. lib·bin 어디에도 `x-github-event` 처리가 없다 |
| 도구 0회로 끝난 턴 | 완료 턴의 28%, keepalive 턴의 42% | [사실] 도구 호출 원장과 턴 이음 |
| 리뷰 요청이 가는 곳 | 공유 계정 둘. pangyo-preachers(Keeper 7명), anyang-keepers(Keeper 12명) | [사실] 각 Keeper 의 `github-cli/hosts.yml` `user` |
| 초록·Ready·REVIEW_REQUIRED 인데 Keeper 계정의 리뷰·댓글 0 | 45건 중 10건 | [사실] GitHub API 대조 |
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
  task_id 없이 부르는 `keeper_task_claim`(`lib/keeper/keeper_tool_task_runtime.ml:781`)이 쓰는
  `Workspace.claim_next_r`(`lib/workspace/workspace_task_schedule.ml:145`)과 같은 순서로 맞춰 둔 것이다(#29101).
- [사실] 라이브 todo 595개. 나이 중앙값 28일. 모든 Keeper 가 "Claimable tasks for this keeper: 596" 근처 값을 본다.
- [사실] 하루 `keeper_tasks_list` 1,331회, 새로 잡은 claim 26회.
- [사실] 모든 keepalive 턴(2,290회)에 `task_backlog` 사유가 붙었다. claimable 이 0 보다 크거나 failed 가 0 보다 크면 붙는다
  (`lib/keeper/keeper_world_observation.ml:1789-1806`). 이 사유는 턴을 열지 말지를 바꾸지 않는다.
  `Periodic_tick` 에서 턴을 여는 조건에 backlog 는 들어가지 않고, 사유 목록에만 붙는다(`:1769-1821`).

### 1.3 Goal 은 Task 를 쥔 Keeper 에게만

- [사실] Active Goals 는 이번 턴의 Task 에 이어진 Goal 만 보여 준다.
  "a turn with no task carries no Goals here" (`lib/keeper/keeper_unified_prompt.ml:1290-1336`).
- [사실] 이 RFC 에서 "진행 중인 Goal"은 `Goal_phase.admits_self_directed_progress` 가 참인 Goal, 곧 `Executing` 과 `Verifying` 이다
  (`lib/goal/goal_phase.ml:54-57`). 라이브에는 `executing` 9개, `verifying` 0개다. Task 없이 깬 Keeper 의 화면에는 0개가 보인다.
- [사실] 진행 중인 Goal 에 이어진 todo 는 12개다(`tasks/goal_task_links.json`).

### 1.4 이미 있는 것 — 서버 PR 스냅숏(RFC-0465)

- [사실] `Server_repository_pulls` 가 등록 저장소의 열린 PR 을 60초마다 GraphQL 로 읽는다
  (`lib/server/server_repository_pulls.ml:777-800`, 시작은 `lib/server/server_bootstrap_maintenance.ml:544`).
- [사실] 자격은 runtime.toml `[repositories] pr_reader` 가 가리키는 Keeper 의 토큰이다. 라이브는 `pr-updater` 다.
- [사실] 결과는 메모리(`Atomic`)에만 있다. 재시작하면 `Pulls_not_read` 부터 다시 읽는다.
  reader 가 준비되지 않았을 때도 모든 저장소가 `Pulls_not_read` 다(`lib/server/server_repository_pulls.mli:196-201`).
- [사실] 실패는 닫힌 타입이다. `Rate_limited { reset_at }`, `Token_rejected`, `Repository_not_visible` 등이 있고,
  빈 목록으로 접히지 않는다(`lib/server/server_repository_pulls.mli:55-81`).
- [사실] 지금 이 스냅숏을 읽는 곳은 HTTP 두 곳(`lib/server/server_routes_http_routes_repositories.ml:527`,
  `lib/server/server_h2_gateway.ml:1249`)과, 그 JSON 을 받는 TUI 다.
  열린 PR #38801 은 TUI 쪽 PR 표시를 걷어내면서 RFC-0465 머리에
  "서버의 PR 조회 API와 Keeper 귀속 규칙은 별도 기능으로 남는다"고 적는다.
- [사실] 라이브 스냅숏(2026-09-27 00:20:58Z, masc): 열린 PR 91개, checks failing 11, changes_requested 13,
  draft 16, 커밋 author 이름이 Keeper 이름과 같은 PR 8개.

### 1.5 다루지 않는 것 — 기억 recall 비중

프롬프트의 74~96% 가 Memory OS recall 이다. recall 은 자르지도 순위를 매기지도 않는다
(`lib/keeper/keeper_memory_os_recall.mli:6`). 턴마다 먼저 읽는 글이 지금의 기회보다 과거의 보류 기록이 되는 문제다.
이 RFC 는 World State 에 없는 입력을 채운다. recall 설계는 다루지 않는다.
다만 §9 의 측정에서 World State 가 늘어난 바이트를 같이 적어, 두 문제의 크기를 비교할 수 있게 한다.

## 2. 원칙

1. **투영이다.** World State 는 사실을 보여 준다. Keeper 를 배정하지 않고, 턴을 막지 않고, 예약을 만들지 않는다.
   Task 를 누가 먼저 잡게 되는지도 바꾸지 않는다.
2. **닫힌 타입으로 나눈다.** PR 의 묶음, 행의 순서, 깨울 변화는 모두 variant 와 타입 있는 칸으로 정한다.
   제목·본문·판정 댓글의 글자를 읽어 분류하지 않는다.
3. **사실은 한 곳에 있다.** PR 의 원본은 GitHub 이고, 서버 스냅숏은 메모리 투영이다.
   World State 와 도구는 그 스냅숏을 읽기만 한다. 파생 값을 권위 있는 저장소로 다시 쓰지 않는다.
   §5 의 깨우기 기록은 파생 값이 아니라 "이 깨우기를 보냈다"는 새 사실이다.
4. **모르는 것은 모른다고 쓴다.** 못 읽은 저장소, 아직 안 읽은 저장소, GitHub 이 계산하지 않은 충돌 여부,
   이 빌드가 모르는 GitHub 값을 빈 목록이나 "문제 없음"이나 다른 값으로 그리지 않는다(RFC-0462).
5. **문구는 `config/prompts` 에 둔다.** 새 절의 모든 문장은 `config/prompts/keeper.md` 의 `### world.*` 조각이다
   (RFC prompts-and-tool-definitions-outside-ocaml).

## 3. 원천 — 서버 PR 스냅숏을 넓혀 쓴다

### 3.1 세 후보

| 후보 | 좋은 점 | 나쁜 점 | 판단 |
|---|---|---|---|
| A. GitHub webhook → connector attention → `turn_reason` | 변화가 몇 초 안에 온다 | 저장소 설정에 webhook 을 걸 관리자 권한과 서명 비밀이 필요하다. 서버가 꺼져 있을 때 온 전달은 GitHub 이 자동으로 다시 보내지 않는다. 그래서 상태를 맞추려면 어차피 목록을 읽어야 한다. 밖에서 들어오는 입력 경로가 하나 늘어난다 | 쓰지 않는다 |
| B. 서버가 주기적으로 읽은 스냅숏 (RFC-0465 의 읽기) | 이미 라이브에서 돈다. 실패가 닫힌 타입이다. 읽는 계정이 하나라 rate limit 을 한 곳에서 다룬다 | 최대 60초 늦다 | **쓴다** |
| C. `scripts/review/queue-ledger.sh` 재사용 | R1 병합 조건별로 "누구의 결정을 기다리나"를 한 줄로 낸다 | bash 스크립트이고 저장소 clone(`--git-dir`)이 필요하다. 리더가 Board 에 정한 R1 규칙을 코드로 옮긴 것이라, 런타임 사실로 넣으면 운영 규칙이 런타임에 박힌다. verdict 줄을 글자로 읽는다(`queue-ledger.sh:17-27`) | 원천으로 쓰지 않는다. Keeper 가 도구로 돌리는 것은 그대로 둔다 |

A 의 재전송: GitHub 공식 문서(2026-09-27 확인,
[Handling failed webhook deliveries](https://docs.github.com/en/webhooks/using-webhooks/handling-failed-webhook-deliveries))는
"GitHub does not automatically redeliver failed webhook deliveries" 라고 적는다.

B 의 60초 지연은 문제가 아니다.
- [사실] Keeper 의 자율 턴 주기가 600초다.
- [사실] PR 의 CI(`PR check` workflow)는 생성부터 끝까지 중앙값 14분이다. 2026-09-27 17:4xZ 에 최근 완료된 pull_request run 36개를 쟀고, 6분에서 60분까지 퍼져 있다.

Lane add-on(`Lane_addon_subscription`, `docs/design/lane-addon-v0.md`)으로 넣는 방법도 봤다.
Lane add-on 은 기계 lane 의 사건을 구독하는 틀이다. PR 은 lane 이 아니라 저장소의 사실이라, 그 틀에 끼우면 facade 가 하나 더 생긴다.
쓰지 않는다.

### 3.2 더 읽을 칸과 모르는 값

[사실] 지금 쿼리는 PR 마다 `number isDraft reviewDecision mergeable`, head 의 `statusCheckRollup.state`,
최근 10커밋의 부모 수와 author 이름을 읽는다(`lib/server/server_repository_pulls.ml:227-238`).

[제안] 아래를 더한다.

| 칸 | 쓰는 곳 |
|---|---|
| `title`, `createdAt`, `baseRefName`, `headRefOid`, `author { __typename login }` | 행 내용, 스택 PR 표시 |
| head 커밋의 `oid`, `committedDate` | head 커밋의 나이, 묶음 안의 순서. 커밋 시각은 PR branch 에 push 된 시각이 아니다 |
| `statusCheckRollup.contexts(first: 30)` 의 CheckRun `name conclusion status`, StatusContext `context state` | 실패한 check 이름 |
| `reviewRequests(first: 10)` 의 `requestedReviewer { __typename ... on User { login } ... on Team { slug } }` 와 `pageInfo { hasNextPage }` | GitHub 이 누구의 리뷰를 기다리나. 잘렸으면 나머지가 있다고 표시한다 |
| `latestReviews(first: 10)` 의 `author { __typename login } state submittedAt commit { oid }` 와 `pageInfo { hasNextPage }` | 계정별 마지막 리뷰, 그 리뷰가 현재 head 에 달렸는지. 잘렸으면 "현재 head 에 리뷰 없음"을 확정하지 않는다 |
| `comments(last: 1)` 의 `author { __typename login } createdAt` | 마지막 댓글. 일반 PR 댓글에는 head SHA 가 없으므로 현재 head 의 리뷰로 세지 않는다 |

`latestOpinionatedReviews` 는 쓰지 않는다. [사실] 00:27Z 조회에서 이 칸에는 CHANGES_REQUESTED 15건만 있었다.
Keeper 판정은 COMMENTED 리뷰(00:35Z `latestReviews` 조회에서 34건)로 많이 달리므로 이 칸으로는 놓친다.

커밋의 `committedDate` 뒤에 달린 일반 PR 댓글도, 그 커밋이 branch 에 push 되기 전에 이전 head 를 보고 쓴 것일 수 있다.
그래서 댓글 시각으로 "현재 head 이후 손댐"을 증명하지 않는다.
리뷰 목록의 페이지가 잘렸으면 못 본 리뷰를 "리뷰 없음"으로 바꾸지 않는다.

**모르는 값.** [제안] 새 칸과 기존 칸 모두 모르는 값을 타입 있는 `Unrecognized` 값으로 읽는다.
칸 하나를 모른다고 PR 행을 버리지 않는다. 그 칸만 "모름"으로 보인다.

```ocaml
type actor =
  | User of string                 (* login *)
  | Bot of string
  | Other_actor of { typename : string; login : string option }  (* Mannequin, Organization 등 *)
  | Actor_absent                   (* GitHub 이 null 을 준다: 지워진 계정 *)

type requested_reviewer =
  | Requested_user of string
  | Requested_team of string       (* slug *)
  | Requested_unrecognized of string   (* __typename *)

type check_state = Checks_passing | Checks_failing | Checks_running | Checks_none
                 | Checks_unrecognized of string   (* GitHub 의 원래 값 *)
(* review_state, mergeable, 리뷰 state, CheckRun conclusion 도 같은 모양으로 Unrecognized 를 갖는다 *)
```

`Unrecognized` 에 담긴 원래 값은 화면에 보여 주기만 한다. 그 글자로 분기하지 않는다.
[사실] 지금은 checks·review·mergeable·author 중 하나라도 못 읽으면 그 PR 은 행에서 빠지고 `undecodable` 로만 센다
(`lib/server/server_repository_pulls.ml:355-357`). 이 동작은 §7 에서 지운다.
`undecodable` 은 PR 번호처럼 행을 세울 수 없는 칸이 없을 때만 남는다.

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

[사실] `lib/server` 는 `(include_subdirs no)` 인 별도 라이브러리 `masc_server` 이고(`lib/server/dune:1-5`), `masc` 에 기댄다.
`lib/keeper` 는 `masc` 안에 있다. 그래서 World State 가 `Server_repository_pulls` 를 부르는 것은 라이브러리 순환이라 컴파일되지 않는다.
타입과 투영을 `masc` 쪽으로 옮기는 것이 이 RFC 의 선행 조건이다.

| 단계 | 무엇 | 위치 |
|---|---|---|
| producer | 60초마다 GraphQL 로 읽는 fiber | [사실] `Server_repository_pulls.start` → `refresh` (`lib/server/server_repository_pulls.ml:582`, `:779`). 이 fiber 와 자격 처리는 `masc_server` 에 남는다 |
| store | 메모리 투영. 재시작하면 비어 있다 | [제안] 타입, `keeper_of_author`, `github_slug_of_remote`, `Atomic` 투영을 `masc` 라이브러리의 새 모듈 `Repository_pulls`(`lib/repository_pulls/`)로 옮긴다. 쓰는 함수는 `Repository_pulls.publish : snapshot -> unit` 하나이고 producer 만 부른다. 읽는 함수는 `Repository_pulls.current : unit -> snapshot` 이다 |
| 대상 입력 1 | 이 Keeper 의 checkout 과 그 remote | [제안] §4.1. `Keeper_sandbox_control.checkout_freshness_rows` 가 이미 턴마다 도는 checkout 측정(`lib/keeper/keeper_unified_turn.ml:768`)에 remote 한 칸을 더한다 |
| 대상 입력 2 | 이 Keeper 가 선언한 `watch_repositories` | [제안] §4.1. keeper TOML 을 읽을 때 `Github_slug.t list` 로 파싱되어 profile·meta 에 실린다(`board_interests` 와 같은 길, `lib/keeper/keeper_types_profile_toml_parser.ml:29`, `lib/keeper/keeper_meta_contract.ml:250`). 턴은 이미 받는 meta 에서 읽는다. 턴 중에 따로 읽는 저장소는 없다 |
| consumer 1 | World State `Pull_requests` 절 | [제안] `Keeper_context_layers.layer_id` 에 variant 추가, `keeper_unified_prompt.ml` 의 `content_of` 에 arm 추가 |
| consumer 2 | 전체 목록 도구 `keeper_pull_requests_list` | [제안] §4.7 |
| consumer 3 | 기존 HTTP 두 곳 | [사실] `server_routes_http_routes_repositories.ml:527`, `server_h2_gateway.ml:1249`. [제안] 둘 다 `Repository_pulls.current` 를 읽는다. JSON 은 새 칸과 `unrecognized` 값만 더한다 |
| consumer 4 | §5 의 깨우기 (S7) | [제안] producer 가 `publish` 한 뒤 같은 snapshot 으로 계산한다 |
| caller | 턴을 조립하는 곳 | [제안] `lib/keeper/keeper_unified_turn.ml:750-805` 가 `repository_freshness`·`lane_updates` 와 같은 자리에서 `Repository_pulls.current ()` 와 checkout 측정 결과를 `Keeper_unified_prompt.build_prompt` 에 넘긴다. 대시보드 미리보기(`lib/dashboard/dashboard_http_keeper_snapshot.ml:204`)도 같은 두 값을 넘긴다 |

옛 이름 `Server_repository_pulls` 로 타입을 다시 내보내는 별칭은 두지 않는다. facade 위에 facade 를 만들지 않는다.

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

상태 줄을 먼저 쓴다. 행이 있든 없든 쓴다. 위 줄이 아래 줄보다 먼저 정해진다.

| 스냅숏 상태 | World State 에 쓰는 것 |
|---|---|
| `reader` 가 `Reader_ready` 가 아님 | 이유 한 줄(선언 없음, 선언이 잘못됨, Keeper 없음, 토큰 없음). 이때 저장소마다의 `Pulls_not_read` 줄은 쓰지 않는다. 이유가 reader 에 있기 때문이다 |
| `repositories_error = Some _` | 아래 행이 지난 읽기의 것이라는 문장과 이유 |
| `Pulls_read { observed_at }` | 읽은 시각(UTC)과 몇 초 전인지 |
| `Pulls_failed { observed_at; failure }` | 못 읽은 이유와 시각. `Rate_limited` 는 GitHub 이 준 다시 읽을 시각. 행은 그리지 않는다 |
| `Pulls_not_read` (reader 는 준비됨) | 서버가 뜬 뒤 아직 읽지 않음 |
| `Pulls_not_github` | 그리지 않는다. GitHub 저장소가 아니다 |

"몇 초 넘으면 오래됐다" 같은 기준은 두지 않는다. 시각만 보여 주고 판단은 Keeper 가 한다.

## 4. World State 의 `Pull_requests` 절

### 4.1 누구에게 보이나

[결정, 2026-09-28 운영자] 대상은 **(checkout 이 있는 저장소) ∪ (선언한 저장소)** 이고, 자기 PR 은 늘 보인다.

1. **자기 PR.** PR 의 가장 최근 부모 하나짜리 커밋 author 이름이 이 Keeper 이름과 정확히 같으면
   (`keeper_of_author`, RFC-0465 §2.1) 그 PR 은 이 Keeper 에게 늘 보인다. checkout 과 상관없다.
   [사실] 런타임이 Keeper 도구 프로세스의 `GIT_AUTHOR_NAME`·`GIT_COMMITTER_NAME` 을 Keeper 이름으로 채운다
   (`lib/exec_ssh_protocol/exec_ssh_protocol.ml:105-106`, `lib/exec_shim/exec_shim.ml:74`).
   이 RFC 에서 "커밋한 Keeper"는 이 값이다. PR 을 연 GitHub 계정(`author.login`)은 "PR 계정"이라고 따로 부른다.
2. **저장소의 묶음 행 — checkout.** 이 Keeper 의 playground 에 그 저장소 checkout 이 있을 때 보인다.
   - checkout 은 `Keeper_playground_checkouts` 가 찾고 `Keeper_sandbox_control.checkout_freshness_rows` 가 턴마다 잰다.
   - [사실] 지금 측정 행(`freshness_row`, `lib/keeper/keeper_sandbox_control.mli:65-72`)에는 경로·브랜치·변경 파일 수·upstream 비교만 있다.
     그 checkout 이 어느 저장소인지는 없다.
   - [제안] 같은 측정에서 `remote.origin.url` 을 읽어 `row_remote` 칸으로 더한다.
     그 URL 을 기존 `github_slug_of_remote`(RFC-0465 의 정확한 세 표기 파서)로 `owner/repo` 로 바꾸고,
     스냅숏의 `slug` 와 같으면 그 저장소에서 일하는 Keeper 로 본다. 이름이나 경로의 글자를 맞춰 보지 않는다.
3. **저장소의 묶음 행 — 선언.** keeper TOML 의 `watch_repositories` 에 그 저장소가 있으면 checkout 이 없어도 보인다.
   checkout 없이 판정·병합을 하는 Keeper 를 위한 칸이다.

**`watch_repositories` 칸** [제안]

| 항목 | 정의 |
|---|---|
| 이름·자리 | keeper TOML 의 최상위 키 `watch_repositories`. `board_interests`·`mention_targets` 와 같은 줄에 둔다 |
| 값 모양 | 문자열 배열. 각 값은 `owner/name` 이다. 예: `watch_repositories = ["jeong-sik/masc"]` |
| 파싱 | TOML 을 읽을 때 한 번 `Github_slug.of_string` 으로 `Github_slug.t` 로 바꾼다. `github_slug_of_remote` 도 같은 `Github_slug.t` 를 내도록 바꾼다. 규칙은 `github_slug_of_remote` 가 remote 의 경로 부분에 쓰는 것과 같다. `/` 로 나눈 조각이 정확히 둘이고 둘 다 비어 있지 않다. 선언은 remote 가 아니라 slug 이므로 `.git` 이나 끝 `/` 를 떼어 주지 않는다. 앞뒤 공백도 받지 않는다 |
| 틀린 값 | 값 하나라도 틀리면 그 keeper 파일의 로드 오류다. 틀린 값을 빼고 나머지만 쓰지 않는다. 오류는 파일 경로, 키, 틀린 값을 말한다. 필드 종류 검사(`Field_string_array`, `keeper_types_profile_toml_parser.ml:23-58`)에도 올린다 |
| 중복 | 같은 slug 두 번은 하나로 합친다(`board_interests` 의 `sort_uniq` 와 같다). 버리는 것이 아니다 |
| 비교 | 스냅숏 저장소의 `Github_slug.t` 와 `Github_slug.equal` 로만 비교한다. 대소문자를 무시하거나 앞부분만 맞추지 않는다. 글자로 분류하지 않는다 |
| 편집 | `POST /api/v1/keepers/<name>/config` 의 허용 칸(`dashboard_config_patch_allowed_fields`, `lib/server/server_dashboard_http_keeper_api_post.ml:717-729`)에 더한다. 요청은 문자열 배열로 받고, 저장하기 전에 같은 파서를 지난다. 하나라도 틀리면 400 과 틀린 값을 돌려주고 아무것도 저장하지 않는다. `GET` 은 `workspace.watch_repositories` 로 돌려준다. 저장 파일 쓰기는 `lib/keeper/keeper_turn_up_config_persistence.ml:345`, `:440` 의 `board_interests` 옆이다 |
| 화면 | TUI Keeper 설정 편집 표(`bin/masc_tui_keeper_config.ml:19-30` 의 `editable_fields`)와 웹 대시보드 설정 패널(`dashboard/src/components/keeper-config-panel.ts`, `board_interests_text` 옆)에 같은 칸을 더한다. `masc_keeper_up` 도구(`config/tools/masc_keeper_up.toml:32` 근처의 `board_interests`)도 같은 칸을 받는다 |

**실패 경로**

| 대상 입력의 상태 | 이 절이 하는 일 |
|---|---|
| `Ok rows`, 어떤 행의 remote 가 그 저장소 | 그 저장소의 묶음 행을 보인다 |
| `Ok rows`, 그 저장소 remote 가 없음 | 그 저장소는 자기 PR 줄만 보인다 |
| `Ok rows`, 어떤 행의 remote 를 못 읽음 | 그 행은 대상 판정에 쓰지 않는다. "remote 를 못 읽은 checkout N개" 한 줄을 쓴다 |
| `Error (Root_missing _)` | checkout 이 없다. 자기 PR 줄만 보인다. 지금 Repository freshness 가 이 경우를 비어 있음으로 다루는 것과 같다(`keeper_unified_turn.ml:776`) |
| `Error` 의 나머지(`Root_not_directory`, `Root_unreadable`, `Root_probe_unreachable`) | "checkout 을 읽지 못함: <이유>" 한 줄. 선언한 저장소의 행과 자기 PR 줄은 그대로 보인다. 지금은 이 오류가 로그로만 가고 `[]` 가 된다(`:777-786`). 이 절은 `[]` 가 아니라 `Error` 를 받는다 |
| 선언한 slug 가 스냅숏의 어느 저장소와도 같지 않음 | "선언한 저장소 <slug> 는 서버가 읽는 저장소 목록에 없음" 한 줄. 오타·대소문자 차이가 조용히 아무것도 안 보이게 되지 않게 한다 |
| 선언 읽기 실패 | 없다. 선언은 keeper TOML 을 읽을 때 파싱되고, 틀리면 그 keeper 가 로드되지 않는다. 턴 중에 선언을 다시 읽지 않으므로 턴 중 읽기 실패도 없다 |

**선언이 필요한 이유.** [사실] 조사 시각의 last-prompt 캡처에서 Keeper 24명 중 11명이 checkout 0개였다
(polisher, rondo, simplifyer, tui-developer, glossary-maniac 등 masc PR 판정을 하는 Keeper 포함).
checkout 만으로는 이 Keeper 들이 묶음 행을 받지 못한다. 선언이 그 틈을 채운다.
어느 checkout 이 masc 인지는 캡처에 remote 가 없어 확인하지 못했다(§13).

**배포 뒤 운영자 단계.** S5 배포 뒤 운영자가 keeper config endpoint 로 아래 Keeper 에 `watch_repositories = ["jeong-sik/masc"]` 를 먼저 넣는다.
기준은 "masc PR 을 판정·병합하거나 masc 이슈를 배정받는데, 캡처에서 checkout 이 0개였거나 수를 확인하지 못한 Keeper"다.

| Keeper | 캡처의 checkout | masc 에서 하는 일 (근거: 09-25~27 조사) |
|---|---|---|
| rondo | 0 | 문서 판정 담당, 이름 적힌 승인 21건 |
| simplifyer | 0 | runtime·Keeper 판정, 승인 13건 |
| polisher | 0 | `[polish]` Task, masc PR push |
| tui-developer | 0 | TUI 판정 담당 |
| glossary-maniac | 0 | masc PR 작성 9건 병합 |
| context-reviewer | 캡처 없음 | 승인 17건, 매 턴 판정 담당(R3) |
| jazz-developer | 캡처 없음 | #39356 배정 |

checkout 이 있는 Keeper 는 S3a 뒤 `row_remote` 로 masc checkout 여부를 센 다음, masc 가 아닌 판정 Keeper 에게만 선언을 더한다.

검토했지만 고르지 않은 기준:

| 기준 | 고르지 않은 이유 |
|---|---|
| `repositories.toml` 의 저장소 `keepers` 목록 | [사실] 런타임에서 읽는 곳이 없다(읽고 쓰는 곳은 `lib/repo_manager/repo_store.ml` 뿐). 라이브 값이 틀렸다: masc 는 `[]`, wkbl 은 지금 없는 Keeper 이름 넷. 운영자는 저장소 쪽이 아니라 Keeper 쪽 선언을 골랐다. 같은 사실을 두 곳에 두지 않도록 이 칸은 따로 지운다(§7) |
| `board_interests` | 관심사 문자열과 PR 제목·파일을 맞춰 보는 것은 글자 분류다 |
| GitHub 자격이 있는 모든 Keeper | 자격 유무는 `hosts.yml` 읽기로 알 수 있다(`Keeper_github_login_lane.stored_token`). 하지만 자격이 있다는 것은 그 저장소에서 일한다는 뜻이 아니다. [사실] 24명 중 20명이 자격이 있다 |
| 모든 Keeper | [사실] GitHub 자격이 없는 Keeper 가 넷이다(geek-scout, msx-retro-mania, rust-hwp-guy, won-chik). 행동할 수 없는 목록을 매 턴 싣는다 |

### 4.2 무엇을 보이나

[제안] PR 하나는 아래 표의 위쪽부터 처음 맞는 칸 하나에만 든다. Draft 가 가장 먼저다.

| 순서 | 조건 | 자리 |
|---|---|---|
| 1 | `draft = true` | 행 없음, 수만 센다 (`Draft`) |
| 2 | checks 가 `Checks_failing` | `Needs Checks_failing` |
| 3 | review 가 `Review_changes_requested` | `Needs Changes_requested` |
| 4 | mergeable 이 `Conflicting` | `Needs Conflicting` |
| 5 | checks 가 `Checks_running` | 행 없음, 수만 센다 (`Checks_running`) |
| 6 | checks 가 `Checks_passing` 또는 `Checks_none`, 그리고 `head_review = Not_reviewed_on_head` (review 결정이 `Review_waiting`·`Review_none`·`Review_approved` 중 무엇이든) | `Needs Unreviewed_on_head` |
| 7 | checks 가 `Checks_passing` 또는 `Checks_none`, 그리고 `head_review = Review_history_incomplete` | 행 없음, 수만 센다 (`Review_history_incomplete`) |
| 8 | checks 가 `Checks_passing` 또는 `Checks_none`, 그리고 `head_review = Reviewed_on_head` | 행 없음, 수만 센다 (`Reviewed_on_head`) |
| 9 | checks 가 `Checks_unrecognized _` 이고 위 2~4 에 들지 않음 | 행 없음, 수만 센다 (`Checks_unrecognized`). 머리 줄에 원래 값을 적는다 |

`head_review` 는 세 값이다.

```ocaml
type head_review =
  | Reviewed_on_head            (* 어떤 계정이든 commit.oid = headRefOid 인 리뷰가 있다 *)
  | Not_reviewed_on_head        (* 리뷰 목록이 잘리지 않았고, 현재 head 에 달린 리뷰가 없다 *)
  | Review_history_incomplete   (* 목록이 잘렸고(hasNextPage), 본 범위에는 현재 head 리뷰가 없다 *)
```

6번에 `Review_approved` 가 드는 이유: head 가 바뀌어도 GitHub 의 review 결정은 예전 승인으로 남을 수 있다.
"현재 head 에 리뷰가 있나"는 리뷰의 `commit.oid` 와 `headRefOid` 가 같은지로만 본다. 댓글은 쓰지 않는다(§3.2).

```ocaml
type attention =
  | Checks_failing
  | Changes_requested
  | Conflicting
  | Unreviewed_on_head

type not_listed =
  | Draft
  | Checks_running
  | Reviewed_on_head
  | Review_history_incomplete   (* 잘린 리뷰 목록으로는 현재 head 의 미검토를 확정할 수 없다 *)
  | Checks_unrecognized

type placement =
  | Needs of attention
  | Not_listed of not_listed
```

구현은 `draft`, `check_state`, `review_state`, `mergeable`, `head_review` 다섯 칸의 생성자를 모두 적는 match 로 한다.
`_` 로 남은 경우를 묶지 않는다. 새 생성자가 생기면 이 표를 다시 정해야 컴파일된다.
review·mergeable 이 `Unrecognized` 인 PR 은 2~4 에서 그 칸만 맞지 않은 것으로 보고 다음 줄로 간다. 행에는 그 칸이 "모름"으로 보인다.

**저장소 머리 줄** (행 수와 상관없이 늘 나온다):
읽은 시각, 열린 PR 수, 네 묶음과 `not_listed` 다섯 자리의 수, 충돌 여부를 GitHub 이 아직 계산하지 않은 PR 수.

충돌 여부 수를 따로 세는 이유: [사실] 00:20:58Z 서버 스냅숏에서 91개 중 80개가 `unknown` 이었고,
7분 뒤 직접 조회에서는 89개 중 0개였다. GitHub 이 목록 조회 때 충돌을 늦게 계산한다.
원인은 확인하지 못했다(§13). 그래서 `Conflicting` 묶음은 GitHub 이 CONFLICTING 이라고 말한 PR 만 담고, 나머지는 "모름" 수로 보여 준다.

**행** (한 줄, 폭이 정해져 있다):

| 칸 | 값 |
|---|---|
| 번호·묶음 | `#39401 checks_failing` |
| 실패 check | 이름 두 개까지. 그 이상은 수 |
| 제목 | `Keeper_types_profile.short_preview ~max_len:80` (Board 행과 같은 자르기, `keeper_unified_prompt.ml:1231`) |
| PR 계정 | `author` 의 login. `Actor_absent` 면 "지워진 계정" |
| base | `main` 이 아니면 base 이름(스택 PR) |
| head 나이 | head 커밋 이후 흐른 시간 |
| 손댄 계정 | §4.5 |
| 리뷰 요청 | `reviewRequests` 의 login·team slug |
| 표시 | 이 Keeper 가 커밋한 Keeper 면 `yours` |

**자기 PR 중 묶음에 들지 않는 것**은 한 줄에 번호와 자리만 늘어놓는다(예: `#39410 (draft) #39422 (checks running)`).

### 4.3 순서

[제안] 묶음 순서는 위 `attention` 선언 순서다.
Repository freshness 가 drift 종류마다 순위를 정해 정렬하는 것(`lib/keeper/keeper_unified_prompt.ml:1886-1897` 의 `drift_rank`)과 같은 모양이다.

묶음 안의 순서는 타입 있는 칸으로만 정한 사전식 순서다. 가중치나 점수를 더하지 않는다.

1. 이 Keeper 의 PR(`yours`) 먼저.
2. **`head_review` 순서: `Not_reviewed_on_head` → `Review_history_incomplete` → `Reviewed_on_head`.** 현재 head 에 리뷰가 없다고 확인된 PR 이 먼저,
   리뷰 목록이 잘려 모르는 PR 이 그다음이다. 리뷰의 `commit.oid = headRefOid` 인지만 본다. 어느 계정이 달았는지는 보지 않는다.
3. head 커밋의 `committedDate` 가 이른 것 먼저. 그다음 PR 번호.

이렇게 정한 이유와 대가:

- 2번에 계정을 넣지 않는다. 계정 하나를 Keeper 여럿이 쓰므로 "PR 계정이 아닌 계정"으로 거르면
  같은 계정의 다른 Keeper 리뷰가 빠진다. D7 로 Keeper 가 GitHub App 이 되면 Keeper 리뷰가 `Bot` 이 되므로, `Bot` 을 빼는 규칙도 두지 않는다.
  대가: 리뷰 봇(chatgpt-codex-connector, [사실] 00:35Z `latestReviews` 에 COMMENTED 17건)만 단 PR 도 "리뷰 있음" 쪽으로 간다.
  행에는 그 계정이 보이므로 Keeper 가 읽고 판단한다.
- 댓글은 순서에 쓰지 않는다. 댓글은 커밋과 이어지지 않아서, "현재 head 뒤에 달렸나"를 보려면
  커밋한 기계의 시계(`committedDate`)와 GitHub 서버 시계(`createdAt`)를 비교해야 한다. 마지막 댓글은 §4.5 처럼 보여 주기만 한다.
- 3번의 `committedDate` 는 커밋한 기계의 시계이고, branch 에 push 된 시각이 아니다. 시계가 틀리거나 오래된 커밋을 늦게 push 하면 묶음 안의 자리가 바뀔 뿐, 묶음은 바뀌지 않는다.

[관찰, 재분류 필요] 00:35Z 조회에서는 묶음에 든 57건 중 45건을 "현재 head 이후 아무도 손대지 않음"으로 셌다.
그 집계는 커밋 시각과 댓글 시각을 비교했고, 잘린 리뷰 목록을 구분하지 않았다. 그래서 현재 head 의 미검토 건수로 확정하지 않는다.
§9 의 M1 에서 완전한 리뷰 페이지와 head OID 로 다시 센다.

Task 목록과 달리 여기서는 오래된 것이 먼저다. [사실] 열린 PR 은 병합·종료로 계속 빠진다(48시간 병합 389건).
오래 열린 PR 은 버려진 것이 아니라 기다리는 것이다.

### 4.4 한도

[사실] 00:27Z 스냅숏으로 모든 묶음 행을 그리면 68행, 평균 187바이트, 합계 약 12.8KB 다.
지금 World State 전체가 Keeper 별 중앙값 11~22KB 다. 열린 PR 수가 늘면 같이 늘어난다.

[제안] 한도는 하나만 둔다.

- **묶음마다 행 상한 `pull_request_rows_per_attention`.** 기본 5 를 제안한다(D3).
  네 묶음 × 5행 × 약 190바이트 ≈ 3.8KB 다.
  Task 목록의 `claimable_task_render_budget_rows = 10` 과 같은 성격의 표시 한도다. Keeper 흐름을 제어하지 않는다.
- **자기 PR 은 상한에 세지 않는다.** 이 규칙이 있어야 §4.1 의 "자기 PR 은 늘 보인다"가 참이다.
  자기 PR 행은 그 묶음 맨 앞에 오고, 상한 5 는 자기 PR 을 뺀 나머지에 적용된다.
  자기 PR 수는 그 Keeper 가 연 PR 수로 묶인다. [사실] 2026-09-27 17:53Z 서버 스냅숏에서 커밋한 Keeper 가 붙은 열린 PR 은 Keeper 당 최대 2개(tui-developer, simplifyer), 합계 7개였다.
- 묶음 머리에는 "N개 중 k개 보임"을 쓴다. Board Activity·Fleet Messages 머리가 개수를 세는 것과 같다.
  나머지를 읽는 도구 이름(`keeper_pull_requests_list`)은 절 안내 조각에 한 번 적는다. 행을 빼고 "N more" 줄을 따로 붙이지 않는다.
- 절의 자리(`ordered`)는 `Repository_freshness` 바로 뒤, `Autonomous_trigger` 앞이다.
  60초마다 바뀌므로 자주 안 바뀌는 앞쪽 절들의 prefix cache 를 깨지 않는 자리다.

### 4.5 "누가 이미 하고 있나"

keeper.md 는 "누가 이미 하고 있는지 먼저 본다"고 한다(`config/prompts/keeper.md:15`).
[제안] 행마다 아래 사실을 그대로 싣는다. 요약하거나 판정하지 않는다.

| 사실 | 원천 | Keeper 단위로 가를 수 있나 |
|---|---|---|
| 커밋한 Keeper | `keeper_of_author` (정확한 이름 비교) | 가를 수 있다 |
| 계정별 마지막 리뷰: 계정, 종류(`User`·`Bot`·그 밖), 상태(APPROVED·CHANGES_REQUESTED·COMMENTED·DISMISSED·모름), 시각, 현재 head 에 달렸는지 | `latestReviews` | 가를 수 없다. 계정만 안다 |
| 마지막 댓글: 계정, 종류, 시각 | `comments(last: 1)` | 가를 수 없다. 댓글이 어느 head 를 보고 쓴 것인지도 알 수 없다 |
| GitHub 이 리뷰를 기다리는 계정·팀 | `reviewRequests` | 가를 수 없다 |

[사실] 리뷰와 댓글은 공유 계정 둘로 달린다. 계정 하나를 Keeper 7명·12명이 같이 쓴다.
그래서 "anyang-keepers 가 2시간 전 COMMENTED" 까지는 말할 수 있고, 그게 어느 Keeper 인지는 말할 수 없다.
판정 댓글 첫 줄의 `by: <Keeper 이름>` 을 읽으면 가를 수 있어 보이지만, 댓글 본문을 글자로 읽는 분류라 쓰지 않는다.
Keeper 단위로 가르려면 Keeper 별 GitHub 신원이 먼저다(RFC keeper-github-apps, D7).
이 절의 안내 조각(`world.pull_requests.intro`)은 "계정 하나를 여러 Keeper 가 같이 쓴다"는 사실을 한 문장으로 적는다.

### 4.6 모양 예시

문구는 `config/prompts/keeper.md` 에 둔다. 아래는 구조를 보이려는 예시이고 최종 문구가 아니다.

```text
### Open Pull Requests
Rows come from the server's GitHub snapshot. One GitHub account is shared by several Keepers, so an account below does not name a Keeper. keeper_pull_requests_list reads every row.
jeong-sik/masc — read 00:27:51Z (43 s ago) · open 89 · checks_failing 8 · changes_requested 10 · conflicting 2 · unreviewed_on_head 37 · draft 19 · checks_running 8 · reviewed_on_head 5 · review_history_incomplete 0 · mergeability not computed 0
- checks_failing (8, showing 5)
  - #39247 [dune build @check] "feat(tui): …" · PR account jeong-sik · base feat/tui-wheel-reader · head 20m · no review on head · requested pangyo-preachers, anyang-keepers
  - #39401 [dune build @check] "fix(keeper): …" · PR account jeong-sik · head 3h · last review pangyo-preachers (User) COMMENTED 2h, older head
- changes_requested (10, showing 5)
  …
Your other open pull requests: #39410 (draft) #39422 (checks running)
```

### 4.7 전체 목록 도구

[제안] Keeper 도구 `keeper_pull_requests_list` 를 더한다.
- 같은 스냅숏(`Repository_pulls.current`)을 읽고, 저장소·묶음·자기 PR 여부로 거른다. 행 모양은 World State 행과 같다.
- checkout 대상 규칙을 적용하지 않는다. 어느 Keeper 든 부르면 모든 저장소 행을 읽는다. World State 는 매 턴 싣는 몫이고, 도구는 Keeper 가 골라 부르는 몫이다.
- GitHub 을 부르지 않는다. 스냅숏이 `Pulls_failed` 이면 그 실패를 그대로 돌려준다.
- 정의는 `config/tools/` 의 TOML 로 둔다.

## 5. GitHub 변화로 깨우나

### 5.1 결정

[제안] **깨운다. 단, 그 PR 의 커밋한 Keeper 한 명만, 세 가지 상태에만.** 스택의 마지막 단계로 두고, 앞 단계의 측정을 본 뒤 운영자가 켤지 정한다(D4).

| 상태 | 깨우나 |
|---|---|
| 자기 PR 의 checks 가 `Checks_failing` | 깨운다 |
| 자기 PR 의 review 결정이 `Review_changes_requested` | 깨운다 |
| 자기 PR 의 mergeable 이 `Conflicting` | 깨운다 |
| 리뷰 요청 | 깨우지 않는다. 공유 계정으로 가서 받을 Keeper 가 하나로 정해지지 않는다. 계정의 Keeper 7명·12명을 다 깨우는 것은 턴만 늘린다 |
| 남의 PR 의 CI 실패 | 깨우지 않는다. 다음 keepalive(600초 이내)의 World State 에 보인다 |
| 새 PR | 깨우지 않는다. 같은 이유 |

[제안] 깨우기는 턴을 여는 것이지, 턴을 막거나 행동을 정해 주는 게이트가 아니다.
깬 턴은 무엇이 바뀌었는지만 받는다. 무엇을 하라는 문장은 싣지 않는다.

### 5.2 왜 커밋한 Keeper 만인가

- [사실] `On_demand` Keeper 는 owner 는 되살리지만 자발 턴은 없다
  (`lib/keeper/keeper_activation_mode.ml:3-4`, `lib/keeper/keeper_lifecycle_gate_env.ml:28-29`). 자극이 없으면 깨지 않는다.
  이런 Keeper 의 PR 이 빨개지면 지금은 아무것도 그 Keeper 를 부르지 않는다. 이 틈은 World State 만으로는 안 메워진다.
- `Autonomous` Keeper 는 600초 안에 World State 로 보게 된다. 깨우기가 더해 주는 것은 최대 10분이다.
  CI 중앙값 14분(§3.1)에 비하면 작다. 그래서 측정을 먼저 한다(§9 M3).
- 커밋한 Keeper 판정은 이름 비교 하나다. 이름은 누구나 커밋에 적을 수 있으므로 권한의 근거로 쓰지 않는다
  (RFC-0465 `keeper_of_author` 주석). 잘못 붙으면 한 Keeper 가 한 번 더 깰 뿐이다.

### 5.3 경로 — 보낸 깨우기를 durable 하게 기록한다

변화를 직전 스냅숏과의 차이로 잡으면 두 가지가 틀어진다.
[사실] event queue 는 같은 자극이 아직 큐에 있을 때만 중복을 막는다(`lib/keeper_runtime/keeper_event_queue.mli:391-425`).
ACK 된 뒤 같은 변화가 다시 보이면 다시 들어간다. CI 재실행이나 mergeable 이 UNKNOWN 을 오가는 것이 그 예다.
또 넣기가 실패했을 때 다음 비교는 "변화 없음"을 보고 깨우기를 잃는다. constitution 의 `failure_keeps_evidence` 와 어긋난다.

[제안] 그래서 차이가 아니라 **상태와 보낸 기록**을 비교한다.

1. **기록 저장소.** `<base-path>/.masc/` 아래 durable 저장소 하나에 "이 깨우기를 보냈다"를 쓴다.
   키는 `(repo_slug, number, head_oid, state)` 이고, 값은 받은 Keeper 와 보낸 시각이다.
   ```ocaml
   type pull_request_wake_state = Checks_failing_on_head | Changes_requested_on_head | Conflicting_on_head
   type pull_request_wake_key =
     { repo_slug : string; number : int; head_oid : string; state : pull_request_wake_state }
   ```
   이 저장소는 RFC every-durable-store-has-one-boot-policy 의 표에 부팅 정책과 격리 방법을 등록한다.
   기록이 없으면 깨우기가 사라지거나 두 번 가므로, "없으면 durable truth 가 손상되는 경우에만 새 상태를 더한다"는 기준을 채운다.
2. **보낼 것 고르기.** producer 가 `Pulls_read` 를 `publish` 한 뒤, 그 스냅숏에서 커밋한 Keeper K 가 있고
   세 상태 중 하나인 PR 마다 키를 만든다. 기록에 그 키가 없으면 K 의 event queue 에 `Pull_request_changed` 를 넣는다.
3. **넣기가 성공한 뒤에만 기록을 쓴다.** `enqueue` 가 `Error` 면 기록을 쓰지 않는다. 다음 읽기에서 같은 키가 다시 보내질 후보가 된다.
   넣기는 성공하고 기록 쓰기가 실패하면 다음 읽기에서 한 번 더 간다. 잃는 것보다 한 번 더 가는 쪽으로 틀린다.
4. **비교할 수 없는 상태.** 저장소가 `Pulls_read` 가 아니면(`Pulls_not_read`, `Pulls_failed`, reader 준비 안 됨) 그 저장소는 비교하지 않는다.
   "변화 없음"이 아니라 "비교 안 함"이다. 기록도 지우지 않는다. 다음 `Pulls_read` 에서 그 사이에 생긴 상태를 그대로 본다.
   재시작 뒤에도 기록이 남으므로 이미 보낸 깨우기는 다시 가지 않고, 꺼져 있던 동안 빨개진 PR 은 깨운다.
5. **같은 head 의 같은 상태는 한 번이다.** CI 를 다시 돌려 또 실패해도, mergeable 이 UNKNOWN 을 거쳐 다시 CONFLICTING 이 돼도,
   head 가 같으면 키가 같아 다시 가지 않는다. 새 커밋이 올라오면 head 가 바뀌어 새 키가 된다.
6. **기록 치우기.** 한 저장소의 `Pulls_read` 에 없는 PR(병합·종료)의 기록은 지운다. 시간이 지났다는 이유로는 지우지 않는다
   (constitution `no_wall_clock_death`). `Pulls_read` 는 커서를 끝까지 따라간 전체 목록이라 이 판단의 근거가 된다.
7. **처음 켤 때.** 기록이 비어 있으므로, 켜는 순간 세 상태에 있는 Keeper PR 마다 한 번씩 간다.
   [사실] 커밋한 Keeper 가 붙은 열린 PR 은 09-27 00:20:58Z 에 8개, 17:53Z 에 7개였다. 많아야 그만큼이다.

자극과 사유:

```ocaml
(* Keeper_event_queue.payload 에 추가 *)
| Pull_request_changed of pull_request_wake_key
```

- 긴급도는 `Normal` 이다. [사실] `Immediate` 는 운영자 명령 같은 지연에 민감한 신호, `Normal` 은 Board 글·멘션,
  `Low` 는 background polling 과 telemetry 넛지다(`lib/keeper_runtime/keeper_event_queue.mli:18-21`).
  이 자극은 polling 에서 나오지만 Keeper 자신의 일에 생긴 바깥 변화라 Board 글과 같은 자리로 본다.
- `Keeper_heartbeat_stimulus_intake.event_queue_trigger_of_stimulus`(`lib/keeper/keeper_heartbeat_stimulus_intake.ml:210-251`)에
  arm 을 더해 새 trigger 를 낸다. `turn_reason` 에 `Own_pull_request_changed_pending` 을 더한다.
  `turn_reason_to_string` 과 모든 exhaustive match 가 따라온다.
- Autonomous Trigger 절이 이 사유와 PR 번호·상태를 보여 주고, `Pull_requests` 절이 그 PR 행을 담는다.

## 6. Task 목록과 Goal

### 6.1 Task 행에 제목

[제안] 행은 한 줄이고 폭이 정해져 있다.

| 칸 | 값 |
|---|---|
| id, 우선순위, 나이(일) | `task-1787 P2 3d` |
| 제목 | `short_preview ~max_len:80`. [사실] 라이브 todo 제목 중앙값 98바이트, p90 135바이트 |
| 만든 이 | `created_by` |
| 이어진 Goal | 진행 중인 Goal 에 이어져 있으면 그 Goal 제목(짧게) |
| 마지막 반납 | `handoff_context` 가 있으면 `updated_by` 와 `reason`(짧게). [사실] todo 84개에 있다(`lib/types/types_core.ml:542-551`) |

"누가 이미 하고 있나"는 claimable Task 에는 해당하지 않는다(맡은 사람이 없는 Task 만 claimable 이다).
대신 누가 왜 놓았는지가 같은 물음에 답한다.

### 6.2 "관련 있는 것 먼저"의 뜻

[제안] 관련은 **Keeper 와 Task 사이에 타입으로 기록된 관계**로만 정한다. 제목이나 관심사를 글자로 맞춰 보지 않는다.
보여 주는 순서는 아래 사전식 순서다.

1. 진행 중인 Goal(Executing·Verifying)에 이어진 Task 먼저. Goal 은 운영자와 Keeper 가 "지금 이것을 진전시킨다"고 선언한 것이다.
2. 우선순위 높은 것 먼저. Task 작성자가 선언한 값이다.
3. **최근에 만든 것 먼저.** [사실] 48시간 안에 만든 Task 35개 중 27개가 끝났거나 진행 중이다.
   14일 넘은 todo 는 94% 이고, 최근 7일 done 102건 중 만든 지 14일 넘은 것은 2건이다.
   오래된 것부터 보이면 운영자 결정에 막힌 같은 Task 가 늘 목록 맨 위에 보인다.
4. id.

**읽기 실패.**
- `created_at` 은 문자열이다(`lib/types/types_core.mli:226`). 경계에서 한 번 시각으로 읽는다.
  못 읽은 Task 는 3번 순서에서 읽은 Task 뒤에 오고, 행에 "만든 시각을 못 읽음"이 보인다. 0 이나 지금 시각으로 채우지 않는다.
- Goal 링크는 `read_goal_task_links_r`(Result)로, Goal 은 `Goal_store.list_goals_result` 로 읽는다.
  [사실] 지금 `build_task_goal_index_for_config` 는 못 읽은 링크 파일을 `[]` 로 바꾼다(`lib/workspace/workspace_goal_index.ml:598-599`).
  이 절은 그 함수를 쓰지 않는다. 둘 중 하나라도 `Error` 면 1번 순서를 빼고 2~4번으로만 줄 세우고, "Goal 링크를 못 읽어 Goal 순서를 쓰지 않음: <이유>" 한 줄을 쓴다.

Keeper 한 명에게만 해당하는 관계는 지금 없다.
- [사실] `task.skills`(Task 가 요구하는 Skill)는 Keeper 의 Skill 과 타입으로 맞출 수 있는 유일한 칸인데, todo 595개 모두 비어 있다.
- 역할·관심사로 맞추는 것은 글자 분류라 하지 않는다.
- Task 를 만들 때 Skill 을 붙이게 할지는 운영자 결정이다(D5). 붙기 시작하면 "이 Keeper 가 가진 Skill 을 요구하는 Task"를
  1번 앞에 두는 것을 따로 제안한다.

### 6.3 claim 이 고르는 순서는 그대로

[제안] 이 RFC 는 보여 주는 순서만 바꾼다. task_id 없이 부르는 claim 이 쓰는 `Workspace.claim_next_r` 은
지금처럼 우선순위 안에서 먼저 만든 것부터 고른다(`lib/workspace/workspace_task_schedule.ml:145`).
외부 에이전트의 `masc_claim_next`(`lib/task/tool_task_handlers.ml:652`)도 그대로다.

그러면 #29101 이 맞춰 둔 "읽는 첫 행 = task_id 없는 claim 이 잡을 첫 행"은 더 이상 참이 아니다.
[제안] Task 목록 조각이 이 차이를 한 문장으로 적는다. "task_id 없이 claim 하면 이 목록이 아니라 우선순위 안에서 먼저 만든 순서로 고른다."
`keeper_world_observation_inputs.ml:214-217` 의 #29101 주석은 새 정렬의 이유로 바꿔 쓴다.

Keeper 쪽 task_id 없는 claim 을 없앨지는 D2 로 둔다. 이 RFC 의 스택에는 넣지 않는다.

| | 좋은 점 | 대가 |
|---|---|---|
| D2 를 하지 않음 (이 RFC 기본) | claim 동작이 바뀌지 않는다. 외부 에이전트와 Keeper 가 같은 규칙을 쓴다 | Keeper 가 읽는 첫 행과 task_id 없는 claim 이 잡는 행이 다르다. 문장 하나로 알릴 뿐이다 |
| D2 를 함 (Keeper 의 `keeper_task_claim` 에 task_id 필수) | Keeper 는 늘 자기가 읽은 행을 골라 잡는다. [사실] 48시간 동안 스스로 다음 일을 집은 `task_claim_next` 는 2번이었고 둘 다 몇 분 안에 반납됐다. task-593 은 이 경로로 여러 Keeper 사이를 돌았다 | 도구 스키마와 `config/prompts/keeper.md:43`, `work-intake` 합성 문구를 같이 바꾼다. 오래된 todo 를 순서대로 치우는 경로가 Keeper 쪽에서 사라진다 |

### 6.4 Goal 은 모두에게

[제안] Active Goals 절은 진행 중인 Goal 을 모든 Keeper 에게 보여 준다. "Task 가 없으면 Goal 도 없음"을 지운다.

Active Goals 는 `ordered` 의 맨 앞 절이다(`lib/keeper/keeper_context_layers.ml:33-35`). 이 절이 자주 바뀌면 뒤따르는 모든 절의 prefix cache 가 깨진다.
그래서 두 곳으로 나눈다.

| 어디 | 무엇 | 언제 바뀌나 |
|---|---|---|
| Active Goals (맨 앞) | 제목, 성공 조건, `Verifying` 표시(지금과 같다), 이 Keeper 가 쥔 Task 가 이 Goal 에 이어져 있으면 `yours` | Goal 이 바뀔 때, 이 Keeper 가 Task 를 잡거나 놓을 때. 잡고 놓을 때는 Current Task 절(둘째 절)도 어차피 바뀐다 |
| Namespace State (다섯째 절) | Goal 마다 이어진 Task 수(todo, 진행 중)와 진행 중 Task 를 쥔 Keeper 이름 | 이어진 Task 가 움직일 때. Namespace State 는 지금도 턴마다 바뀐다(실행 중 fiber 수) |

진행 중 Task 를 쥔 Keeper 이름이 "누가 이미 하고 있나"에 대한 Goal 쪽 답이다.

### 6.5 한도

- Task 행은 지금처럼 10행(`claimable_task_render_budget_rows`)이다. 7+3 으로 나누던 것은 한 목록으로 합친다.
  행 약 200바이트 × 10 ≈ 2KB. 나머지 수는 지금 조각(`world.namespace_state.claimable_more`)이 그대로 말한다.
- Goal 행도 10행까지다. 넘치면 머리에 "N개 중 10개 보임"을 쓰고 `masc_goal_list` 를 안내 조각에 적는다.
  [사실] 라이브 진행 중 Goal 9개, 제목 70~131바이트. 행 약 250바이트 × 9 ≈ 2.2KB.

## 7. 지우는 것 (hard cut)

호환 reader, 옛 이름 별칭, "예전에는" 주석을 남기지 않는다. 지운 이름을 부르는 테스트는 같은 PR 에서 지우거나 새 동작으로 바꾼다.

| 지우는 것 | 위치 (부르는 곳 포함) | 이유 |
|---|---|---|
| `Server_repository_pulls` 안의 타입·투영 | `lib/server/server_repository_pulls.ml(i)` → `Repository_pulls`. 부르는 곳: `server_routes_http_routes_repositories.ml:527`, `server_h2_gateway.ml:1249`, `server_bootstrap_maintenance.ml:544` | §3.3. 옛 이름 별칭 없음 |
| 칸 하나를 못 읽으면 PR 행을 버리는 decode | `lib/server/server_repository_pulls.ml:355-357` | §3.2 의 `Unrecognized` 로 바뀐다 |
| Task id 만 싣는 JSON 행 | `lib/keeper/keeper_unified_prompt.ml:1769-1777` | §6.1 행으로 바뀐다 |
| 오래된 7 + 최신 3 나누기, `claimable_task_newly_added_rows`, OCaml 안의 `"  Newly added (most recent):\n"` | `:1201-1203`, `:1799-1818` | 순서가 최근 것 먼저라 따로 뽑을 필요가 없다. 문장은 OCaml 에 있으면 안 된다 |
| World State 쪽 claim 순서 정렬 | `lib/keeper/keeper_world_observation_inputs.ml:214-226` | §6.2 의 보여 주는 순서로 바뀐다. `claim_next_r` 의 정렬은 그대로 둔다 |
| Task 에 이어진 Goal 만 고르는 거르기 `active_goal_summaries_for_task` | `lib/keeper/keeper_unified_prompt.ml:1290-1336`, `.mli:96`, `.mli:169`. 부르는 곳: `lib/keeper/keeper_unified_turn.ml:751`, `lib/dashboard/dashboard_http_keeper_snapshot.ml:163`, `test/test_keeper_goal_phase_projection.ml`(8곳) | §6.4 |
| `turn_reason.Task_backlog` | `lib/keeper_contract/keeper_world_observation_turn_types.ml:79-82`, `lib/keeper/keeper_world_observation.ml:322`, `:1789-1806` 과 이를 매치하는 곳 | 모든 keepalive 에 붙고 턴 여부를 바꾸지 않는다. backlog 는 Namespace State 에 사실로 남는다 |
| 위를 지운 뒤 부르는 곳이 없는 `claimable_drives_wake`, `failed_drives_wake`, `actionable_signal_present` | `lib/keeper/keeper_world_observation.ml:1608-1620`, `test/test_keeper_raw_task_signal_wake.ml:30` | [사실] `actionable_signal_present` 는 지금도 lib 안에서 부르는 곳이 없고 이 테스트만 부른다 |
| `Surface_ref.Webhook`, `Keeper_external_attention.Webhook` | `lib/keeper/surface_ref.ml:24`, `:36`, `:64`, `:110`, `lib/keeper/keeper_external_attention.ml:49`, 매치하는 곳(`keeper_input_speaker.ml:216`, `keeper_counterpart_observation.ml:35`, `:65`, `keeper_chat_operation_payload.ml:179`, `keeper_world_observation_message_scope.ml:370`, `:464`) | 만드는 곳이 없다. 이 RFC 는 GitHub 을 읽기로 받는다 |
| 저장소 기록의 `keepers` 칸 | `lib/repo_manager/repo_manager_types.mli:29`, `lib/repo_manager/repo_store.ml:25`, `:77`, `:127`, `:505`, `lib/server/server_routes_http_routes_repositories.ml:109`, `:255`, `lib/tui_decode.mli:969` | "어느 Keeper 가 어느 저장소를 보나"가 Keeper 쪽 `watch_repositories` 로 옮겨 간다. [사실] `repo_store.ml:77` 이 이 키를 필수로 읽으므로, 라이브 `repositories.toml` 에서 키를 먼저 빼야 한다. 그래서 이 스택과 떼어 별도 PR 로 한다 |
| TUI 쪽 webhook 표면 | `bin/masc_tui_keeper_chat_history.ml:35`(자체 variant), `:320`, `:355-357`(`"webhook"` decoder). 테스트: `test/test_tui_chat_surface_mirror.ml:33`, `:44`, `test/test_surface_ref.ml:34`, `test/test_tui_keeper_chat_history.ml:980-984`, `test/keeper_continuation_channel/test_keeper_continuation_channel.ml:65` | 서버 쪽을 지운 뒤 남기면 호환 reader 가 된다 |

`Webhook` 근거: [사실] 라이브 저장소 JSON·JSONL 에 `webhook` 값 0건(tool_calls·logs·raw-traces·tool_blobs·turn-records 제외 검색).
Telegram RFC-0384 도 webhook 방식을 빼고 있다.

`Task_backlog` 를 지우면 system log 의 `keepalive turn scheduled` 사유에서 `task_backlog` 가 사라진다.
이 문자열을 세는 대시보드나 스크립트가 있으면 같은 PR 에서 고친다.

RFC-0465 는 대체하지 않는다. 그 RFC 의 서버 읽기와 Keeper 귀속 규칙에 소비자를 더 붙이는 것이다.
TUI 표시 부분은 열린 #38801 이 이미 다른 RFC 로 넘긴다.

## 8. 구현 스택

작은 PR 로 나눈다. 앞 PR 이 병합된 뒤 다음 PR 을 main 기준으로 연다.

| # | 내용 | 확인 |
|---|---|---|
| S1 | `Repository_pulls` 모듈로 타입·`keeper_of_author`·`github_slug_of_remote`·투영을 옮기고 `publish`/`current` 를 둔다. 읽기 fiber·자격은 `masc_server` 에 남긴다. HTTP 두 곳이 `Repository_pulls.current` 를 읽는다. 동작 변화 없음 | 기존 `server_repository_pulls` 테스트가 그대로 통과한다. 두 HTTP 경로의 JSON 이 옮기기 전과 바이트 단위로 같다(기록한 스냅숏 fixture 로 비교) |
| S2 | GraphQL 에 §3.2 칸을 더하고, 모든 칸의 모르는 값을 `Unrecognized` 로 읽는다 | 실제 응답을 줄여 만든 fixture 가 기대한 타입 행으로 decode 된다. 모르는 check conclusion, `Team` reviewer, `null` actor, `Mannequin` actor 를 넣은 fixture 에서 PR 행이 빠지지 않고 그 칸만 `Unrecognized`·`Actor_absent` 가 된다. 리뷰·리뷰 요청 목록이 잘린 fixture 는 `hasNextPage` 를 그대로 싣는다. PR 본문에 `rateLimit { cost }` 측정값을 적는다 |
| S3a | checkout 측정 행에 `row_remote` 를 더한다(Docker·Micro_vm 은 호스트, Remote_ssh 는 endpoint probe 가 같이 읽는다) | remote 가 있는 checkout, remote 가 없는 checkout, 읽기 실패 checkout 을 담은 fixture 가 세 가지 값을 낸다. Repository freshness 절 렌더는 바뀌지 않는다 |
| S3b | `Github_slug.t` 와 `watch_repositories` 칸: TOML 파서·필드 종류 목록·profile·meta·저장 쓰기, config endpoint 허용 칸과 저장 전 파싱, `GET` 응답, TUI 편집 표, 웹 대시보드 패널, `masc_keeper_up` 인자. `github_slug_of_remote` 가 `Github_slug.t` 를 낸다 | 왕복: `watch_repositories = ["jeong-sik/masc", "jeong-sik/masc"]` 를 읽고 저장하면 `["jeong-sik/masc"]` 가 다시 읽힌다. `"jeong-sik"`, `"a/b/c"`, `"jeong-sik/masc.git"`, `" jeong-sik/masc"` 는 각각 그 keeper 파일의 로드 오류이고 오류가 틀린 값을 말한다. 같은 값을 config endpoint 로 보내면 400 이고 저장된 값은 그대로다. TUI·대시보드는 `GET` 의 `workspace.watch_repositories` 를 그린다 |
| S4 | `layer_id.Pull_requests`, `placement`·순서·상한, `config/prompts/keeper.md` 의 `### world.pull_requests.*` 조각, `keeper_unified_turn.ml` 과 대시보드 미리보기 배선, checkout 으로 대상 고르기 | fixture World State: CI 빨강 PR, CR PR, head 에 리뷰 없는 초록 PR, 옛 head 에만 승인이 있는 PR, CI 가 빨간 draft, 리뷰 목록이 잘리고 본 범위에 현재 head 리뷰가 없는 초록 PR, `Pulls_failed` 저장소, 이 Keeper 가 커밋한 PR 6개(상한보다 많음)를 담은 스냅숏. 확인하는 것은 구조다(묶음 머리의 "N개 중 k개", 행 번호, 순서, `yours`, 실패 줄). 문구는 고정하지 않는다. 자기 PR 6개가 모두 보이고 남의 행은 5개다. 빨간 draft 는 묶음에 들지 않는다. 잘린 리뷰 목록의 PR 은 `Unreviewed_on_head` 에 들지 않고 `Review_history_incomplete` 수로 센다. checkout 도 선언도 없는 Keeper 는 자기 PR 줄만 받는다. checkout 이 없고 `watch_repositories` 에 그 저장소를 적은 Keeper 는 묶음 행을 받는다. checkout 측정이 `Error` 인 Keeper 는 이유 줄, 선언한 저장소의 행, 자기 PR 줄을 받는다. 선언했지만 스냅숏에 없는 slug 는 그 한 줄을 받는다. 새 조각이 모두 그려진다 |
| S5 | `keeper_pull_requests_list` 도구 | 도구 결과가 같은 스냅숏의 행과 같다. checkout 없는 Keeper 도 모든 행을 읽는다. `Pulls_failed` 는 실패로 돌아온다 |
| S6 | Task 행 칸과 보여 주는 순서, Goal 을 모두에게, Goal 진행 줄을 Namespace State 로 | fixture backlog: 진행 중 Goal 에 이어진 P3 Task, 오래된 P1, 새 P1, `created_at` 을 못 읽는 Task. 목록 순서가 §6.2 대로다. 같은 fixture 에서 `claim_next_r` 은 오래된 P1 을 고른다(바뀌지 않음). Goal 링크 파일을 못 읽는 fixture 에서 이유 줄이 나오고 Goal 순서가 빠진다. Task 없는 Keeper 의 World State 에 진행 중 Goal 이 나온다 |
| S7 | §7 의 `Task_backlog`, 쓰지 않게 된 함수, `Webhook`(서버·TUI) 제거 | exhaustive match 가 컴파일을 통과한다. 지운 이름이 lib·bin·test 에서 `rg` 로 0건이다 |
| S8 | (D4 가 켜면) 깨우기 기록 저장소, `Pull_request_changed` 자극, `Own_pull_request_changed_pending` | Keeper K 가 커밋한 PR 이 `Checks_failing` 인 스냅숏 → K 에게 자극 1개와 기록 1개. 같은 스냅숏을 다시 넣으면 0개. 넣기를 `Error` 로 만든 경우 기록이 없고, 다음 스냅숏에서 다시 1개. `Pulls_failed` 사이에 끼어도 기록이 지워지지 않는다. 기록을 남긴 채 재시작하면 0개. head 가 바뀌면 1개. PR 이 목록에서 빠지면 그 기록이 지워진다. 다른 Keeper 에게는 0개 |

S1 → S2 → S4 → S5 는 차례로 의존한다. S3a 와 S3b 는 main 기준으로 따로 가고 S4 앞에 병합된다. S3b 는 S1 이 `masc` 쪽으로 옮긴 `github_slug_of_remote` 를 `Github_slug.t` 를 내도록 바꾸므로 S1 뒤다. `Github_slug` 는 S3b 가 새로 만든다(지금 같은 이름의 모듈은 없다). S6 은 main 기준으로 따로 간다.
S7 은 S6 뒤, S8 은 S4 뒤다.

## 9. 배포 뒤 확인

코드 확인은 §8 이 맡는다. 여기는 라이브에서 확인하는 것과 효과를 재는 것이다.
잰 값은 판단 재료다. 어떤 값도 런타임 기준값이 되지 않는다.

**L1 — 빨간 PR 이 World State 에 보인다 (S4 배포 뒤)**

1. `GET /api/v1/repositories/pulls` 에서 `checks = failing` 인 masc PR 번호 하나를 고른다.
2. masc checkout 이 있는 Keeper 하나와, checkout 없이 `watch_repositories` 에 masc 를 적은 Keeper 하나(배포 뒤 운영자 단계, §4.1)의 다음 턴 기록(turn-records 의 `dynamic_context` 블록)을 읽는다.
3. 그 번호가 `checks_failing` 묶음 아래 있거나, 묶음 상한을 넘었으면 머리의 "N개 중 k개"의 N 에 들어 있다.
4. masc checkout 도 선언도 없는 Keeper 의 같은 시각 턴 기록에는 이 절의 묶음 행이 없다.

**L2 — 아직 못 읽었을 때 말한다**
배포 재시작 직후 첫 읽기(최대 60초) 전에 돈 턴의 기록에서, 이 절이 "서버가 뜬 뒤 아직 읽지 않음" 줄을 내고
묶음 행을 그리지 않는지 본다. 라이브 설정을 바꾸지 않고 확인할 수 있는 실패 모양이 이것이다.
나머지 실패 모양(`Pulls_failed`, reader 없음, checkout 읽기 실패)은 S4 fixture 가 맡는다.

**측정 (배포 전 7일과 배포 뒤 7일)**

| # | 무엇 | 어디서 |
|---|---|---|
| M1 | 묶음에 든 PR 중 24시간 안에 현재 head 에 리뷰가 달린 비율 | GraphQL, 매일 같은 시각 |
| M2 | CI 빨강·충돌 PR 에 Keeper 계정 커밋이 달린 수 | GraphQL `commits` |
| M3 | 커밋한 Keeper 가 있는 PR 에서, check run 이 실패로 끝난 시각부터 그 Keeper 의 다음 커밋까지 걸린 시간. activation mode 별로 나눈다 | GitHub check run `completedAt`(서버 시각)과 다음 커밋. 스냅숏은 메모리에만 있어 과거를 모르므로, 배포 전 값도 GitHub 에서 다시 만든다 |
| M4 | 하루 `keeper_task_claim` 수와 claim 뒤 반납까지 걸린 시간 | task events |
| M5 | World State 바이트 중앙값 변화, memory recall 바이트와 비교 | turn-records |
| M6 | Keeper 가 부른 `gh pr view`·`gh pr list`·`gh pr checks` 하루 수 | 도구 호출 원장 |

D4(깨우기)는 S4 만 배포된 7일의 M3 을 보고 정한다. `Autonomous` Keeper 가 이미 한 keepalive 안에 반응하면, 깨우기는 `On_demand` Keeper 몫만 남는다.

## 10. 열린 PR 과 겹치는 곳

2026-09-27 17:5xZ 에 열린 PR 42개의 파일 목록으로 다시 확인했다. 09-27 에 겹쳤던 #39377(`keeper_unified_turn.ml`), #39401(`keeper_prompt.ml`),
#39239(event queue 저장), #39244(취소 대기열 2/3)는 그 사이 병합됐다. 해당 단계는 병합된 main 위에서 연다.

| PR | 겹치는 파일 | 영향 |
|---|---|---|
| #38801 TUI measured home | `bin/masc_tui_repository_pulls.ml` 삭제, `docs/rfc/RFC-0465-…` 머리 수정 | S1 은 OCaml 타입을 옮기지만 HTTP JSON 은 그대로라 TUI decode 와 부딪히지 않는다. 이 RFC 는 RFC-0465 파일을 고치지 않는다. #38801 이 먼저 병합되면 스냅숏 소비자는 World State·도구·HTTP 만 남는다 |
| #39442 예약 문구 | `config/prompts/keeper.md` | S4 가 같은 파일에 `### world.pull_requests.*` 조각을 더한다. 고치는 절이 달라 글자 충돌은 작다. S4 는 #39442 뒤에 연다 |
| #39392 backlog snapshot 인코딩 | workspace backlog | S6 과 파일이 가깝다. 파일 목록상 직접 겹침은 없다 |

`lib/keeper/keeper_context_layers.*`, `lib/keeper/keeper_unified_prompt.ml`, `lib/server/server_repository_pulls.*`,
`lib/keeper/keeper_sandbox_control.*`, `lib/keeper_runtime/keeper_event_queue*` 를 고치는 열린 PR 은 없었다.

## 11. 운영자 결정

2026-09-28 운영자가 모두 정했다. D1 은 제안과 다르게, D4 는 측정 뒤로 정했다. 나머지는 제안대로다.

| # | 물음 | 결정 (2026-09-28, 운영자) |
|---|---|---|
| D1 | 묶음 행을 누구에게 보이나. [사실] 조사 시각에 Keeper 11명이 checkout 0개였고, 그중 masc PR 을 판정하는 Keeper 가 있다 | checkout 관계 + Keeper 별 저장소 선언(`watch_repositories`). §4.1 |
| D2 | Keeper 의 task_id 없는 claim 을 없애나 (§6.3 표) | 제안대로: 이 RFC 에서는 하지 않는다 |
| D3 | 묶음당 PR 행 상한 | 제안대로: 5 (약 3.8KB). 자기 PR 은 세지 않는다 |
| D4 | 자기 PR 상태로 커밋한 Keeper 를 깨우나 (S8) | S4 만 배포된 7일의 M3 을 본 뒤 결정한다. 그때까지 S8 은 열지 않는다 |
| D5 | Task 를 만들 때 Skill 을 붙이게 하나 (지금 todo 595개 모두 비어 있다) | 제안대로: 붙기 시작하면 Skill 관계를 순서 맨 앞에 두는 것을 따로 제안한다 |
| D6 | PR 을 읽는 계정을 Keeper 공유 계정(anyang-keepers)에서 떼나 | 제안대로: 지금 계정 유지. rate limit 은 기존 `Rate_limited` 경로가 받는다 |
| D7 | Keeper 별 GitHub 신원(RFC keeper-github-apps)을 진행하나 | 제안대로: 이 RFC 는 계정 단위로 동작하고, 리뷰 계정 종류로 순서를 정하지 않는다. 신원 전환은 그 RFC 에서 따로 정한다 |

## 12. 하지 않는 것

- PR 을 Keeper 에게 배정하지 않는다. 묶음·순서는 보여 주는 순서일 뿐이다.
- Task claim 이 고르는 순서를 바꾸지 않는다.
- R1 초록 차선, HOLD, 병합 보류 같은 운영 규칙을 런타임에 넣지 않는다. 그 규칙은 Board 와 Keeper 가 가진다.
- PR 제목·본문·댓글·판정 줄, checkout 경로·이름을 글자로 읽어 분류하지 않는다.
- 새 cooldown, cap, 예약, "몇 시간 넘으면" 같은 시간 기준을 두지 않는다.
- 서버가 PR 을 만들거나 고치거나 병합하지 않는다. 읽기만 한다.
- Memory OS recall 의 크기와 순위는 다루지 않는다(§1.5).
- Board attention 의 관심사 판정은 다루지 않는다.

## 13. 확인하지 못한 것

- `mergeable` 이 한 시점에 80/91 이 `unknown` 이고 7분 뒤 0/89 인 이유. 서버 읽기 계정과 직접 조회 계정이 다르다는 점,
  main 이 자주 움직인다는 점이 후보다. 재지 않았다.
- figma-mcp·wkbl 저장소의 쿼리 cost. masc 만 쟀다.
- 조사 시각에 checkout 이 있던 Keeper 13명 중 누가 masc checkout 을 가졌는지. 캡처에 remote 가 없다. S3a 뒤에야 셀 수 있다.
- Remote_ssh Keeper 의 checkout remote 를 endpoint probe 가 같은 시간 안에 읽을 수 있는지.
- `Manual` Keeper 가 event queue 자극으로 깨는지. `Manual` 은 owner 를 되살리지 않는다(`keeper_activation_mode.ml:3`).
  `On_demand` 는 owner 를 되살리므로 자극으로 깬다고 읽었지만, 턴까지 이어지는 경로를 끝까지 따라가지는 않았다.
- World State 를 읽은 Keeper 가 실제로 PR 을 더 고르는지. 이것은 §9 의 M1·M2 로만 알 수 있다.
- 측정값 일부(`gh` 명령 수, "없음·기다림" 문구 비율)는 정규식 집계라 과다·과소가 있다.
