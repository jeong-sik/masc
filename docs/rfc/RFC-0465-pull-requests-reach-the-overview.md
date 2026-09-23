---
rfc: "0465"
title: "Workspace 저장소의 열린 PR 을 서버가 읽고, Overview 가 Keeper 옆에 붙인다"
status: Draft
created: 2026-09-23
author: dancer + claude
supersedes: []
superseded_by: null
related: ["0464"]
---

# RFC-0465: 열린 PR 이 Overview 에 닿는다

## 0. 결정할 것

Overview Team 블록(RFC-0464)은 누가 어떤 Task 를 잡았는지까지 말한다.
그 일이 어떤 PR 로 나갔고, CI 가 통과했는지, 리뷰를 기다리는지는 말하지 못한다.
서버에 PR 을 읽는 코드가 없기 때문이다.

1. 서버가 등록된 GitHub 저장소(`/api/v1/repositories` 의 `url`)마다 열린 PR 을 주기적으로 읽는다.
2. PR 을 Keeper 에 붙이는 기준은 **PR 마지막 커밋의 author 이름**이다(§2.1).
   런타임이 Keeper 의 git author 이름을 Keeper 이름으로 정해 두므로, 그 이름이
   등록된 Keeper 이름과 정확히 같으면 그 Keeper 의 PR 이다.
3. TUI 는 Team 행 끝에 PR 번호와 상태(CI 통과·실패·진행, 리뷰 대기, 충돌, draft)를 붙이고,
   Team 아래에 저장소별 한 줄 요약을 둔다. 어느 Keeper 에도 붙지 않은 PR 은
   요약 줄에 "Keeper PR 아님" 수로 센다.

## 1. 기준선 (2026-09-23)

| 항목 | 지금 | 근거 |
|---|---|---|
| PR 을 읽는 서버 코드 | 없음 | lib/ 에 GitHub API 클라이언트·`gh pr` 호출 없음 |
| Keeper 상태의 `pr_history` | 늘 빈 목록 | `keeper_status_detail.ml` 이 `.playground_pr_history.jsonl` 을 읽지만, 이 파일을 쓰는 코드가 없다 |
| Keeper GitHub 자격 | 12명이 계정 3개를 나눠 쓴다(anyang-keepers 6, pangyo-preachers 5, jeong-sik 1). App 자격 0명 | `<base-path>/.masc/keepers/*/github-cli/hosts.yml` 의 `user` |
| 등록 저장소 | 3개: figma-mcp·masc(public), wkbl(private) | `/api/v1/repositories`, `gh repo view` |
| masc 열린 PR | 52개(draft 아닌 것 44개: BLOCKED 38, CLEAN 5, DIRTY 1) | GraphQL `pullRequests(states:OPEN)` 의 `mergeStateStatus` |
| 열린 PR 마지막 커밋 author | 52개 중 46개가 `jeong-sik`. Keeper 이름과 같은 것은 1개(`tui-developer`) | GraphQL `commits(last:1){nodes{commit{author{name}}}}` 와 `<base-path>/.masc/config/keepers/*.toml` 비교 |
| Task ↔ PR 연결 필드 | 없음 | backlog `execution_links` 는 operation/session id 뿐 |

계정 하나를 여러 Keeper 가 나눠 써서 PR 작성자 로그인으로는 Keeper 한 명을 가를 수 없다.
git author 이름은 지금 Keeper 마다 제각각이다(`jeong-sik`, `pangyo-preachers`, `gm` 같은 줄임말).
그래서 런타임이 author 이름을 정해 주는 일(§5 의 1번)이 이 RFC 의 선행 조건이다.
`pr_history` 는 쓰는 곳이 없는 필드라 이 RFC 의 첫 PR 에서 지운다.

## 2. 타입

```ocaml
type check_state = Checks_passing | Checks_failing | Checks_running | Checks_none
type review_state = Review_approved | Review_changes_requested | Review_waiting | Review_none
type merge_state = Merge_clean | Merge_conflicting | Merge_unknown

type pull_request = {
  repo_slug : string;         (* owner/repo *)
  number : int;
  title : string;
  head_branch : string;
  draft : bool;
  checks : check_state;       (* statusCheckRollup.state 를 디코드 경계에서 한 번 변환 *)
  review : review_state;      (* reviewDecision 을 같은 방식으로 *)
  merge : merge_state;        (* mergeable: MERGEABLE | CONFLICTING | UNKNOWN *)
  last_commit_author : string option;  (* commits(last:1) 의 author.name. 커밋이 없으면 None *)
  updated_at : float;
}

type repository_pulls =
  | Pulls_not_read              (* 재시작 뒤 첫 읽기 전 *)
  | Pulls_read of { observed_at : float; pulls : pull_request list; undecodable : int }
  | Pulls_failed of { observed_at : float; failure : failure }
  | Pulls_not_github            (* GitHub 가 아닌 remote: 읽지 않는다 *)
```

