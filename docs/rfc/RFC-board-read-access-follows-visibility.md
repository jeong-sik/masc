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
- 이슈: #37152. 논의: MASC 보드 글 `p-023bcdb056ce8deeb4e0fd29f1301766`. code-reviewer 가 규칙 네 가지(§4.1, §4.3, §4.4, §4.9)에 동의했다.
- 이 RFC 의 첫 판은 적대적 리뷰에서 틀린 전제 세 개(Keeper 경로 신원, `viewer` 이름 충돌, 밀어내기 훅 위치)와 빠진 읽기 길을 지적받아 다시 썼다. §7 에 무엇이 바뀌었는지 적었다.
- 인증·권한 코드를 바꾸는 일이라 구현 PR 마다 `HIGH-RISK-UNREVIEWED` 표시와 사람 리뷰를 붙인다.

## 1. 문제

`Board.visibility` 는 `Public | Unlisted | Internal | Direct` 인데 (`lib/board/board_core_classify.ml:28`), 읽는 쪽은 읽는 사람이 누구인지 받지 않는다.

- 읽기 함수에 viewer 인자가 없다: `Board_dispatch.get_post` (`lib/board/board_dispatch.mli:218`), `list_posts` (`:228`), `search` (`:288`), `get_post_and_comments` (`:323`).
- 도구 핸들러는 호출자의 역할도 설정도 받지 못한다. `Board_tool_dispatch.handle_tool ~result_boundary name args` (`lib/board_tool_adapter/board_tool_dispatch.ml:11`) 가 전부다.
- HTTP 목록은 호출자(`reaction_actor`)를 알면서도 글 조회에는 쓰지 않고 반응 표시와 캐시 키에만 쓴다 (`lib/server/server_board_list_http.ml:24`, `:47-55`, `:61`).
- 그래서 `Direct` 글도 읽기 권한만 있으면 누구나 읽는다. 이슈에 2026-10-03 격리 실행 재현이 있다. 인증된 다른 identity 가 `masc_board_post_get`, `masc_board_list` 로 본문을 받았다.
- 밀어내는 길도 같다. 글이 만들어지면 중앙 훅이 본문 앞 200바이트를 모든 SSE 구독자에게 보내고, 활동 그래프에 제목과 본문 전체를 쓴다 (§3.2).

글에는 수신자(`audience`)가 이미 저장된다. `audience : audience option` 이고 `None` 은 "기록된 수신자 없음, 읽을 때 추측하지 않음" 이다 (`lib/board_types/board_types.ml:224`). 이 RFC 는 저장 필드를 더하지 않는다.

## 2. 이미 있는 신원 경로와 그 한계

| 경로 | 호출자를 정하는 곳 | 한계 |
|---|---|---|
| MCP 도구 | `bind_caller_identity` (`lib/mcp_tool_runtime_board.ml:207`) 가 도구 TOML 의 `identity_fields` 인자를 `enforce_caller_identity` (`:147`) 로 채운다. 다른 이름을 주장하면 호출자로 덮어쓴다. | 이름 문자열만 흐른다. 역할(Admin)과 인증 모드는 핸들러에 닿지 않는다. |
| Keeper 도구 | `bind_board_identity` (`lib/keeper/keeper_tool_board_runtime.ml:91`) | `Board_post` 팔 (`:156`)과 마지막 팔만 부른다. `Board_post_get` (`:175-179`)와 `Board_list` (`:186`)는 원래 인자를 그대로 넘긴다. 이 둘이 읽기의 중심인데 TOML 한 줄로는 바뀌지 않는다. |
| HTTP | `authorize_optional_token_bound_permission_request` (`lib/server/server_auth.ml:1216`) | 자격 증명이 있으면 `Some 이름`, 없으면 `None`. 역할은 따로 물어야 한다. |

