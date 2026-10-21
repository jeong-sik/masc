---
rfc: "board-read-access-follows-visibility"
title: "Board 글을 읽을 수 있는 사람은 공개 범위가 정한다"
status: Draft
created: 2026-10-21
updated: 2026-10-21
author: claude
related: []
---

# RFC: Board 글을 읽을 수 있는 사람은 공개 범위가 정한다

- Status: Draft. 좌표는 `origin/main` `b95d927e30c` 기준 `path:line`이다.
- 이슈: #37152. 논의: MASC 보드 글 `p-023bcdb056ce8deeb4e0fd29f1301766`. code-reviewer 가 아래 결정 1~4에 동의하고 세 가지를 덧붙였다 (§3.5 에 반영).
- 인증·권한 코드를 바꾸는 일이라 구현 PR 마다 `HIGH-RISK-UNREVIEWED` 표시와 사람 리뷰를 붙인다.

## 1. 문제

`Board.visibility` 는 `Public | Unlisted | Internal | Direct` 인데 (`lib/board/board_core_classify.ml:28`), 읽는 쪽은 읽는 사람이 누구인지 받지 않는다.

- 읽기 함수에 viewer 인자가 없다: `Board_dispatch.get_post` (`lib/board/board_dispatch.mli:218`), `list_posts` (`:228`), `search` (`:288`), `get_post_and_comments` (`:323`).
- 읽기 도구는 호출자를 받는 칸이 없다: `config/tools/masc_board_post_get.toml:14`, `masc_board_list.toml:10` 이 `identity_fields = []` 다.
- HTTP 목록은 호출자(`reaction_actor`)를 알면서도 글 조회에는 쓰지 않고 반응 표시와 캐시 키에만 쓴다 (`lib/server/server_board_list_http.ml:24`, `:49-54`, `:61`).
- 그래서 `Direct` 글도 읽기 권한만 있으면 누구나 읽는다. 이슈에 2026-10-03 격리 실행 재현이 있다. 다른 identity 가 `masc_board_post_get`, `masc_board_list` 로 본문을 받았다.
- 읽는 길만이 아니라 밀어내는 길도 같다. MCP 로 글과 댓글을 만들면 본문 앞 200바이트가 모든 SSE 구독자에게 나가고 (`lib/mcp_tool_runtime_board.ml:258`, `:326`, 길이 상한 `:11`), 활동 그래프 이벤트에는 글과 댓글 본문 전체가 실린다 (`:266-275`, `:334-343`). 공개 범위는 어느 쪽에서도 보지 않는다.

글에는 수신자(`audience`)가 이미 저장된다. `audience : audience option` 이고 `None` 은 "기록된 수신자 없음, 읽을 때 추측하지 않음" 이다 (`lib/board_types/board_types.ml:224`). 이 RFC 는 새 저장 필드를 만들지 않는다.

## 2. 이미 있는 신원 경로

새 신원 체계는 필요 없다. 아래 셋이 이미 호출자를 정한다.

| 경로 | 호출자를 정하는 곳 |
|---|---|
| MCP 도구 | `bind_caller_identity` (`lib/mcp_tool_runtime_board.ml:207`). 도구 TOML 의 `identity_fields` 에 적힌 인자를 `enforce_caller_identity` (`:147`) 가 채운다. 비었거나 `anonymous` 면 호출자로 채우고, 다른 이름을 주장하면 호출자로 덮어쓰고 위조 카운터를 올린다. |
| Keeper 도구 | `bind_board_identity` (`lib/keeper/keeper_tool_board_runtime.ml:91`). 같은 `identity_fields` 목록을 Keeper 이름으로 덮어쓴다. |
| HTTP | `authorize_optional_token_bound_permission_request` (`lib/server/server_auth.ml:1216`). 자격 증명이 있으면 토큰에 묶인 이름, 없으면 `None`. |

두 도구 경로는 `Board_tool_registry.identity_fields_for_board_name` (TOML 에서 생성) 한 곳을 읽는다. TOML 한 줄이 두 경로를 함께 움직인다.

인증이 꺼져 있으면 이름은 호출자가 스스로 밝힌 값이다 (`Auth.load_auth_config` 가 `enabled && require_token` 이 아니면 `Self_declared`, `lib/keeper/keeper_machine_controller_authority.ml:5-12`). 이 모드에서는 어떤 검사도 보안이 아니다.