GitHub 가 모르는 값을 보내면 그 PR 행은 `Checks_none` 으로 접지 않고, `undecodable` 로 센다(RFC-0462).

`merge` 가 있어야 "CI 초록에 승인까지 났지만 충돌이라 못 합침"이 "곧 합쳐짐"과 달라 보인다.
`Merge_unknown` 은 GitHub 가 아직 계산하지 않았다는 뜻이다. 충돌 없음으로 보이지 않는다.

### 2.1 PR 을 Keeper 에 붙이는 규칙

- 비교하는 값: `last_commit_author` 와 등록된 Keeper 이름(`<base-path>/.masc/config/keepers/<name>.toml`).
  문자열이 정확히 같을 때만 붙인다. 대소문자를 무시하거나 앞부분만 맞춰 보지 않는다.
- PR 하나는 많아야 Keeper 하나에 붙는다. 마지막 커밋의 author 가 그 Keeper 다.
  리뷰어 Keeper 가 그 branch 에 커밋을 올리면 PR 은 리뷰어 쪽으로 옮겨 간다.
  한 PR 을 두 Keeper 행에 나눠 보이지 않는다.
- author 가 어느 Keeper 이름과도 같지 않거나 `None` 이면 그 PR 은 버리지 않는다.
  저장소 요약 줄에 "Keeper PR 아님" 수로 센다.
- Keeper 가 다른 branch 로 옮겨 가도 PR 의 커밋은 그대로이므로 PR 은 행에 남는다.

| Tick | Keeper K 가 하는 일 | PR 상태 | Team 행 |
|---|---|---|---|
| 1 | `fix/a` 에서 커밋 후 PR #1 을 연다 | #1 CI 진행 | K · #1 |
| 2 | `fix/b` 로 옮겨 커밋 후 PR #2 를 연다 | #1 리뷰 대기, #2 CI 진행 | K · #1 #2 |
| 3 | `main` 으로 돌아가 다음 Task 를 본다 | #1 충돌, #2 리뷰 대기 | K · #1 #2 |

알고 있는 대가: 런타임이 author 이름을 정하기 전에 올라간 PR 은 author 가 Keeper 이름이 아니다.
그 PR 들은 새 커밋이 올라가기 전까지 "Keeper PR 아님" 으로 센다. 지금 masc 열린 PR 52개 중 51개가 여기에 든다(§1).
GitHub 화면의 "Update branch" 로 만든 merge 커밋도 author 가 운영자 계정이라 같은 일이 생긴다.

## 3. 읽기

- GitHub GraphQL 한 번에 저장소 하나의 열린 PR 을 읽는다(최대 100개, 커서로 이어 읽기).
- 주기: 60초. PR 상태는 사람이 보는 속도로 바뀌고, GraphQL 한 번이 저장소 하나다.
- 결과는 메모리에만 둔다. 재시작하면 다음 읽기까지 `Pulls_not_read` 로 보인다.
  PR 은 GitHub 이 원본이고, 서버가 영속할 사실이 아니다.
- 읽기가 실패해도 목록이 조용히 비지 않는다.
  - 등록 저장소 목록을 못 읽거나 읽기 자체가 예외로 끝나면, 이전 행을 그대로 두고
    `repositories_error` 에 이유를 적는다. 화면은 그 행이 지난 읽기의 것임을 함께 보여 준다.
  - 저장소 하나의 읽기가 실패하면 그 저장소는 `Pulls_failed` 로 바뀌고 실패 이유(권한 없음, 토큰 거부,
    rate limit 등)를 말한다. 빈 목록으로 보이지 않는다.

### 3.1 rate limit

rate limit 은 이 서버만의 몫이 아니다. `pr_reader` 계정 하나의 몫이고, 같은 계정을 쓰는
Keeper 들의 `gh` 호출과 나눠 쓴다. 폴링은 3개 저장소 × 시간당 60회 = 180 point 로,
시간당 5000 point 의 약 4% 다.

- GitHub 가 `retry-after` 를 보내면 그 시간을 먼저 따른다. 403 에 `retry-after` 가 붙으면
  secondary rate limit 으로 본다.