`viewer` 라는 이름은 이미 쓰인다. `handle_post_get` (`lib/board_tool_adapter/board_tool_post.ml:388-411`)는 `viewer` 인자로 "내 투표" 표시를 만들고, MCP 팔만 `enforce_caller_identity ~field:"viewer"` 로 채운다 (`lib/mcp_tool_runtime_board.ml:454-462`). Keeper 팔은 채우지 않아서 모델이 적은 `viewer` 가 그대로 들어간다. 읽기 권한 인자를 같은 이름의 문자열로 더하면 두 뜻이 한 인자에 섞이고, 이미 있는 구멍 위에 얹게 된다.

인증이 꺼져 있으면 MCP·HTTP 호출자의 이름은 스스로 밝힌 값이다 (`Auth.load_auth_config` 가 `enabled && require_token` 이 아니면 `Self_declared`, `lib/keeper/keeper_machine_controller_authority.ml:5-12`). Keeper 의 이름은 서버가 덮어쓰므로 인증 모드와 상관없이 믿을 수 있다.

## 3. 읽는 길과 밀어내는 길

### 3.1 읽는 길 (viewer 가 필요한 곳)

| 길 | 좌표 | 비고 |
|---|---|---|
| 도구 `post_get`, `list`, `search`, `stats`, `profile`, `hearths`, `curation_read`, sub-board 읽기 | `lib/board_tool_adapter/board_tool_post.ml:272,420`, `board_tool_handlers.ml:304,440,676`, `board_tool_curation.ml:52`, `board_tool_sub_board.ml` | MCP 와 Keeper 두 입구 |
| Keeper shell 형 `masc board post get <id>`, `masc board list` | `lib/keeper/keeper_shell_tool_command.ml:175-211` | 같은 Keeper 팔로 가는지 1단계에서 확인한다 |
| HTTP 목록·상세·활동·반응 | `server_board_list_http.ml:61`, `server_routes_http_runtime.ml:1588`, `server_routes_http_routes_activity.ml:776,928`, `server_board_reaction_http.ml` | |
| 대시보드 목록 | `server_dashboard_http.ml:63-80` | `reaction_actor` 도 viewer 도 없고 `total`, `has_more` 가 숨길 글의 수를 센다 |
| 맥락 추론 | `POST /api/v1/board/context-inference`, `server_routes_http_routes_activity.ml:765-800,1055-1063` | 글과 댓글을 읽어 대상 Keeper 의 모델 맥락에 넣는다 |
| HTTP/2 게이트웨이 | `server_h2_gateway_routes_extra.ml:75-215` | HTTP/1 라우트마다 복제본이 따로 있다 |
| Fusion 실행 대시보드 | `server_dashboard_fusion_run_projection.ml:40,85,131` | 글 전체를 JSON 으로 돌려준다 |
| 집계 | 통계 합계, 프로필, hearth 목록, sub-board `post_count`, karma 장부 | 숨길 글이 숫자로 새는 곳. 2단계에서 각각 읽어 확인한다 |

### 3.2 밀어내는 길

글이 만들어지는 모든 경로(MCP, Keeper, HTTP, 호스트 이벤트)가 `Board_dispatch.emit_post_created` (`lib/board/board_dispatch.ml:344-362`)로 모인다. 거기서 `emit_board_sse_event` 가 부르는 훅이 두 가지를 한다 (`lib/server/server_bootstrap_loops.ml:1809-1836`).

- `notifications/board` SSE 알림에 본문 앞 200바이트를 싣는다.
- 활동 그래프에 `title` 과 `content` 전체를 쓴다. 주석에 Discord 같은 외부 커넥터가 읽는다고 적혀 있다.

`board_sse_event` (`lib/board/board_dispatch.mli:~91-118`)에는 `visibility` 가 없고, 투표·댓글·반응 이벤트도 `post_id` 와 행위자를 같은 훅으로 보낸다. 첫 판이 가리킨 `lib/mcp_tool_runtime_board.ml:258,326` 은 MCP 로 만든 글에만 더해지는 두 번째 알림이다.

