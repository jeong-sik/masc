---
rfc: "keeper-wakes-when-a-pr-check-finishes"
title: "PR 의 check 가 끝나면 Keeper 를 깨우는 감시"
status: Draft
created: 2026-11-11
updated: 2026-11-11
author: claude
supersedes: []
superseded_by: null
related: ["0379", "0465", "keeper-world-state-shows-open-work", "keeper-github-apps", "per-keeper-github-cli-identity", "keeper-async-fleet-continuity", "execute-background-through-the-tool-outbox", "wake-signal-diet"]
implementation_prs: []
---

# RFC: PR 의 check 가 끝나면 Keeper 를 깨우는 감시

이 문서는 설계 후보와 재는 법을 적는다. (나)의 구현은 Draft PR #51338, #51339, #51340 에 있다.
시각은 따로 적지 않으면 UTC 다. 코드 좌표는 `origin/main` `0cdf57159663` 에서 읽은 값이다.

## 0. 요약

- **문제.** Keeper 는 PR 의 check 를 기다리느라 Execute 하나(`sleep` 반복, `…/check-runs` 읽기)를 쥐고 턴을 연 채 있다. 11-08T05:40Z~11-11T05:40Z(72시간)에 이런 60초 이상 호출이 308건, 18.946시간이다. 같은 길이의 앞 창은 184건, 8.925시간이었다.
- **지금 코드.** 서버가 깨워 주는 것은 Actions run 하나가 끝날 때(`until_github_run`)뿐이다. PR head 가 바뀔 때(RFC-0379 §6.6 `Pull_heads`)와 자기 PR 의 check 가 실패할 때(world-state RFC §5)는 제안이고 코드에 없다. 어느 쪽도 "check 가 끝났다"로 깨우지 않는다.
- **후보.** (가) `Pull_heads` 감시의 사건에 check 완료를 더한다. (나) commit 하나의 check 를 기다리는 감시를 새로 둔다. (다) 읽기를 서버 한 곳으로 모은다. (나)와 (다)를 묶는 쪽을 정석으로 보고(§4.5), "끝"은 B′(체크 run 이 모두 끝남)로 정했다(§7).
- **측정으로 알게 된 것.** ① 기다림의 비용은 GitHub 읽기가 아니라 Keeper 시간이다. 읽기는 어림 711번/72시간이다. ② "check 가 끝났다"는 한 사건이 아니다. 같은 commit 의 `statusCheckRollup.state` 가 질의 모양에 따라 다르고, 뒤따르는 job 은 앞 job 이 끝나는 초에 만들어진다. ③ 필수 check 만 거르려면 "이름마다 최신 run" 을 고르는 규칙을 우리가 가져야 한다.
- **사용자가 정할 것.** 후보, "끝"의 뜻, 읽기 예산의 주인이다(§7).

## 1. 배경 (측정)

### 1.1 긴 Execute 가 check 를 기다린 시간

창 A 는 11-08T05:40Z~11-11T05:40Z, 창 B 는 11-07T10:20Z~11-10T10:20Z 다. 둘 다 72시간이다.
출처는 창 A 가 #51284 의 `docs/evidence/tool-efficiency-1111-2026-11/result-github-wait-shapes-2026-11-08T05-40_11-11T05-40.json`, 창 B 가 `docs/evidence/tool-efficiency-1110-2026-11/result-github-wait-shapes-2026-11-07T10-20_11-10T10-20.json` 이다.
모양은 명령 글자로 가른다(`github_wait_shapes.py` 의 `shape_of`). 측정용이고 제품 규칙이 아니다.

| | 창 B | 창 A |
|---|---:|---:|
| Execute 호출 | 61,128 | 89,771 |
| Execute 중 `run_in_background` 를 쓴 호출 | 77 | 124 |
| 60초 이상 Execute | 675 | 1,181 |
| 60초 이상 중 `run_in_background` 를 쓴 호출 | 0 | 0 |
| 60초 이상 중 GitHub 를 기다리는 호출 | 517건, 30.839 h | 926건, 61.342 h |
| `pr_checks` (`gh pr checks`·`view`·`status`) | 112건, 4.963 h | 168건, 8.615 h |
| `commit_checks` (`/commits/<sha>/check-runs`·`status`·`check-suites`) | 72건, 3.962 h | 140건, 10.331 h |
| 둘의 합 | 184건, 8.925 h | 308건, 18.946 h |