- `retry-after` 가 없으면 `x-ratelimit-reset` 시각까지 기다린다.
- 기다리는 동안은 요청을 보내지 않고, 그 저장소는 `Pulls_failed` 의 `Rate_limited` 로 GitHub 가 준 시각을 싣는다.
- GitHub 가 시각을 주지 않으면 우리가 만든 대기 시간을 넣지 않고 다음 60초 주기에 다시 묻는다.

## 4. 자격 증명 — B 로 결정 (2026-09-23 운영자)

서버는 runtime.toml `[repositories] pr_reader = "<keeper>"` 가 가리키는 Keeper 의
`github-cli/hosts.yml` 토큰으로 읽는다. 검토한 선택지:

| 선택지 | 장점 | 단점 |
|---|---|---|
| A. 운영자의 `gh auth token` 을 서버가 읽기마다 호출 | 설정 없음. 운영자가 이미 로그인해 있다 | 서버가 `gh` 실행 파일과 운영자 로그인에 기대게 된다 |
| B. runtime.toml `[repositories] pr_reader = "<keeper>"` 로 한 Keeper 의 `github-cli/hosts.yml` 을 쓴다 | 이미 있는 Keeper 자격을 재사용. 경로 하드코딩 없음 | 그 Keeper 의 토큰 권한에 묶인다 |
| C. GitHub App 설치 토큰(`keeper_github_app_broker`) | 권한이 저장소 단위로 좁다 | 지금 App 자격을 가진 Keeper 가 없다 |

B 를 고른 이유: 새 환경변수나 새 비밀 저장소를 만들지 않는다. 선언이 없거나, 가리킨 Keeper 가
없거나, 그 Keeper 에 `hosts.yml` 토큰이 없으면 PR 섹션이 그 이유를 말하고 읽지 않는다.
다른 자격으로 대신 읽지 않는다.

토큰은 `Keeper_github_identity.stored_token` 으로 읽기마다 새로 읽는다. 복사해 두지 않으므로
그 Keeper 가 다시 로그인하거나 로그아웃하면 다음 읽기가 바로 따라간다.

B 에서 꼬일 수 있는 지점과 처리:

| 지점 | 무엇이 일어나나 | 처리 |
|---|---|---|
| 접근 권한 | 선언한 Keeper 의 계정이 private 저장소(wkbl)에 권한이 없으면 GitHub 가 404 를 준다 | 그 저장소만 `Pulls_failed` 로 이유를 말한다. 빈 목록으로 보이지 않는다 |
| rate limit 공유 | 같은 계정을 쓰는 Keeper 들의 `gh` 호출과 한 몫을 나눠 쓴다 | §3.1 대로 GitHub 가 준 대기 시각을 따른다 |
| 토큰 교체 | 그 Keeper 가 나중에 GitHub App 으로 바뀌면 hosts.yml 토큰이 1시간짜리가 되고, 갱신은 레인이 도구를 띄울 때만 일어난다 | 401 은 "토큰 거부" 로 말하고, hosts.yml 토큰이 바뀔 때까지 다시 묻지 않는다. App 전환 때 이 RFC 를 다시 본다 |

## 5. 스택

| # | 내용 |
|---|---|
| 1 | 런타임이 Keeper 의 도구 프로세스에 `GH_CONFIG_DIR` 과 함께 `GIT_AUTHOR_NAME`·`GIT_COMMITTER_NAME` 을 Keeper 이름으로 넘긴다(별도 PR) |
| 2 | 쓰는 곳 없는 `pr_history` 필드와 감사 스크립트의 같은 이름 읽기 제거 |
| 3 | `[repositories] pr_reader` 선언, GraphQL 읽기, `repository_pulls` 투영, `GET /api/v1/repositories/pulls` |
| 4 | GraphQL 에 `mergeable` 과 `commits(last:1){nodes{commit{author{name}}}}` 을 더하고 §2.1 규칙으로 Keeper 를 붙인다 |
| 5 | TUI: Team 행 끝 PR 표시(충돌 포함)와 저장소별 한 줄 요약("Keeper PR 아님" 수 포함) |

## 6. 하지 않는 것

- Task 와 PR 을 제목·본문 문자열로 잇지 않는다. 마지막 커밋 author 이름과 Keeper 이름의 정확한 비교만 한다.
- Keeper 의 checkout 이 지금 어느 branch 에 있는지(`Keeper_sandbox_control.checkout_scan`)로 PR 을 잇지 않는다.
  checkout 은 지금 HEAD 하나만 말하고, Keeper 가 다음 branch 로 옮기면 PR 이 떨어져 나간다.
- PR 을 서버가 만들거나 머지하지 않는다. 읽기만 한다.