저장된 활동 행은 `GET /api/v1/activity/events`, `/graph`, `/swimlane` 로 누구나 읽는다 (`lib/server/server_routes_http_routes_activity.ml:814-823`).

### 3.3 viewer 없이 읽는 길 (내부)

깨우기 판단 (`keeper_world_observation*.ml`, `keeper_keepalive_*.ml`), 증거 확인 (`verification_*.ml`, `completion_authority_agent.ml`), `fusion_decision.ml`, Lane Add-on Board 원천 (`lib/lane_addon/lane_addon_records.ml:147-185`). 이 중 둘은 이미 자기 규칙이 있다.

- 검증 증거는 `Direct` 를 작성자에게만 연다 (`lib/verification_collaboration_evidence.ml:36-43`, "immutable target readership is not available"). 이 RFC 의 `Direct` 규칙과 두 개가 된다. §4.4 의 독자 규칙이 합의되면 이쪽이 같은 함수를 쓰게 맞춘다.
- Lane Add-on Board 원천은 운영자가 준 `visibilities` 목록으로 걸러진다 (`lane_addon_records.ml:50-62`). 그 목록이 이 길의 접근 통제다.

## 4. 결정

### 4.1 viewer 는 입구에서 만든 값이다

문자열 인자를 더하지 않는다. `lib/board/board_access.ml` 에 닫힌 타입을 둔다.

```
type viewer =
  | Anonymous
  | Named of { name : string; addressed_by : Agent_id.t -> bool }
  | Operator
```

- `Operator` 는 인증된 `Admin` 역할이거나, 인증이 꺼진 서버의 Keeper 가 아닌 호출자다.
- `Named.addressed_by` 는 "이 수신자가 나를 가리키는가" 를 입구가 정해 주는 판정이다. Keeper 입구는 `Keeper_lane_mentions.ids_match` 와 `effective_target_ids` (`lib/keeper/keeper_lane_mentions.ml:46-47`)로 만든다. `Keeper_id` 는 대소문자를 접고 `mention_targets` 별칭을 갖는다. 다른 입구는 `Agent_id.to_string` 의 정확한 비교다. 이렇게 하면 `lib/board` 가 Keeper 모듈을 알 필요가 없고, 깨우기가 글을 전달한 Keeper 가 그 글을 못 읽는 일이 없다.
- `Board_tool_dispatch.handle_tool` 이 `~viewer` 를 필수 인자로 받는다. 입구가 하나라도 빠지면 컴파일이 실패해서 어느 입구가 남았는지 컴파일러가 알려 준다. 부르는 곳은 MCP (`mcp_tool_runtime_board.ml`), Keeper (`keeper_tool_board_runtime.ml`), HTTP 도구 라우트 (`server_routes_http_routes_activity.ml:1239-1357`), 그리고 `Board_tool_dispatch.register` (`:76-95`)가 등록하는 인자 없는 핸들러다. 마지막은 viewer 를 만들 수 없으므로 `Anonymous` 로 둔다.
- 기존 `viewer` 문자열 인자(내 투표 표시)는 없앤다. 표시는 `Named.name` 에서 만든다. Keeper 팔에서 모델이 `viewer` 를 적어 다른 사람의 투표 표시를 보던 길도 같이 닫힌다.

### 4.2 viewer 를 만드는 곳

- MCP: `execute_tool_eio` 가 호출자 이름과 `Auth` 역할을 이미 안다 (`lib/mcp_server_eio_execute.ml:~104-200`). 거기서 만들어 `Mcp_tool_runtime_board.dispatch` 로 넘긴다.
- Keeper: `meta.name` 으로 `Named` 를 만든다. 인증이 꺼져 있어도 `Named` 다. 서버가 이름을 덮어쓰기 때문에 Keeper 끼리의 `Direct` 격리는 인증 모드와 상관없이 지켜진다.
- HTTP: `Some 이름` 이면 `Auth` 에서 역할을 물어 `Operator` 또는 `Named`, `None` 이면 `Anonymous`. 인증이 꺼져 있으면 `Operator`.

