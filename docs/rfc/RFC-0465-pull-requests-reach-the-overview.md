---
rfc: "0465"
title: "등록 저장소의 열린 PR을 읽고 Keeper에 연결한다"
status: Draft
created: 2026-09-23
updated: 2026-11-09
author: dancer + claude
supersedes: []
superseded_by: null
related: ["tui-measured-operator-home"]
---

# RFC-0465: 등록 저장소의 열린 PR과 Keeper 귀속

이 문서는 서버의 PR 조회와 Keeper 귀속 규칙을 정한다. TUI 목적지는
[운영자 홈 결정](RFC-tui-measured-operator-home.md)을 따른다.

## 0. 서버의 역할

서버는 등록된 저장소 중 설정한 GitHub 호스트의 remote를 가진 저장소에서 열린 PR을 읽는다.
읽은 PR의 상태와 author를 보존하고, author가 등록된 Keeper 이름과 정확히 같으면
그 Keeper에 연결한다. GitHub 로그인이나 현재 checkout의 branch로 연결하지 않는다.

## 1. 정본

- [Repository_pulls](../../lib/repository_pulls.mli): 데이터 타입, Keeper 귀속, JSON 투영과 최신 snapshot.
- [Server_repository_pulls](../../lib/server/server_repository_pulls.mli): GraphQL 조회, 자격 해소와 갱신.
- [조회 구현](../../lib/server/server_repository_pulls.ml): 페이지 크기·author 창·재조회 조건.
- [HTTP route](../../lib/server/server_routes_http_routes_repositories.ml):
  `GET /api/v1/repositories/pulls`는 최신 snapshot의 JSON을 반환한다.

이 문서는 서버가 읽는 사실의 의미를 설명한다. 화면의 행·섹션·배치를 정하지 않는다.

## 2. PR과 조회 상태

PR은 `repo_slug`, `number`, `draft`, `checks`, `review`, `mergeable`, `author`를 가진다.
CI 상태는 PR head의 `statusCheckRollup.state`, 리뷰 상태는 `reviewDecision`,
충돌 여부는 `mergeable`에서 각각 읽는다. `Mergeable_unknown`은 충돌 없음이 아니다.

저장소별 조회 상태는 다음과 같다.

| 상태 | 의미 |
|---|---|
| `Pulls_not_read` | 아직 읽지 않았거나 현재 reader를 사용할 수 없어 읽지 않음 |
| `Pulls_read` | 관측 시각, 읽은 PR 목록, 해석하지 못한 행 수(`undecodable`) |
| `Pulls_failed` | 관측 시각과 조회 실패 원인 |
| `Pulls_not_github` | 설정한 호스트의 지원 remote 형식에 해당하지 않아 읽지 않음 |

GitHub의 알 수 없는 enum이나 필수 필드가 빠진 PR 행은 `undecodable`로 센다.
없는 check나 review 상태로 바꾸지 않는다. 실패와 미조회도 PR이 없는 정상 조회와 구분한다.

### 2.1 PR을 Keeper에 붙이는 규칙

- 최근 커밋 10개를 읽어, 최신 것부터 부모 수가 정확히 하나인 첫 커밋의 `author.name`을 쓴다.
  머지 커밋의 author는 이 귀속에 사용하지 않는다.
- 이 창에 해당 커밋이 없거나 그 커밋의 author 이름이 null이면 `author = None`이다.
  응답 구조가 잘못된 경우는 author 없음으로 처리하지 않고 해당 PR을 `undecodable`로 센다.
- 읽은 author와 등록된 Keeper 이름을 대소문자까지 정확히 비교한다. 이름이 같은 경우에만
  JSON의 `keeper`에 그 이름을 넣는다. 일치하지 않거나 author가 없어도 PR 자체는 목록에 남긴다.
- Keeper 이름 목록을 읽지 못했거나 아직 읽지 않았으면 PR 조회는 계속하되 `keeper`는 null이다.
  snapshot의 `keepers` 상태로 이 경우와 이름이 일치하지 않는 경우를 구분한다.
- Keeper가 다른 branch로 옮겨도 같은 PR의 커밋 author는 변하지 않는다. 반대로 다른 Keeper가
  마지막 단일 부모 커밋을 쓰면 그 이름으로 귀속이 달라질 수 있다.