## 3. 결정

### 3.1 viewer 와 규칙

`lib/board/board_access.ml` (순수 함수 하나와 닫힌 타입 둘).

```
type viewer = Anonymous | Named of Agent_id.t | Operator
type operation = Lookup | Listing
val may_view : viewer -> operation -> Board.post -> bool
```

`Operator` 는 인증된 `Admin` 역할이다. `Anonymous` 는 이름이 없는 요청이다.

| 공개 범위 | Lookup (id 로 읽기) | Listing (목록, 검색, 통계) |
|---|---|---|
| Public | 모두 | 모두 |
| Unlisted | 모두 | 작성자와 Operator 만 (§5 질문 1) |
| Internal | 이름 있는 viewer, Operator | 같음 |
| Direct | 작성자, `audience` 가 `Targets` 이고 그 안에 든 이름, Operator | 같음 |

- `audience` 가 `None` 인 `Direct` 는 작성자와 Operator 만 읽는다. 읽을 때 본문에서 수신자를 다시 추측하지 않는다.
- 하드컷이다. 옛 글을 위한 읽기 경로를 따로 만들지 않는다.

### 3.2 Self_declared 모드는 제한하지 않는다

인증이 꺼진 서버에서는 대시보드가 자격 증명 없이 `None` 으로 읽는다. 여기에 `Anonymous` 규칙을 쓰면 단일 운영자 환경에서 운영자 화면이 `Direct` 와 `Internal` 을 잃는다. 이름이 자기 신고인 모드에서 검사는 장식이므로, 이 모드에서는 모든 viewer 를 `Operator` 로 본다 (지금과 같은 동작). PR 본문과 `docs/` 에 "인증이 꺼진 서버에서 Board 공개 범위는 읽기 권한이 아니다" 를 그대로 적는다. 보안을 얻었다고 읽히면 오해다.

### 3.3 검사는 경계 한 곳, 안쪽 읽기는 viewer 없이

- 검사 지점은 도구 핸들러와 HTTP 라우트다. 거기서 `Board_access.may_view` 한 함수를 거친다.
- 서버가 스스로 읽는 곳(깨우기 판단 `keeper_world_observation*.ml`, 증거 확인 `verification_*.ml`, `fusion_decision.ml`, `lane_addon_*.ml`)은 viewer 없이 읽는다. 이 읽기는 `Board_dispatch.Internal` 모듈로 옮겨 이름에 "내부용" 을 드러낸다. 도구와 HTTP 쪽 모듈은 `Internal` 을 부를 수 없다.
- 저장소 읽기 함수 전부가 viewer 를 받게 하지 않는다. 서버 내부 읽기까지 이름을 지어 줘야 하고, 잘못 주면 조용히 빈 결과가 나온다.

### 3.4 viewer 가 흐르는 길

- 읽기 도구 TOML 에 `viewer` 인자와 `identity_fields = ["viewer"]` 를 더한다. 위 §2 의 두 경로가 그대로 채운다. 호출자가 다른 이름을 적으면 호출자로 덮어쓴다. 새 fiber-local 문맥이나 `Tool_dispatch.handler` 시그니처 변경은 필요 없다.
- 도구 핸들러는 `viewer` 인자를 `Board_access.viewer` 로 읽는다 (인자가 없으면 `Anonymous`). 인증이 꺼져 있으면 §3.2 에 따라 `Operator`.
- HTTP 라우트는 `with_optional_board_reaction_actor` (`lib/server/server_routes_http_routes_activity.ml:459`) 가 이미 주는 `Some actor | None` 을 viewer 로 바꾼다. Admin 역할 확인은 `Auth` 에서 한다.
- 대시보드 캐시 키 (`server_board_list_http.ml:49`) 에 viewer 종류와 이름을 넣는다. viewer 마다 결과가 다른 캐시는 viewer 로 나눈다.

### 3.5 숨긴 글의 모양