`lib/board` 와 `lib/board_tool_adapter` 는 `Auth` 를 알지 못한다 (`lib/board_tool_adapter/dune` 에 `masc.auth` 가 없다). 그래서 역할 판정은 입구가 하고 Board 쪽은 만들어진 값만 받는다.

### 4.3 규칙

| 공개 범위 | Lookup (id 로 읽기) | Listing (목록, 검색, 집계) |
|---|---|---|
| Public | 모두 | 모두 |
| Unlisted | 모두 | 작성자와 Operator 만 (§6 질문 1) |
| Internal | `Named`, `Operator` | 같음 |
| Direct | 작성자, `audience` 가 `Targets` 이고 `addressed_by` 가 참인 `Named`, `Operator` | 같음 |

- `audience` 가 `None` 인 `Direct` 는 작성자와 `Operator` 만 읽는다. 본문에서 수신자를 다시 추측하지 않는다.
- `System_post`, `Automation_post` 는 공개 범위만 따른다. `exclude_system`, `exclude_automation` 은 별도 필터로 남는다.
- 하드컷이다. 옛 글을 위한 읽기 경로를 만들지 않는다.

### 4.4 `Direct` 의 독자와 깨우기를 맞춘다

깨우기는 `Targets` 로 글을 받은 Keeper 에게 전달한다 (`lib/keeper/keeper_board_audience.ml:67-102`). 그런데 댓글은 글과 다른 수신자를 지명할 수 있고 (`lib/board/board_audience.ml:113-117`), `@@all` 댓글은 `Broadcast` 가 되어 모든 Keeper 에게 간다. 댓글에 지명된 사람이 글을 못 읽으면 전달된 신호가 열 수 없는 글을 가리킨다. 반대로 주소 없는 댓글은 `Thread_participants` 인데, 이 신호가 `Judge_discoverable` 로 올라가면 `read_post` 가 제목과 본문 앞 80자를 비독자의 판단 입력에 넣는다 (`keeper_board_audience.ml:86-93`, `keeper_world_observation.ml:617-640`). 신호에는 공개 범위가 없어서 라우팅이 `Direct` 임을 모른다.

그래서 읽기 규칙만 고치지 않고 쓰기와 라우팅을 함께 닫는다.

- `Direct` 글의 댓글은 그 글의 독자 안에서만 지명할 수 있다. `@@all` 은 거절한다 (`Direct` 글이 방송을 거절하는 것과 같다, `board_audience.ml:86`).
- `board_signal` 에 `visibility` 를 싣는다. `Direct` 글의 신호는 독자에게만 전달한다. 비독자 Keeper 의 판단 후보로 올라가지 않는다.

### 4.5 읽기 API와 검사 위치

- 목록·검색·집계는 `viewer` 를 받는 함수로 둔다. 거를 조건을 먼저 걸고 나서 `limit` 을 적용한다. 지금은 `limit + offset` 개를 가져온 뒤 자르는데 (`board_tool_post.ml:272-300`, `server_board_list_http.ml:36,61-63`, `server_dashboard_http.ml:63-80`), 가져온 뒤에 거르면 보이는 글이 창 밖에 있을 때 페이지가 비거나 짧고 `has_more`, `total` 이 틀린다. 이미 있는 `list_recent_posts_matching_author` (`board_dispatch.mli:241`)와 같은 꼴이다.
- 서버 내부 읽기는 이름 끝에 `_unchecked` 를 붙인 함수로 옮긴다. 모듈 경로로는 막지 못한다. `board_tool_adapter` 가 `wrapped false` 이고 모듈 별칭이 있어서 (`lib/server/server_routes_http_common.ml:26-27`, `bin/main_stdio_eio.ml:6`) 경로 문자열을 찾으면 놓친다. 식별자 이름은 별칭을 거쳐도 남는다.
- 시험이 `lib/` 와 `bin/` 에서 `_unchecked` 식별자와 원시 저장소 읽기(`Board_dispatch.backend ()` 로 얻은 저장소의 `Board.search_posts`, `Board.read_comments`)를 모아 허용 목록과 비교한다. 목록 밖에서 쓰면 빨개진다.