- CI는 author를 찾은 커밋이 아니라 PR head에서 읽는다. head가 머지 커밋이어도 같다.

귀속은 관측용 연결이며 권한을 증명하지 않는다. 누구나 git author 이름을 설정할 수 있다.
이 author 창은 귀속에 사용할 관측 범위이며 PR 조회 목록이나 Keeper 실행을 제한하지 않는다.

## 3. 읽기와 실패

서버가 시작할 때 한 번 읽고 이후 60초마다 갱신한다. 저장소별로 GraphQL 한 페이지에
최대 100개를 요청하고, 다음 커서가 있으면 이어 읽는다. 같은 페이지 커서가 반복되면
`Response_unreadable`로 끝낸다.

snapshot은 메모리에만 둔다. GitHub가 PR 사실의 원본이며 서버 재시작 뒤에는 새로 읽는다.
한 갱신에서 reader, 등록 저장소, Keeper 이름을 다시 확인한다.

- 등록 저장소 목록을 읽지 못하거나 갱신이 예외로 끝나면 이전 저장소 행을 보존하고
  `repositories_error`에 이유를 남긴다. 보존한 행을 최신 정상 조회로 취급하지 않는다.
- reader를 사용할 수 없으면 다른 자격으로 대신 읽지 않는다. 등록 목록을 읽은 경우 각 GitHub
  저장소는 `Pulls_not_read`이고 `reader`가 이유를 가진다. 이전 정상 PR 목록을 현재 값으로 쓰지 않는다.
- 저장소 하나의 조회가 실패하면 그 저장소는 `Pulls_failed`다. 접근 불가, 토큰 거부,
  rate limit, HTTP·GraphQL·전송·응답 구조 오류를 정상 빈 목록으로 바꾸지 않는다.
- Keeper 이름 목록의 실패는 GitHub 조회를 막지 않는다. 실패 이유는 `keepers`에 보존하고
  귀속은 §2.1처럼 미확인으로 남긴다.

### 3.1 rate limit과 토큰 거부

GitHub가 보낸 `retry-after`를 먼저 따르고, 없으면 `x-ratelimit-reset`을 쓴다.
미래의 대기 시각이 있으면 그때까지 해당 저장소를 다시 요청하지 않고
`Rate_limited { reset_at }`와 처음 실패한 관측 시각을 보존한다.
GitHub가 시각을 주지 않으면 임의의 대기 시간을 만들지 않고 다음 60초 갱신에 다시 묻는다.

401로 거부된 토큰은 같은 GraphQL endpoint에서 같은 토큰인 동안 다시 보내지 않는다.
reader의 토큰은 매 갱신에 다시 읽으며, 토큰이나 endpoint가 달라지면 새 조회를 할 수 있다.
거부된 자격을 비교하는 내부 상태에는 토큰 원문 대신 digest와 endpoint를 보관하고,
이 상태는 JSON 응답에 넣지 않는다.

## 4. 자격 증명

runtime.toml의 `[repositories] pr_reader = "<keeper>"`가 읽기에 사용할 Keeper를 정한다.
새 환경변수나 별도 비밀 저장소를 만들지 않고 기존 Keeper의 GitHub 로그인을 사용한다.

`github_host`의 기본값은 `github.com`, `graphql_url`의 기본값은
`https://api.github.com/graphql`이다. 다른 호스트를 설정하면 그 호스트의 HTTPS GraphQL URL도
명시해야 한다. reader는 설정한 호스트의 토큰을 `Keeper_github_login_lane.stored_token`으로 읽는다.

선언 없음, 잘못된 설정, 없는 Keeper, 읽을 수 없는 토큰은 각각의 `reader` 상태로 남긴다.
원격 Keeper의 로그인도 이 로그인 경계를 통해 해소하며 서버 호스트의 임의 자격으로 대체하지 않는다.
runtime.toml·Keeper 선언·로그인을 매 갱신에 다시 읽으므로 다음 갱신이 변경을 확인한다.

## 5. 범위

서버는 이 경로에서 PR을 생성하거나 병합하지 않는다. Task와 PR을 제목·본문 유사도로
연결하지 않으며, Keeper의 현재 checkout으로 PR 귀속을 추정하지 않는다.
`keeper` 연결, CI·리뷰·충돌 관측만으로 PR의 독립 승인이나 병합 허가가 성립하지 않는다.