- 합 18.946 h 는 창 A GitHub 기다림 61.342 h 의 30.9% 다. 72시간으로 나누면 평균 0.263개가 동시에 붙들려 있다.
- 창 A 는 창 B 의 2.12배다. 두 창의 Keeper 와 일이 달라서 이 증가를 어떤 변경의 효과로 읽지 않는다.
- 같은 Keeper 의 채팅 작업이 큐에서 기다린 시간과의 겹침은 모든 60초 이상 Execute 로 쟀다(`queue_wait_overlap.py --hold-s 60`, 창 A, #51284 의 `result-queue-wait-overlap-…json`). 1,183호출 74.214 h 중 15.519 h(20.9%)가 겹쳤다. 위 표의 60초 이상 1,181건과 2건 다르다. `github_wait_shapes.py` 는 행의 `ts` 가 창 안인 호출을 세고 `queue_wait_overlap.py` 는 호출 구간이 창과 닿는 호출을 센다(#51284 README). 이 RFC 는 check 기다림만의 몫을 가르지 않았다. #51303 이 같은 15.519 h 를 턴 종류와 명령으로 가른다. 직접 턴에서 `sleep` 뒤에 GitHub 확인 상태를 읽는 호출 중 같은 Keeper 의 채팅 작업이 기다린 시간이 10.629 h 다. 그쪽 분류는 `sleep` 이 든 호출이고 `actions/runs` 읽기도 세서, 위 표의 `pr_checks`·`commit_checks` 와 집합이 다르다.
- 18.946 h 는 check 를 기다린 시간의 상한이다. §1.2 의 "읽는 것" 줄처럼 `gh pr view` 로 리뷰나 병합을 기다린 호출이 섞여 있다.

### 1.2 기다림이 쓰인 모양 (스크립트 밖에서 센 값)

입력은 §1.1 과 같은 장부(`~/me/.masc/tool_calls`), 같은 창, 같은 `shape_of` 다. 정규식으로 명령 글자를 센 값이다. 저장소에 스크립트를 두지 않았다.
합계가 위 JSON 과 같다(`pr_checks` 168건 8.615 h, `commit_checks` 140건 10.331 h).

- 308건 중 `gh pr checks --watch` 는 1건(0.074 h)이다. 229건(16.867 h, 89.0%)은 명령에 `sleep <정수>` 가 있다. `sleep` 값은 중앙값 120초(p10 45초, p90 300초, 최소 4초, 최대 540초)다.
- 호출 시간은 중앙값 201초, p90 413초, 최대 1,060초다.
- 호출 시간 ÷ 첫 `sleep` 값으로 읽기 횟수를 어림하면 711번이다(229건만 센 어림이고 한계가 아니다). 시간당 10번 안팎이다.
- 읽는 것: `gh pr checks` 77건(4.819 h), 커밋의 `check-runs`·`status` 133건(9.808 h), `gh pr view|status` 98건(4.319 h, 그중 7건은 `check-runs` 도 적었다).
- check 이름을 하나 골라 읽는 호출이 66건(5.899 h, 31.1%)이다. `type-check` 31건, `ocaml` 27건, `artifact-current` 14건이 많다(한 호출이 이름을 둘 이상 적기도 한다).
- 저장소: `jeong-sik/masc` 211건(11.258 h), `jeong-sik/wkbl` 86건(7.151 h), 명령에 저장소가 없는 11건(0.537 h)이다.
- 대상: `commit_checks` 140건 중 저장소와 sha 가 글자로 있는 88건(서로 다른 (저장소, sha) 58쌍, 7.114 h)을 REST `GET /repos/{r}/commits/{sha}/pulls` 로 물었다. 그 sha 가 PR 의 최종 head 인 것이 44건(3.901 h), PR 안에 있지만 최종 head 가 아닌 것이 35건(2.710 h), 어느 PR 에도 없는 것이 9건(0.503 h)이다. 나머지 52건은 sha 가 셸 변수에 있어서 모른다.
- 동시에 붙든 수: 최대 4개다. 1개 12.663 h, 2개 2.514 h, 3개 0.400 h, 4개 0.013 h 이고, 하나라도 붙든 시간은 15.591 h 다(72시간 중).
- Keeper 16명이다. 시간이 큰 쪽은 rondo 4.575 h, wkbl-front 2.586 h, wkbl-web-leader 2.566 h, masc-productor-owner 2.465 h, wkbl-data 2.221 h, code-reviewer 1.827 h 다.

### 1.3 GitHub 에 직접 물어 본 것

2026-11-11 08:16Z~08:52Z, `jeong-sik/masc`, 이 세션의 `gh` 계정이다. 서버가 읽는 계정(`pr-updater`)이 아니다. 같은 API 이므로 같은 동작이라고 가정했다.

| # | 물은 것 | 본 것 |
|---|---|---|
| 1 | 열린 PR 40개에서 `statusCheckRollup` 의 `state` 만 고를 때와 `contexts` 를 같이 고를 때 | 7개 PR(50830, 50832, 51084, 51112, 51196, 51209, 51228)에서 head 가 같은데 `state` 가 `SUCCESS` 대 `FAILURE` 로 갈린다. 순서를 바꿔 다시 물어도 같은 7개다. 51112 하나만 물어도 재현된다. `contexts` 에는 앞 check suite 의 `changes`·`type-check` 가 `CANCELLED` 로 남아 있다. 51112 의 `mergeStateStatus` 는 `CLEAN` 이다 |
| 2 | 51112 head 의 `GET /commits/{sha}/check-runs?filter=latest` 와 `filter=all` | 둘 다 14개이고 취소된 앞 suite 의 run 이 들어 있다 |
| 3 | `gh pr checks 51112` (gh 2.101.0) | 5줄 모두 pass, 종료 코드 0이다. `--required` 는 `changes`·`type-check` 두 줄이다. 중복은 CLI 가 걷어 낸다 |
| 4 | 같은 `check-runs` URL 에 `If-None-Match` | 2번 모두 304 이고 `x-ratelimit-used` 가 그대로(668)다. 응답에 `Cache-Control: private, max-age=60` 과 약한 ETag 가 있고 `x-poll-interval` 은 없다 |
| 5 | GraphQL 한 질의에 commit 20개와 없는 sha 1개의 `statusCheckRollup { state }` | 비용 1점이다. 없는 sha 는 `null` 이다. 짧은 sha 는 질의 전체가 `Expected type 'GitObjectID'` 검증 오류로 실패한다 |
| 6 | 51112 head 의 `PR type-check` run(42956752125)의 job 시각 | `changes` 는 04:03:48 에 만들어져 04:03:55 에 끝났고, `type-check` 는 04:03:55 에 만들어졌다. run 은 04:03:46~04:11:28 내내 `in_progress` 다 |
| 7 | 51112 head 의 `GET /actions/runs?head_sha=` | run 12개다. 04:03Z push 뒤 08:00Z 와 08:16Z 에 리뷰 이벤트가 `Approval merge request` run 을 같은 head 에 더 만들었다 |
| 8 | `main` head 의 `GET /actions/runs?head_sha=` 에 40자리 sha 와 앞 10자리 | 40자리는 run 4개, 앞 10자리는 오류 없이 0개다 |
| 9 | `GET /actions/runs?per_page=200` (저장소 전체) | 100개만 돌아온다 |

- 1 로 서버 스냅숏의 질의(`state` 만, `lib/server/server_repository_pulls.ml:164`)는 GitHub 의 병합 판정과 같은 쪽이고, `contexts` 를 더하면 달라진다는 것을 알았다. 이유는 모른다.
- 6 으로 `needs` 로 이어진 job 은 앞 job 이 끝나는 초에 만들어진다는 것을 알았다. 그 사이에 읽으면 있는 context 가 모두 끝난 것으로 보인다. 초 단위 시각이라 틈의 길이는 1초 안쪽이라는 것만 안다.
- 7 로 한 head 의 check 가 끝난 뒤에도 새 check 가 같은 head 에 붙는다는 것을 알았다.
- 8 로 짧은 sha 는 REST 에서 오류가 아니라 빈 목록이 된다는 것을 알았다. 거르지 않으면 "아직 run 이 없는 commit"과 구별되지 않는다.

### 1.4 GitHub 문서

2026-11-11 08:16Z 에 github/docs 의 원문과 docs.github.com 으로 확인했다. 읽은 문서는 [REST 한도](https://docs.github.com/en/rest/using-the-rest-api/rate-limits-for-the-rest-api), [REST 모범 사례](https://docs.github.com/en/rest/using-the-rest-api/best-practices-for-using-the-rest-api), [GraphQL 한도](https://docs.github.com/en/graphql/overview/rate-limits-and-query-limits-for-the-graphql-api), [필수 check 문제 해결](https://docs.github.com/en/pull-requests/how-tos/merge-and-close-pull-requests/troubleshooting-required-status-checks), [check 상태](https://docs.github.com/en/pull-requests/reference/status-checks)다.

- REST: 인증된 사용자는 시간당 5,000건이다. PAT, OAuth 앱, GitHub App 사용자 토큰이 한 계정의 한도를 같이 쓴다. App 설치 토큰은 최소 5,000건이고 저장소·사용자 수에 따라 12,500건까지 는다. Actions 의 `GITHUB_TOKEN` 은 저장소당 시간당 1,000건이다.
- GraphQL: 사용자는 시간당 5,000점이고 `GITHUB_TOKEN` 은 저장소당 1,000점이다. 한도를 넘어도 상태는 200 이고 오류 본문과 `x-ratelimit-remaining: 0` 으로 온다.
- 보조 한도: 동시 요청 100, REST 900점/분, GraphQL 2,000점/분이다. 문서는 이 값이 예고 없이 바뀐다고 적는다.
- 조건부 요청: 인증된 GET 이 304 를 받으면 기본 한도에 들지 않는다. 문서는 폴링 대신 webhook 을 먼저 권하고, 폴링해야 하면 `x-poll-interval` 과 조건부 요청을 따르라고 한다.
- 필수 check: 마지막 commit 의 check 가 통과해야 한다. 성공으로 치는 값은 `success`, `skipped`, `neutral` 이다. 조건으로 건너뛴 job 은 `success` 로 보고된다. 경로·브랜치 필터나 commit 메시지로 건너뛴 workflow 의 check 는 `Pending` 에 머물러 병합을 막는다.
- check 의 `status` 값은 `completed`, `expected`, `failure`, `in_progress`, `pending`, `queued`, `requested`, `startup_failure`, `waiting` 이다. 이 가운데 `expected`, `pending`, `requested`, `startup_failure`, `waiting` 은 Actions 만 쓴다. `conclusion` 은 `action_required`, `cancelled`, `failure`, `neutral`, `skipped`, `stale`, `success`, `timed_out` 이다.
- 결합 상태 API 의 문서는 `failure` 가 하나라도 있으면 `failure`, 하나라도 `pending` 이면 `pending` 이라 적는다. 이것은 commit status 의 문서이고 check run 을 합친 `statusCheckRollup` 의 문서가 아니다.

## 2. 문제

- Keeper 가 check 를 기다리는 동안 Execute 가 턴을 쥔다. 서버에는 check 가 끝났다고 깨우는 길이 없다.
- 길이 둘 있지만 맞지 않는다.
  - `until_github_run` 은 run 하나를 받는다. 한 head 의 check 는 여러 workflow 의 run 으로 나뉜다(§1.3 의 7: run 12개). Keeper 는 run 번호가 아니라 commit sha 를 안다. 이미 있는 감시도 잘 안 쓰인다. 창 A 의 `single_run` 340건 중 같은 Keeper 가 그 run 에 감시를 건 것은 16건(1.326 h), 걸지 않은 것은 324건(23.554 h)이다.
  - `run_in_background` 는 이미 있다(`config/tools/Execute.toml:8-11`). 창 A 의 Execute 89,771건 중 124건이 썼고 60초 이상 1,181건 중에는 0건이다. 서버가 재시작하면 그 run 은 끝난다. 읽기는 Keeper 마다 따로 한다.
- "끝"이 한 사건이 아니다. 같은 commit 의 합산 판정이 질의 모양에 따라 다르고(§1.3 의 1), 뒤따르는 job 은 앞 job 이 끝난 뒤에 생기고(6), 끝난 뒤에도 같은 head 에 새 run 이 붙는다(7).
- 풀어야 할 것은 다섯이다. 무엇을 거는가, 누가 어떻게 읽는가, "끝"이 무엇인가, 어떻게 깨우고 치우는가, 틀렸는지 어떻게 아는가.

## 3. 지금 코드가 하는 일

| 하는 일 | 어디 | 동작 |
|---|---|---|
| run 감시 인자 | `config/tools/masc_schedule_create.toml:79-89`, `lib/tool_schedule.ml:397-417` | `until_github_run` 은 Actions run URL 하나다. due 는 필수이고 마감이다. `one_shot` 만 받는다 |
| 감시 한 번 | `lib/schedule_run_watch.mli:143-163`(`tick`), `:124-126`(`settle_payload`) | 감시가 달린 `Scheduled` one-shot Keeper wake 를 모아 서로 다른 대상마다 한 번 읽는다. 끝났거나 영구 실패면 due 를 지금으로 당기고 payload 에서 감시를 지운다. 읽는 사이에 일정이 바뀌면 `Stale_instance` 로 바뀐 쪽을 지킨다 |
| 서버 루프 | `lib/server/server_schedule_run_watch.ml:7`(`poll_interval_sec = 30.0`), `:9-27`, `:64-99`. 시작은 `lib/server/server_bootstrap_maintenance.ml:632-640` | 30초마다 한 번 돈다. 한도에 걸리면 GitHub 이 준 시각까지 쉰다 |
| run 읽기 | `lib/server/server_github_run_reader.ml:5`, `:23`, `:76` | REST `/repos/{o}/{r}/actions/runs/{id}` 를 읽는 계정 토큰으로 읽는다. 쉬는 시간은 한 시간까지다 |
| runner 간격 | `lib/config/env_config_runtime_services.ml:92` | 기본 15초다 |
| PR 스냅숏 | `lib/server/server_repository_pulls.ml:156-169`(질의), `:187-191`(`check_state_of_wire`), `:207-228`(`decode_checks`), `:762`(등록 저장소), `:832`(`poll_interval_s = 60.0`) | 등록 저장소의 열린 PR 을 60초마다 GraphQL 로 읽는다. check 는 head commit 의 `statusCheckRollup { state }` 하나다. `lib/repository_pulls.mli:15-19`, `:80-98`(`checks`, `head_oid`), `:138-154`, `:277-281` 에 타입과 `publish`·`current` 가 있고 메모리에만 있다 |
| 읽는 계정 | `lib/server/server_repository_pulls.ml:633-639`(`stored_token`), `:667`(`resolve_reader`), `:901-908`(`rest_get`). 라이브 `~/me/.masc/config/runtime.toml:1414-1415` 의 `pr_reader = "pr-updater"` | REST 와 GraphQL 이 같은 토큰을 쓴다. github.com 만 읽는다 |
| 등록 저장소 | `~/me/.masc/config/repositories.toml` (11-11) | `jeong-sik/figma-mcp`, `jeong-sik/masc`, `jeong-sik/wkbl` 셋이다. `wkbl` 만 비공개다 |
| 스냅숏을 쓰는 곳 | `lib/repository_pulls_placement.mli:1-27` | World State 의 PR 칸이 `Checks_failing` 을 "할 일"로, `Checks_running` 을 "목록 밖"으로 놓는다. 깨우지는 않는다 |

없는 것은 다음과 같다.

- `Pull_heads`·`until_github_pr_heads`·`Pull_request_changed` 는 lib, config, bin, test 에 0건이다(`rg`).
- GitHub webhook 을 받는 경로가 없다. `X-GitHub-Event`·`X-Hub-Signature` 가 lib 과 config 에 0건이다. world-state RFC §3.1 의 A 가 이유와 함께 쓰지 않기로 했다.
- RFC-0379 §6.6.2 의 1번은 스냅숏 레코드에 head 가 없다고 적는다. 지금은 `head_oid` 가 있다(#50214).
- #51284 가 RFC-0379 에 같은 정정을 더한다. `Pull_heads` 는 head 변경·닫힘·병합에 깨우고 check 완료에는 깨우지 않는다.

이 서버가 오늘 `until_github_run` 으로 깨운 기록은 로그에 있다(`masc-start-20261111T073312Z.log`, `schedule_run_watch: woke` 줄 2개, 17:13:23 와 17:24:39 KST).

## 4. 후보 설계

### 4.0 세 후보가 같이 쓰는 것

- 감시는 일정 행에 산다. `masc.keeper_wake` payload body 의 필드 하나이고 `one_shot` 만 받는다. due 는 마감이다. 일정 행이 유일한 기록이라서 새 저장소도 새 durable 상태도 없다. 서버가 재시작해도 이어진다.
- 한 일정에 감시는 하나다. `until_github_run` 과 새 감시를 같이 주면 도구가 거절한다. `until_github_run` 은 바꾸지 않는다.
- 만들 때 읽지 않는다(RFC-0379 §6.5). 이미 끝난 대상은 다음 순서에 깨운다.
- 읽기 실패는 RFC-0379 §6.5 와 같이 둘로 나눈다. 같은 답이 다시 올 것(`Not_visible`, `Token_rejected`, `Forbidden`, `Response_unreadable`, 읽는 계정 없음)은 첫 순서에 이유와 함께 일찍 깨운다. 나머지(`Rate_limited`, 전송 실패, 5xx)는 다음 순서에 다시 읽고 due 가 마감이다. `read_failure` 타입은 `lib/schedule_run_watch.mli:75-91` 것을 쓴다.
- 읽는 계정, 한도 정지(`pause_after`), 30초 간격은 서버 루프의 것이다. 새 상수를 더하지 않는다.
- 깨우는 길은 `until_github_run` 과 같다. 끝났다고 보면 due 를 지금으로 당기고 필드를 지우고 메시지 앞에 결과를 붙인다. runner 가 Keeper 큐에 넣는다. 필드가 지워져서 두 번 깨우지 않는다.
- Keeper 에게 알리는 곳은 도구 정의다(`masc_schedule_create`·`masc_schedule_update` 의 인자 설명과 `Execute` 의 설명). 문장은 구현 PR 이 정한다. 이 RFC 는 Keeper 프롬프트 문장도 강제 규칙도 제안하지 않는다.

### 4.1 "끝"의 뜻

세 후보가 모두 정해야 하는 축이다.

| | 끝 = | 읽는 것 | 틈 |
|---|---|---|---|
| A | commit 의 합산 판정이 났다(`statusCheckRollup.state` 가 `SUCCESS`, `FAILURE`, `ERROR`) | GraphQL, `state` 만 | ① `contexts` 를 같이 고르면 같은 commit 이 `FAILURE` 로 바뀐다(§1.3 의 1). ② `needs` 로 이어진 job 이 만들어지기 전 1초 안쪽에 읽으면 "끝"으로 보인다(6). ③ `FAILURE` 가 `PENDING` 보다 앞서는지는 check run 쪽에서 확인하지 못했다 |
| B | 그 commit 의 Actions run 이 하나 이상이고 모두 `completed` 다 | REST `GET /repos/{o}/{r}/actions/runs?head_sha=<sha>&per_page=100` 한 번 | Actions 가 아닌 check(commit status, 다른 앱)를 보지 않는다. run 이 아직 없는 때(push 직후)와 영영 없는 commit(경로 필터)을 구별하지 못해 둘 다 due 까지 기다린다. `workflow_run` 으로 뒤늦게 생기는 run 은 그 전에 못 본다. ②의 틈은 없다. job 이 이어지는 동안에도 run 은 계속 `in_progress` 다(6). 깨울 때 판정 대신 run 별 `conclusion` 을 준다 |
| B′ | 그 commit 의 Actions run 중 `event` 가 `push`·`pull_request`·`workflow_run` 인 것(체크 run)이 하나 이상이고 모두 `completed` 다. 다른 `event`(리뷰·라벨·손으로 돌린 run)는 세지 않는다 | B 와 같다 | B 의 틈 중 체크가 시작하기 전에 깨우는 것을 막는다(아래 첫 항목, 60개 head 에서 B 6개, B′ 0개). B 와 같이 Actions 가 아닌 check 를 보지 않는다. 제품 코드가 `event` 를 닫힌 종류로 읽는다. 모르는 값은 `Other_event` 로 남기고 체크 run 으로 세지 않는다. 깨울 때 run 별 `conclusion` 을 준다 |
| C | B 가 참이고, 그때 한 번 읽은 A 의 판정이 났다 | B 는 순서마다, A 는 B 가 참일 때만 | 읽기가 둘이다. ②를 B 가 막고 ①은 `state` 만 고르면 피한다. 판정이 `PENDING` 이면 B 가 참인 채 다음 순서에도 A 를 읽는다 |
| D | 필수 check 만 | `isRequired` 나 ruleset 읽기와 "이름마다 최신 run" 고르기 | 후보에서 뺀다. 최신 run 을 고르는 규칙을 우리가 가져야 한다. REST 목록은 취소된 앞 run 을 함께 주고(2), `gh` 는 (workflow, 이름)으로 클라이언트에서 거른다(3). 이름만으로 거르면 틀린다. 51112 의 `contexts` 에 `request` 가 8개 있다 |

- **B 는 체크가 시작하기 전에 깨울 수 있다.** 하네스 PR #51315 가 최근 PR 60개의 head(2026-11-11T09:55Z)에서 run 을 읽었다. 47개 head 에 "만들어진 run 이 모두 끝난" 순간이 있었고, 그중 6개(10.0%)는 그 뒤에 체크 run(`event` 가 `push`·`pull_request`·`workflow_run`)이 더 만들어졌다. 간격은 중앙값 56초, 최대 98초다. 승인 workflow(`Approval merge request`)가 먼저 끝나고 체크가 시작하는 경우다. 체크 run 끼리만 보면 끊김이 60개 head 모두에서 0이었다. 끝을 "체크 run 이 하나 이상이고 모두 끝났다"로 좁히면 이 표본에서 이른 깨움이 0이다. 대가는 제품 코드가 `event` 값을 닫힌 종류로 읽어야 한다는 것이다(모르는 값은 `Other_event` 로 남기고 체크 run 으로 세지 않는다). 표본이 한 저장소·한 시기이고 run 단위라서 job 단위 틈(②)은 보지 못했다.
- 이름을 골라 기다리는 호출이 66건(5.899 h)이다. check 이름은 job 이름이라 run 목록(B)으로는 고를 수 없다. `GET /commits/{sha}/check-runs?check_name=` 이 필요하다. v1 에 넣지 않고 §7 에 올린다.
- "첫 실패에 깨운다"(`gh pr checks --fail-fast` 와 같은 뜻)는 이 표와 따로 정할 일이다. B 가 주는 run 별 `conclusion` 으로 표현은 되지만, 실패한 run 이 다시 돌아 덮이는지는 미리 알 수 없다.

### 4.2 후보 가 — `Pull_heads` 감시의 사건에 check 완료를 더한다

- 걸기. RFC-0379 §6.6.1 의 `until_github_pr_heads: {repo, pulls: [{number, head}]}` 를 먼저 만들고, 감시가 받는 사건에 `Checks_decided` 를 더한다. 사건을 고르게 하지 않으면 head 변경을 기다리는 리뷰 Keeper 도 check 완료로 깨어난다. 고르게 하면 인자가 하나 늘어난다.
- 읽기. 서버의 60초 PR 스냅숏을 그대로 쓴다. 추가 읽기가 0번이다. 스냅숏에 `head_oid` 와 `checks` 가 이미 있다.
- 깨우는 때. 스냅숏의 그 PR 의 `head_oid` 가 건 `head`(7~40자리 접두어, RFC-0379 §6.6.1)로 시작하고 `checks` 가 `Checks_passing` 또는 `Checks_failing` 이면 `Checks_decided` 다. 시작하지 않으면 `Head_moved`, 열린 목록에 없으면 `Left_open_pulls` 다. 닫힘과 병합은 구별하지 못한다. `Pulls_not_read`·`Pulls_failed` 는 기다림이다.
- 지연. 스냅숏 60초와 runner 15초를 더한 75초 안이다(기존 상수 둘의 합이고 읽는 시간은 뺀다).
- 장점. GitHub 읽기가 늘지 않는다. 읽는 곳이 하나라서 한도 정지와 계정 문제가 한 군데다. 매핑이 `check_state_of_wire` 하나다.
- 단점.
  - `Pull_heads` 가 먼저 있어야 한다. RFC-0379 §6.6.2 의 열린 결정(읽는 방법, PR 상한, 닫힘에도 깨우는지, 반복 일정)이 앞선다.
  - 열린 PR 목록에 없는 commit 은 못 건다. 샘플에서 9건(0.503 h)이 어느 PR 에도 없는 commit 이었다.
  - 등록 저장소 셋 밖은 못 건다. `wkbl` 은 비공개이고 `pr-updater` 가 읽는지 확인하지 못했다. 못 읽으면 `wkbl` 의 7.151 h(38%)가 닿지 않는다.
  - 끝의 뜻이 A 로 고정이다. 스냅숏이 `state` 만 고르므로 틈 ①은 피하지만 ②가 남는다.
- 이 설계가 틀렸다면 드러나는 곳. 하네스의 "안 건 기다림"이 줄지 않거나 "늦은 깨움"이 75초를 넘는 곳이다(§5.2).

### 4.3 후보 나 — commit 하나의 check 를 기다리는 감시를 새로 둔다

- 걸기. `masc_schedule_create`·`masc_schedule_update` 에 `until_github_checks` 를 더한다. 값은 commit URL `https://github.com/<owner>/<repo>/commit/<40자리 16진수>` 다. 짧은 sha 는 도구가 거절한다. REST 는 짧은 sha 에 빈 목록을 주고(§1.3 의 8) GraphQL 은 질의 전체를 검증 오류로 거절한다(§1.3 의 5). PR 의 head 를 기다릴 때는 Keeper 가 그 head 의 sha 를 준다.
- 읽기. 서버 루프가 서로 다른 (저장소, sha)마다 한 번 읽는다. 끝의 뜻이 B 면 REST 한 번이다. C 면 B 의 읽기에 필요할 때 롤업 읽기가 한 번 더 든다.
- 깨우는 때. B 면 run 이 모두 끝났을 때 한 번이다. 결과는 run 별 `workflow`·`event`·`conclusion` 이고 고르거나 합치지 않는다(§4.6).
- 지연. 30초와 15초를 더한 45초 안이다(RFC-0379 §6.5 의 계산과 같고 읽는 시간은 뺀다).
- 읽기 수. 서로 다른 commit 수 × 시간당 120번이다. 측정한 동시 최대 4개면 480번/시간(REST 5,000 의 9.6%), 평균 0.263개면 약 32번/시간이다. Execute 보유가 감시로 모두 바뀐다고 가정한 값이다. 지금 Keeper 가 읽는 어림 711번/72시간(시간당 10번 안팎)보다 는다.
- 장점.
  - PR 과 저장소 등록과 무관하다. 읽는 계정이 볼 수 있으면 된다. PR 에 없는 commit 도 된다.
  - `until_github_run` 의 tick, `settle_payload`, `Stale_instance` 지킴, 영구·일시 실패 구분을 그대로 쓴다.
  - 새 durable 상태와 새 상수가 없다.
- 단점.
  - 인자가 한 곳에 더해지는 게 아니다. 도구 정의 둘, `lib/tool_schedule.ml:397-417`, `lib/schedule_payload_projection.ml:211`·`:237`, TUI 수정 폼(`bin/masc_tui_types.ml:3064-3067`)에 든다. 하나라도 빠지면 `masc_schedule_update` 가 감시를 지운다(RFC-0379 §6.5 가 적은 동작이고, 그래서 TUI 수정 폼도 감시를 같이 싣는다).
  - Keeper 가 push 해서 commit 이 바뀌면 옛 commit 의 감시는 계속 돌고 옛 commit 으로 한 번 깨운다. "head 가 바뀌었다"는 사건이 없다.
  - Keeper 가 쓰지 않을 수 있다. `until_github_run` 의 선례가 324건/23.554 h 다(§2).
- 이 설계가 틀렸다면 드러나는 곳. 하네스의 "거짓 깨움"과 "깬 뒤 되기다림"이 0 이 아니거나 "안 건 기다림"이 줄지 않는 곳이다(§5.2).

### 4.4 후보 다 — 읽기를 서버 한 곳으로 모은다

감시를 어디에 걸든 읽기 구조는 따로 고른다.

| | 누가 읽나 | 시간당 읽기 | Keeper 시간 |
|---|---|---|---|
| 0 지금 | Keeper 가 Execute 로 각자 `sleep` 반복 | 어림 711번/72시간(시간당 10번 안팎) | 72시간에 18.946 h 붙든다 |
| 1 서버가 감시마다 | 감시 하나가 읽기 하나 | 감시 수 × 3,600 ÷ 간격 | 0 |
| 2 서버 한 곳에서 대상마다 한 번 | 같은 commit 은 Keeper 가 몇이든 한 번 | 서로 다른 대상 수 × 3,600 ÷ 간격 | 0 |
| (가)의 스냅숏 | 서버가 이미 읽는 것 | 늘지 않는다(저장소 수 × 60번/시간) | 0 |

- 구조 2 는 `Watch.tick` 이 이미 한다. 서로 다른 대상마다 한 번 읽고 한도에 걸리면 그 순서에서 더 읽지 않는다(`lib/schedule_run_watch.mli:149-151`). 새 감시도 같은 tick 을 쓰면 구조 2 가 된다.
- 끝의 뜻이 A 나 C 의 롤업이면 대상을 GraphQL 한 질의에 모을 수 있다. commit 21개가 1점이었다(§1.3 의 5). 대신 나쁜 sha 하나가 질의 전체를 실패시킨다. 40자리 16진수만 받아야 한다. B 는 REST 라서 이 일이 없다.
- 읽는 계정은 Keeper 12명이 `gh` 로 같이 쓴다(world-state RFC §3.4 의 서술이고 이번에 다시 세지 않았다). 서버 읽기가 늘면 Keeper 의 한도가 줄고 Keeper 의 폴링이 줄면 한도가 는다. 순효과는 재지 않았다.
- 장점. 같은 commit 을 여럿이 기다려도 읽기가 하나다. 읽기가 한 곳이라 한도 정지가 한 곳이다.
- 단점. 지금보다 읽기가 는다. 간격이 30초라서 Keeper 의 `sleep` 중앙값 120초보다 4배 촘촘하다.
- 이 설계가 틀렸다면 드러나는 곳. 하네스의 "읽기 수"가 식(대상 수 × 3,600 ÷ 간격)과 다르거나 서버 로그에 `Rate_limited` 줄이 나오는 곳이다(§5.2).

### 4.5 비교와 정석

| | 가 | 나 |
|---|---|---|
| 걸 수 있는 것 | 등록 저장소의 열린 PR | 읽는 계정이 보는 모든 commit |
| 새 GitHub 읽기 | 0 | 대상 수 × 120번/시간 |
| 최대 지연 | 75초 | 45초 |
| 선행 | `Pull_heads`(코드 없음, 결정 열림) | 없음 |
| 닿는 코드 | `Pull_heads` 전부 | 도구 정의 둘, `tool_schedule`, 투영, TUI 폼, 읽기 하나 |
| 끝의 뜻 | A 로 고정 | A·B·B′·C |
| 새 상수 | 0 | 0 |

정석으로는 (나)에 구조 2 를 묶는 쪽을 본다. 끝은 B′로 정했다(§7). 이유는 측정에서 나온다.

- 기다림의 54.5%(18.946 h 중 10.331 h)가 commit 읽기다. 표본 88건 중 9건은 어느 PR 에도 없는 commit 이다. PR 로 키를 잡으면 그 9건은 걸 수 없다.
- 읽기 수가 대상 수로만 정해지고 측정한 동시 최대가 4다.
- 새 상태가 없고 새 상수가 없다. 30초와 15초는 지금 코드의 것이다.
- B 는 깨우는 때에 판정(성공·실패)을 만들지 않아서 "이름마다 최신 run" 규칙이 필요 없다. 틈 ②가 없다.

대가는 다음과 같다.

- 읽기가 지금보다 는다.
- 인자가 다섯 곳에 닿는다.
- Actions 가 아닌 check 를 보지 못한다. `masc` 의 열린 PR 40개의 context 는 모두 check run 이었고 commit status 는 0개였다(§1.3 의 1 의 질의). `wkbl` 은 보지 못했다.
- 옛 commit 감시를 Keeper 가 정리해야 한다.

(가)는 리뷰하는 Keeper 의 head 감시(§6.6)가 필요하다는 결정이 난 뒤에 간다. 그때 check 완료를 거기에 더할지 따로 정한다.

### 4.6 깨움의 모양

타입은 스케치다. 이름과 필드는 구현 PR 이 정한다.

```ocaml
(* (나)·끝 B. sha 는 40자리 16진수만 받는다 *)
type target = { repo : Schedule_run_watch.repo; sha : Commit_sha.t }

type run_view =               (* GitHub 이 준 run 한 개. 고르거나 합치지 않는다 *)
  { workflow : string
  ; event : string
  ; created_at : float
  ; conclusion : Schedule_run_watch.conclusion option }  (* completed 가 아니면 None *)

type settled =
  | Runs_completed of { runs : run_view list }      (* 하나 이상이고 모두 completed *)
  | Unreadable of Schedule_run_watch.read_failure   (* 같은 답이 다시 올 때만, 일찍 깨운다 *)
```

```ocaml
(* (가) *)
type verdict = Passing | Failing

type settled_pull =
  | Checks_decided of { head : Commit_sha.t; verdict : verdict }
  | Head_moved of { was : Commit_sha.t; now : Commit_sha.t }
  | Left_open_pulls            (* 닫힘인지 병합인지는 모른다 *)
  | Unreadable of Schedule_run_watch.read_failure
```

- `conclusion` 은 `Schedule_run_watch.conclusion`(`lib/schedule_run_watch.mli:45-55`)을 그대로 쓴다. run 의 `conclusion` 이 같은 값 집합이다. 모르는 값은 `Unrecognized` 로 남는다.
- `status` 가 `completed` 가 아닌 문자열은 아직 도는 것이다. `status` 가 없거나 문자열이 아니면 응답 해석 실패다. 지금 run 감시와 같다(`observation_of_run_json`).
- 판정을 `Passing | Failing` 으로 줄이는 것은 (가)와 끝 C 뿐이다. `Repository_pulls.check_state` 에서 `Checks_passing`·`Checks_failing` 만 판정이 난 것으로 옮기고 `Checks_running`·`Checks_none` 은 기다림이다. 모르는 wire 값은 지금처럼 읽기 실패다.
- 메시지는 감시의 대상과 이 값에서 만든다. 대상은 (가)가 저장소·PR 번호·head 이고 (나)가 저장소·sha 다. 첫 줄들은 결과와 URL 이고 그 뒤는 Keeper 의 원래 메시지다. 시험은 문장이 아니라 값을 비교한다.
- run 별 목록을 싣는지는 §7 에 올린다. 싣지 않으면 Keeper 가 깬 뒤 `gh` 로 한 번 더 읽는다. 실으면 취소된 앞 run 이 함께 보인다.

### 4.7 정리 — head 가 바뀔 때

- 감시의 상태는 일정 행 하나다. 깨울 때 필드를 지우고 due 를 지금으로 당기면 끝이다. 정리할 다른 저장소가 없다.
- (나)에서 Keeper 가 새 commit 을 push 하면 `masc_schedule_update` 로 같은 일정을 새 sha 에 다시 건다. update 는 정의 전체를 바꾸므로(RFC-0379 §6.5) 옛 감시가 남지 않고 깨움도 한 번도 안 간다. 다시 걸지 않으면 옛 commit 이 끝날 때 옛 commit 으로 깨운다. 메시지에 sha 가 있어서 Keeper 가 알아본다.
- (가)에서는 서버가 `Head_moved` 로 끝낸다. 깨움이 한 번 간다.
- 서버가 재시작하면 일정 행이 남아 있어서 다음 순서에 다시 읽는다. (가)의 스냅숏은 재시작 직후 `Pulls_not_read` 라서 첫 읽기까지 기다린다.
- 대상 commit 이 그 저장소에 없으면(GraphQL `null`, REST 404) 같은 답이 다시 올 실패라서 이유와 함께 일찍 깨운다. run 이 아직 하나도 없는 commit 은 기다린다. 영영 없으면 due 에 깨어난다.

## 5. 하네스

Harness First 로 구현보다 먼저 정한다. 평가 기준이 구현 PR 안에 있으면 에이전트가 바꿀 수 있다.

### 5.1 다시 재는 법과 기준선

구현 뒤에 같은 길이(72시간)의 창을 같은 스크립트로 잰다. 명령은 #51284 의 `docs/evidence/tool-efficiency-1111-2026-11/README.md` 의 「다시 내는 법」과 같다.

```
python3 -I docs/evidence/tool-efficiency-1110-2026-11/github_wait_shapes.py <시작> <끝> ~/me
python3 docs/evidence/tool-efficiency-before-after-2026-11/queue_wait_overlap.py --base-path ~/me --since <시작> --end <끝> --hold-s 60 --json-out <경로>
python3 -I docs/evidence/execute-waits-2026-11/measure_execute_waits.py --base-path ~/me --from-date <날짜> --to-date <날짜> --until <끝> --json-out <경로>
```

기준선은 창 A 의 값이다. `pr_checks`+`commit_checks` 308건 18.946 h, 60초 이상 Execute 1,183호출 중 같은 Keeper 의 채팅 작업과 겹친 15.519 h(20.9%), 감시를 건 `single_run` 16건이다.
장부는 오래된 날 파일을 지우므로 같은 창을 나중에 다시 재면 값이 달라질 수 있다(#51284 README).

### 5.2 새로 재는 것

단위는 이미 있는 키다. 감시 하나는 일정 행(`schedule_id` 와 instance id)과 대상 (저장소, sha)다. 아는 곳은 셋이다.

- 거는 쪽: `masc_schedule_create` 장부 행의 `input` 에 있는 새 인자(typed 키)다.
- 깨우는 쪽: 서버 로그 `masc-start-<UTC>.log` 의 `schedule_run_watch:` 줄이다. 구현 PR 은 새 변형마다 줄을 낸다. RFC-0379 §6.5 가 같은 로그로 효과를 세도록 정했다.
- 사실 쪽: 하네스가 깨운 뒤에 GitHub 에서 직접 읽는다. `GET /actions/runs?head_sha=` 와 run 별 `GET /actions/runs/{id}/jobs` 다. 서버가 읽은 값으로 서버를 채점하지 않는다. job 의 `created_at`·`completed_at` 은 서버가 쓰는 run 의 `status` 와 다른 객체라서 틈 ②를 잡는다.

| 지표 | 정의 | 판정 |
|---|---|---|
| 거짓 깨움 | `Runs_completed`(또는 `Checks_decided`)로 깬 시각 T 에, 그 sha 의 run 중 `created_at ≤ T` 이고 T 에 아직 끝나지 않은 것이 있었다. 그 run 의 job 이 T 뒤에 만들어진 경우도 센다. T 뒤에 새 사건이 만든 run(리뷰 이벤트의 `Approval merge request`)은 세지 않는다 | 한 건이라도 나오면 sha·T·run 목록을 증거로 남긴다 |
| 놓친 깨움 | 대상의 모든 run 이 끝난 시각 `t_done`(job `completed_at` 의 최댓값)이 있는데 감시가 due 로 깨어났다. 한도 정지로 설명되는 것은 따로 센다 | 같다 |
| 늦은 깨움 | `T − t_done` 의 분포 | 최대가 `poll_interval_sec` + runner 간격 + 읽는 시간(기존 상수의 합)을 넘으면 원인을 적는다 |
| 깬 뒤 되기다림 | 같은 Keeper 가 같은 (저장소, sha)로 깬 뒤에 긴 check 대기 Execute 를 낸 호출 | 한 건이라도 나오면 거짓 깨움 칸과 맞춘다 |
| 안 건 기다림 | 감시 없이 걸린 긴 check 대기 Execute(같은 Keeper, 같은 (저장소, sha)). `github_wait_shapes.py` 의 `watched_by_same_keeper` 와 같은 정의를 `pr_checks`·`commit_checks` 로 넓힌다 | 줄어드는 방향만 본다 |
| 읽기 수 | 서버 로그의 순서당 읽은 대상 수 × 순서 수 | 식(대상 수 × 3,600 ÷ 간격)과 같아야 한다. 다르면 원인을 적는다 |
| 기다림 시간 | 창 A 와 같은 길이에서 `pr_checks`+`commit_checks` 시간 | 보고만 한다. 두 창의 일이 달라서 합격 기준으로 쓰지 않는다 |

- 합격은 값이 아니라 사건으로 정한다. 거짓·놓친 깨움을 몇 건까지 받아들일지는 사용자가 정한다.
- 기다림이 줄었다는 것만으로는 성공이 아니다. 줄었는데 거짓 깨움이 늘었으면 Keeper 는 깬 뒤에 다시 기다린다.

### 5.3 고정하는 것

- 하네스 PR 은 #51315 다. 정의(`check_wake_scoring.py`), 실제 head 에서 줄인 fixture 와 변이 8개, 감시가 없을 때의 값을 재는 프로브가 들어 있다.

- 위 표의 정의와 합성 fixture 를 하네스 PR 로 구현 PR 보다 먼저 병합한다. 구현 PR 은 그 파일을 바꾸지 않는다. 리뷰에서 확인한다. `.github/CODEOWNERS` 는 전부 한 사람이라서 기계로 막지 못한다.
- fixture 는 실제 값에서 줄인다. 51112 head 의 run 목록(취소된 앞 suite 와 뒤따른 suite), `PR type-check` run 의 job 시각(틈), 리뷰 이벤트가 뒤늦게 붙인 run 이다.
- 시험은 합성 장부와 합성 GitHub 응답으로 돈다. 변이(경계 비교, 최댓값을 최솟값으로, 기준 시각 바꾸기)를 하나씩 넣어 잡히는지 확인한다.
- 장부와 서버 로그는 읽기만 한다. 하네스가 GitHub 을 읽는 수는 깨움 수 × 호출 둘이다.
- 명령 글자로 `pr_checks`·`commit_checks` 를 가르는 규칙은 하네스가 세는 데만 쓴다. 제품 규칙이 아니다. `Execute` 는 명령을 해석하지 않는다(`config/tools/Execute.toml:6-7`).

## 6. 하지 않는 것

- GitHub webhook 을 받는 길. world-state RFC §3.1 의 A 결정을 따른다. 문서는 폴링 대신 webhook 을 권한다(§1.4). 그 결정이 바뀌면 이 RFC 가 아니라 그쪽에서 다시 연다.
- `Execute` 를 가로채거나 명령 글자로 감시를 자동으로 거는 일.
- Keeper 프롬프트 문장, 강제 규칙, yield 규칙.
- 감시 수 상한, 간격 조정, cooldown, dedup 상수. 새 상수를 더하지 않는다.
- 옛 일정을 읽는 reader·converter. `until_github_run` 은 바꾸지 않는다.
- 필수 check 만 거르기(끝 D).
- Ready 나 병합을 판정하는 일. 깨움은 사실을 알린다.
- world-state RFC 의 S8(자기 PR 실패에 깨움)과 `Pull_heads` 를 이 RFC 에서 만드는 일.
- `run_in_background` 길을 고치는 일. `execute-background-through-the-tool-outbox` 가 다룬다. #51303 은 영수증을 기다리며 턴이 끝나는 길을 후보로 낸다.

## 7. 사용자가 정할 것

1. **후보.** (나)에 구조 2 를 묶은 쪽을 정석으로 본다(§4.5). 근거는 commit 읽기가 기다림의 54.5% 라는 것, 읽기 수가 대상 수로만 정해진다는 것, 새 상태·상수가 없다는 것이다. 대가는 읽기가 는다는 것과 인자가 다섯 곳에 닿는다는 것이다. (가)는 `Pull_heads` 결정 뒤로 미룬다.
2. **"끝"의 뜻.** 결정(사용자, 2026-11-11): B′(체크 run 이 하나 이상이고 모두 끝남)다. 체크 run 은 `event` 가 `push`·`pull_request`·`workflow_run` 인 run 이다. 하네스 #51315 의 60개 head 에서 B 는 이른 깨움이 6개(10.0%)였고 B′ 는 0개였다(§4.1). 판정을 만들지 않아서 "이름마다 최신 run" 규칙이 필요 없고 틈 ②가 없다. Actions 가 아닌 check 를 놓친다. 하네스가 그런 거짓 깨움을 보이면 C 로 간다. 같이 정할 것은 셋이다. 첫 실패에 깨울지, 이름을 고른 check 만 기다리는 인자(66건, 5.899 h)를 v1 에 넣을지, 필수 check 만(D)을 영영 뺄지다.
3. **읽기 예산의 주인.** 서버는 `[repositories] pr_reader`(라이브 `pr-updater`)의 토큰으로 REST 와 GraphQL 을 읽는다. 이 계정은 Keeper 12명이 `gh` 로 같이 쓰고 한도는 계정당 REST 5,000건/시간, GraphQL 5,000점/시간이다(§1.4). 선택지는 둘이다. 지금 계정을 그대로 쓰고 스냅숏·run 감시와 한도를 나눈다. 또는 감시 전용 읽는 계정이나 GitHub App 설치 토큰(`keeper-github-apps`; 최소 5,000건, 최대 12,500건/시간)을 따로 둔다. 한도에 걸리면 감시 루프는 GitHub 이 준 시각까지 쉬고 due 가 마감이다(지금 동작). Actions 의 `GITHUB_TOKEN` 한도(저장소당 1,000건/시간)는 이 기능이 쓰지 않는다. 그 한도는 #50434 가 다룬다. 이 기능은 읽기만 해서 워크플로를 돌리지 않는다.
4. **깨움에 run 별 목록을 싣는가.** 싣지 않으면 Keeper 가 깬 뒤 `gh` 로 한 번 더 읽는다. 실으면 그 읽기가 줄지만 취소된 앞 run 이 함께 보인다(§1.3 의 2).
5. **옛 commit 감시의 정리.** Keeper 가 `masc_schedule_update` 로 다시 거는 데 맡길지, 서버가 PR 의 새 head 를 알아 `Head_moved` 로 끝낼지다. 뒤쪽은 (가)의 읽기가 필요하다.
6. **순서.** 하네스 PR 을 구현 PR 앞에 두는지, S8 과 겹치는 문제를 S8 을 켤 때로 미루는지다. S8 이 켜지고 같은 PR 에 감시가 걸려 있으면 PR 이 실패할 때 깨움이 둘 간다. RFC-0379 §6.3 은 어느 쪽이 먼저 구현되든 읽는 계정을 하나로 쓰라고 제안한다.

## 8. 확인하지 못한 것

- `statusCheckRollup.state` 에서 `FAILURE` 가 `PENDING` 보다 앞서는지 확인하지 못했다. 표본의 `FAILURE` 는 모두 check 가 다 끝난 PR 이었다. 문서는 commit status 쪽만 `failure` 가 앞선다고 적는다.
- `contexts` 를 같이 고르면 `state` 가 달라지는 이유를 모른다. 7/40 PR 에서 두 번 재현했고 GitHub 쪽 동작이라 예고 없이 바뀔 수 있다.
- 서버의 읽는 계정(`pr-updater`)으로는 묻지 않았다. §1.3 은 이 세션의 `gh` 계정으로 읽은 값이다.
- `pr-updater` 가 비공개 `jeong-sik/wkbl` 을 읽는지, 라이브 스냅숏의 `wkbl` 이 `Pulls_read` 인지 모른다. 스냅숏 엔드포인트(`GET /api/v1/repositories/pulls`, `lib/server/server_routes_http_routes_repositories.ml:508`)는 인증이 필요해서 읽지 않았다.
- `workflow_run` 으로 이어 도는 workflow 의 run 이 PR head 의 `actions/runs?head_sha=` 에 나오는지 모른다.
- `commit_checks` 140건 중 52건은 sha 가 셸 변수에 있어서 PR 의 head 인지 모른다.
- 308건 중 `gh pr view|status` 98건(4.319 h)이 check 를 기다렸는지 리뷰나 병합을 기다렸는지 모른다. 18.946 h 는 상한이다.
- `gh pr checks` 와 `gh api` 가 어느 계정으로 읽는지 확인하지 못했다. `per-keeper-github-cli-identity` 가 정하는 일이다. §4.4 의 "Keeper 12명이 같은 계정을 쓴다"는 world-state RFC 의 서술이다.
- 서버 읽기가 늘고 Keeper 의 폴링이 줄 때의 계정 한도 순효과를 재지 않았다. 이 세션 계정의 GraphQL 은 11-11 08:29:55Z 에 5,000점 중 2,164점을 쓴 상태였다(창 07:43:34Z~08:43:34Z). 다른 세션들이 쓴 것이고 서버의 읽는 계정과 다른 계정이다.
- GraphQL 한 질의에 넣을 수 있는 commit 수의 상한은 재지 않았다. 21개까지만 해 봤다.
- REST `actions/runs` 는 `per_page=200` 을 줘도 100개만 돌려준다(§1.3 의 9). run 이 100개가 넘는 head 가 있는지는 재지 않았고, 있으면 쪽을 넘겨 읽어야 한다.
- 문서 표는 `startup_failure` 를 `status` 값에 넣었다(§1.4). 워크플로 run 에서는 `conclusion` 으로 오는 값이다(`lib/schedule_run_watch.mli:45-55`). run 의 `status` 로 오는지 확인하지 못했다. 그렇게 오면 B 는 그 run 을 "도는 중"으로 읽고 due 까지 기다린다. 지금 `until_github_run` 도 같다.
- 구현이 없어서 깨움 지연, 거짓 깨움, 놓친 깨움의 값이 없다.
- 긴 호출의 최대 1,060초가 Execute 의 시간 제한 때문인지 확인하지 않았다.
- GitHub 의 한도와 동작은 2026-11-11 08:16Z~08:52Z 의 값이다.