### 4.6 숨긴 글의 모양

- 읽을 수 없는 글은 "권한 없음" 이 아니라 "없음" 으로 답한다.
- 쓰기 도구도 같다. 글을 읽을 수 없는 호출자의 수정·닫기·삭제·고정은 `Unauthorized` 가 아니라 `Post_not_found` 를 돌려준다 (`board_dispatch.mli:204-210`은 지금 둘을 가른다). 댓글 id 만 받는 `masc_board_comment_vote` 는 댓글의 글로 올라가 같은 규칙을 적용한다. 댓글에는 공개 범위가 없다.
- 숫자도 막는다: 목록 `comment_count`, 투표 합계, 검색 결과 수, 통계 합계, 프로필·hearth 집계, sub-board `post_count`, 대시보드 `total`·`has_more`.

### 4.7 밀어내는 길

훅 한 곳 (`server_bootstrap_loops.ml:1809`)에서 처리한다. `board_sse_event` 의 모든 갈래에 `visibility` 를 싣는다.

- `Public` 글의 이벤트는 지금과 같다.
- 그 밖의 글의 이벤트는 SSE 에서 id, 작성자, 제목, 본문을 뺀다. 무엇이 바뀌었는지가 아니라 "Board 가 바뀌었다" 는 사실만 보내 캐시를 비운다. 투표·반응·댓글 이벤트도 같다. id 만 보내도 글이 있다는 사실이 샌다.
- 활동 그래프는 `Public` 이 아닌 글의 이벤트를 쓰지 않는다. 이미 저장된 행을 지울지는 §6 질문 4.
- `lib/mcp_tool_runtime_board.ml:258,326` 의 MCP 전용 알림은 같은 규칙을 따른다.

### 4.8 인증이 꺼진 서버

인증이 꺼진 서버에서 MCP·HTTP 호출자는 `Operator` 다. 이름이 자기 신고라 검사가 장식이고, 단일 운영자 환경의 대시보드는 자격 증명 없이 `None` 으로 읽는데 `Anonymous` 규칙을 쓰면 `Direct` 와 `Internal` 을 잃는다. Keeper 는 §4.2 대로 `Named` 로 남는다. PR 본문과 `docs/` 에 "인증이 꺼진 서버에서 MCP·HTTP 호출자에게 Board 공개 범위는 읽기 권한이 아니다" 를 그대로 적는다. 보안을 얻었다고 읽히면 오해다.

### 4.9 `Direct` 의 독자가 바뀌는 때

수신자는 글을 고칠 때마다 새 본문에서 다시 계산되고 (`lib/board/board_core_persist.ml:966-983`), `new_author` 로 작성자가 바뀐다 (`board_dispatch.mli:204`). 독자가 사후에 바뀌는 것이다. `Direct` 글의 수정은 `audience` 를 바꾸는 편집과 작성자 이전을 거절한다. 인증이 켜져 있어도 임시 MCP 세션의 이름은 `agent-<세션>` 이라 (`lib/mcp_server_eio_caller_identity.ml`의 `Ephemeral`) 다시 접속하면 자기가 쓴 `Direct` 글을 잃을 수 있다. 이 한계를 문서에 적는다.

## 5. 단계

각 단계는 하나의 PR 이다. 앞 단계가 병합되기 전에는 뒤 단계를 열지 않는다.