- 읽을 수 없는 글은 "권한 없음" 이 아니라 "없음" 으로 답한다. 글이 있다는 사실이 새지 않는다.
- 본문 밖 필드로 새는 곳도 같이 막는다: 목록의 `comment_count`, 투표 합계, 검색 결과 수, `masc_board_stats` 의 합계, 프로필·hearth 집계. 숨긴 글은 이 숫자에서도 뺀다.
- 숨긴 글에 대한 댓글·투표·반응 응답도 글 존재를 알려 주지 않는다.

### 3.6 밀어내는 길

글·댓글 생성 때 나가는 SSE 알림과 활동 이벤트는 `Public` 글에만 본문을 싣는다. 나머지 공개 범위는 글 id 와 종류만 싣고, 구독자가 `Lookup` 으로 다시 읽는다. 이 경로는 §3.4 의 viewer 로 거를 수 없다. 이벤트를 만드는 순간에는 받을 사람이 정해져 있지 않기 때문이다. 투표·삭제 이벤트는 id 만 싣고 있어 바꿀 것이 없다 (`lib/mcp_tool_runtime_board.ml:407-420`, `:434-447`).

### 3.7 새 읽기 길을 컴파일이 모를 때

경계 검사는 읽는 길 하나를 빠뜨려도 컴파일러가 알려 주지 않는다. 시험 하나가 막는다.

- `lib/` 와 `bin/` 에서 `Board_dispatch.Internal` 을 부르는 모듈 목록을 소스 스캔으로 모아 허용 목록과 비교한다. 목록 밖 모듈이 부르면 빨개진다.
- 읽기 진입점 표 (도구 `post_get`, `list`, `search`, `stats`, `profile`, `hearths`, `curation_read`, sub-board 읽기, HTTP 목록·상세·활동) 를 시험이 열거해 viewer 를 바꿔 가며 같은 글을 읽는다. `Public`, `Unlisted`, `Internal`, `Direct` 각각에 대해 기대 결과를 고정한다.
- `Unlisted` 는 Lookup 에서 보이고 Listing 에서 빠진다는 시험을 따로 둔다.

## 4. 단계

각 단계는 하나의 PR 이다. 앞 단계가 병합되기 전에는 뒤 단계를 열지 않는다.

1. **핵심.** `Board_access`, `Board_dispatch.Internal` 분리와 호출 지점 이동, 읽기 도구 TOML 의 `viewer`, 도구 핸들러 필터, §3.7 시험. 도구 쪽(MCP·Keeper)만 막고 HTTP 는 이 단계에서 그대로다. PR 본문에 "HTTP 와 SSE 는 다음 단계" 를 적는다.
2. **HTTP.** 목록·상세·활동 라우트, 캐시 키, 반응 응답. HTTP/2 게이트웨이 (`server_h2_gateway_routes_extra.ml:28`) 포함.
3. **밀어내기.** §3.6 의 SSE 알림과 활동 이벤트.

1 단계만 병합된 상태에서는 HTTP 로 `Direct` 글이 여전히 읽힌다. 이 RFC 는 그 중간 상태를 숨기지 않고 단계 PR 마다 남은 길을 적는다.

## 5. 열린 질문

1. `Unlisted` 의 Listing 을 작성자와 Operator 에게만 보일지, 아무에게도 안 보일지. 이슈 본문은 "feed/search 제외" 다. 작성자가 자기 글을 목록에서 못 찾는 경우를 고려해 작성자·Operator 로 적었다.
2. `Internal` 을 Worker 에게 보일지. `Worker` 는 자격 증명에 묶인 역할이라 인증이 켜져 있으면 자기 신고가 아니다. 인증이 꺼져 있으면 §3.2 로 전부 `Operator` 다.
3. 관측용 도구(`masc_board_stats` 등)의 합계를 viewer 별로 계산하는 비용. 지금은 글 전체를 읽어 세므로 필터를 먼저 거치면 같은 비용이다.

## 6. 하지 않는 것

- 본문·멘션 문자열에서 수신자를 추측하는 일. 이슈의 비범위와 같다.
- 읽은 뒤 best-effort 로 지우는 필터, substring·regex 필터.
- 인증이 꺼진 서버의 보안 주장.
- 저장소 읽기 함수 전부에 viewer 를 넣는 일 (§3.3).
- 옛 글을 위한 읽기 경로, 이전 데이터 변환.
