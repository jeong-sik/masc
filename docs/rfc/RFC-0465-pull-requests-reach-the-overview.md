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
2. PR 을 Keeper 에 붙이는 기준은 **branch 이름 하나**다. PR 의 head branch 가 Keeper 의
   repository checkout branch(`repository_checkouts[].branch`)와 같으면 그 Keeper 의 PR 이다.
3. TUI 는 Team 행 끝에 PR 번호와 상태(CI 통과·실패·진행, 리뷰 대기, draft)를 붙이고,
   Team 아래에 저장소별 한 줄 요약을 둔다.

## 1. 기준선 (2026-09-23)

| 항목 | 지금 | 근거 |
|---|---|---|
| PR 을 읽는 서버 코드 | 없음 | lib/ 에 GitHub API 클라이언트·`gh pr` 호출 없음 |
| Keeper 상태의 `pr_history` | 늘 빈 목록 | `keeper_status_detail.ml` 이 `.playground_pr_history.jsonl` 을 읽지만, 이 파일을 쓰는 코드가 없다 |
| Keeper GitHub 자격 | 12명 모두 공유 계정 `hosts.yml`, App 자격 0명 | `~/.masc/keepers/*/github-cli/hosts.yml` |
| 등록 저장소 | 3개 (figma-mcp, masc, wkbl) | `/api/v1/repositories` |
| masc 열린 PR | 44개 | `gh pr list` |
| Task ↔ PR 연결 필드 | 없음 | backlog `execution_links` 는 operation/session id 뿐 |

공유 계정이라 PR 작성자 로그인으로는 Keeper 를 가를 수 없다. 그래서 branch 로 붙인다.
`pr_history` 는 쓰는 곳이 없는 필드라 이 RFC 의 첫 PR 에서 지운다.

## 2. 타입

```ocaml
type check_state = Checks_passing | Checks_failing | Checks_running | Checks_none
type review_state = Review_approved | Review_changes_requested | Review_waiting | Review_none

type pull_request = {
  repo_slug : string;         (* owner/repo *)
  number : int;
  title : string;
  head_branch : string;
  draft : bool;
  checks : check_state;       (* statusCheckRollup.state 를 디코드 경계에서 한 번 변환 *)
  review : review_state;      (* reviewDecision 을 같은 방식으로 *)
  updated_at : float;
}

type repository_pulls =
  | Pulls_not_read              (* 재시작 뒤 첫 읽기 전 *)
  | Pulls_read of { observed_at : float; pulls : pull_request list }
  | Pulls_failed of { observed_at : float; error : string }
  | Pulls_not_github            (* GitHub 가 아닌 remote: 읽지 않는다 *)
```

GitHub 가 모르는 값을 보내면 그 PR 행은 `Checks_none` 으로 접지 않고, 디코드 실패로 센다(RFC-0462).

## 3. 읽기

- GitHub GraphQL 한 번에 저장소 하나의 열린 PR 을 읽는다(최대 100개, 커서로 이어 읽기).
- 주기: 60초. PR 상태는 사람이 보는 속도로 바뀌고, GraphQL 한 번이 저장소 하나다.
  rate limit 은 시간당 5000 point 이고 3개 저장소 × 60회 = 180 point 다.
- 결과는 메모리에만 둔다. 재시작하면 다음 읽기까지 `Pulls_not_read` 로 보인다.
  PR 은 GitHub 이 원본이고, 서버가 영속할 사실이 아니다.

## 4. 열린 질문 — 자격 증명

서버가 어느 GitHub 자격으로 읽을지 정해야 한다. 선택지:

| 선택지 | 장점 | 단점 |
|---|---|---|
| A. 운영자의 `gh auth token` 을 서버가 읽기마다 호출 | 설정 없음. 운영자가 이미 로그인해 있다 | 서버가 `gh` 실행 파일과 운영자 로그인에 기대게 된다 |
| B. runtime.toml `[repositories] pr_reader = "<keeper>"` 로 한 Keeper 의 `github-cli/hosts.yml` 을 쓴다 | 이미 있는 Keeper 자격을 재사용. 경로 하드코딩 없음 | 그 Keeper 의 토큰 권한에 묶인다 |
| C. GitHub App 설치 토큰(`keeper_github_app_broker`) | 권한이 저장소 단위로 좁다 | 지금 App 자격을 가진 Keeper 가 없다 |

추천은 B 다. 새 환경변수나 새 비밀 저장소를 만들지 않고, 선언이 없으면 PR 섹션이
"PR reader not declared" 로 말하고 읽지 않는다.

## 5. 스택

| # | 내용 |
|---|---|
| 1 | 쓰는 곳 없는 `pr_history` 필드와 감사 스크립트의 같은 이름 읽기 제거 |
| 2 | `[repositories] pr_reader` 선언, GraphQL 읽기, `repository_pulls` 투영, `GET /api/v1/repositories/pulls` |
| 3 | TUI: Team 행 끝 PR 표시와 저장소별 한 줄 요약 |

## 6. 하지 않는 것

- Task 와 PR 을 제목·본문 문자열로 잇지 않는다. branch 이름 비교만 한다.
- PR 을 서버가 만들거나 머지하지 않는다. 읽기만 한다.