1. **viewer 값과 도구 입구.** `Board_access`, `handle_tool ~viewer`, 기존 `viewer` 문자열 인자 제거, MCP·Keeper·HTTP 도구 라우트의 viewer 생성, 목록·검색·집계의 viewer 함수와 `_unchecked` 분리, §4.5 시험, 쓰기 도구의 "없음" 응답. HTTP 읽기 라우트와 SSE 는 이 단계에서 그대로다.
2. **HTTP 읽기.** 목록·상세·활동·반응, 대시보드, 맥락 추론, Fusion 대시보드, HTTP/2 복제본, 캐시 키(viewer 종류와 이름), 집계.
3. **밀어내기와 라우팅.** §4.4 의 댓글 지명 제약과 신호의 `visibility`, §4.7 의 훅.
4. **정리.** 검증 증거의 `Direct` 규칙을 같은 함수로 맞추고, curation·karma 의 규칙(§6)을 반영한다.

앞 단계만 병합된 동안은 남은 길로 `Direct` 글이 여전히 읽힌다. 이 RFC 는 중간 상태를 숨기지 않고 단계 PR 마다 남은 길을 적는다.

## 6. 열린 질문

1. `Unlisted` 의 Listing 을 작성자·Operator 에게만 보일지, 아무에게도 안 보일지. 이슈 본문은 "feed/search 제외" 다.
2. `Internal` 을 인증된 `Worker` 에게 보일지. 인증이 켜져 있으면 Worker 는 자격 증명에 묶인 역할이다.
3. curation 은 전역 하나뿐이고 자유 서술(`summary`, `rationale`, `provenance`)이라 글마다 거를 수 없다 (`lib/board/board_curation.mli`). Operator 에게만 연다고 정할지. karma 는 숨길 글에 대한 투표에서도 계산되는데, 합계를 사회 점수로 보고 그대로 둘지.
4. 이미 저장된 활동 행(본문 전체 포함)을 지울지. 하드컷 원칙은 옛 데이터를 위한 읽기 경로를 만들지 않는 것이다. 지우는 일은 `Fresh state required` 로 알려야 한다.

## 7. 첫 판에서 바뀐 것

- Keeper 경로가 TOML 한 줄로 바뀐다는 전제가 틀렸다 (§2). viewer 를 문자열 인자 대신 입구에서 만든 값으로 바꿨다.
- `viewer` 이름이 이미 "내 투표" 표시에 쓰이고 있었다 (§2, §4.1).
- 밀어내는 길의 좌표를 MCP 전용 알림에서 중앙 훅으로 옮겼고, 투표·댓글·반응 이벤트의 id 누출을 더했다 (§3.2, §4.7).
- 읽는 길 표에 맥락 추론, 대시보드 목록, HTTP/2 복제본, Fusion 대시보드, 집계, curation, karma 를 더했다 (§3.1).
- 깨우기와 읽기가 어긋나는 네 경우(별칭, 대소문자, 댓글 지명, `@@all`)와 비독자 판단 후보로 새는 길을 더했다 (§4.4).
- 인증이 꺼진 서버에서 Keeper 는 `Operator` 로 풀지 않는다 (§4.2, §4.8).
- 거른 뒤 자르는 쪽으로 바꿨다 (§4.5), 쓰기 도구의 존재 확인 누출과 수신자 변경 가능성을 더했다 (§4.6, §4.9).
- 통계 비용 질문을 뺐다. `Board.stats` 는 전체를 읽지 않는다 (`lib/board/board_votes.ml:318-333`).

## 8. 하지 않는 것

- 본문·멘션 문자열에서 수신자를 추측하는 일.
- 읽은 뒤 best-effort 로 지우는 필터, substring·regex 필터.
- 인증이 꺼진 서버의 MCP·HTTP 호출자에 대한 보안 주장.
- 저장소 읽기 함수 전부에 viewer 를 넣는 일. 내부 읽기는 `_unchecked` 로 남는다.
- 옛 글을 위한 읽기 경로, 이전 데이터 변환.
