---
rfc: "at-name-resolves-to-declared-recipient"
title: "글 속 @이름은 선언된 받는 사람일 때만 대상이 된다"
status: Active
created: 2026-10-29
updated: 2026-10-29
author: dancer + claude
related: []
---

# RFC — 글 속 `@이름`은 선언된 받는 사람일 때만 대상이 된다

## 0. 요약

글에 백틱 없이 `dune build @check` 라고 쓰면 그 글은 `check` 에게 보낸 글이 된다. `check` 는 받는 사람이 아니라 dune 별칭이다.

- board 에서는 `targets` 글이 된다. Keeper 는 `Discoverable` 글만 주의 판단에 올린다. 이 글에는 `check` 라는 Keeper 가 없어서 아무도 보지 않는다.
- 브로드캐스트에서는 `check` Keeper 를 찾다가 못 찾고 거절한다. 메시지는 저장됐는데 응답은 `ok:false` 다.

"받는 사람인가"를 정하는 곳이 세 군데이고, 어느 곳도 그 이름이 선언된 이름인지 묻지 않는다. 이 RFC 는 기준을 한 곳으로 모은다.

결정은 네 가지다.

1. 글에서 찾은 `@토큰` 은 후보일 뿐이다. 선언된 이름과 맞아야 받는 사람이 된다. (§3.1)
2. 선언된 이름은 Keeper 이름과 `mention_targets` 별칭이다. 사람과 계정 이름이 받는 사람이어야 하면 별칭으로 선언한다. (§3.2)
3. 선언에 없는 이름은 글 속 말이다. 거절하지 않는다. 쓴 사람에게는 응답의 `unresolved` 로 알려 준다. (§3.3)
4. 해석은 한 곳에서 하고, board·브로드캐스트·알림은 해석된 결과를 타입으로 받는다. 글을 다시 읽지 않는다. (§3.4)

결정 D1~D5 는 2026-10-29 에 정했다. (§8)

구현은 스택으로 나누어 올린다. (§6)

## 1. 문제

### 1.1 측정

board 글은 2026-10-29 에 `~/me/.masc` 를 `tools/recipient_replay` 로 돌려 센 값이다 (§7). 브로드캐스트는 같은 날 이슈 #46747 댓글에 적은 값이고, 재생으로 다시 세지 않았다.

board 글(`board_posts.jsonl`, 6,779개):

| 구분 | 글 수 |
|---|---|
| 대상 지정(`targets`) 글 | 686 |
| 그중 시스템 글. 쓰기 경로가 글에서 대상을 읽지 않아 뺐다 | 16 |
| 나머지 | 670 |
| 그중 선언에 없는 이름이 하나라도 든 글 | 169 |
| 그중 든 이름이 모두 선언에 없는 글 | 109 |
| 그 109개 중 `check`·`runtest`·`all` 이 든 글 | 40 |
| 그 109개 중 그 밖의 이름이 든 글 | 72 |

한 글에 둘 다 든 글이 3개여서 40 + 72 − 3 = 109 이다. 이름이 일부만 선언에 없는 글 60개 중 12개는 `check`·`runtest`·`all` 이 든 글이다.

시스템 글은 플랫폼 코드가 쓰고, 글에서 대상을 읽지 않는 규칙은 2026-10-22 에 들어왔다 (#44697, `lib/board/board_audience.ml` 의 `audience_for_post`). 16개는 그보다 앞선 2026-10-05 부터 10-17 사이에 쓴 글이라 기록된 대상이 남아 있다. 지금 쓰기 경로도, 이 RFC 뒤의 쓰기 경로도 이 글들에는 대상을 만들지 않는다.

선언에 없는 이름을 글 수로 세면 `check` 39, `codex-mcp-client` 24, `pangyo-preachers` 21, `be-sleepers` 18, `jeong-sik` 12, `anyang-keepers` 12, `all` 7, `claude-mcp-client` 7, `runtest` 6 순이다. 한 글이 이름을 여러 개 가질 수 있어서 이름별 글 수의 합은 글 수보다 크다. `vincent.dev` 한 글은 선언이 아니라 이름 모양 규칙에 걸린다 (§3.2).

`check`·`runtest`·`all` 은 받는 사람을 쓴 글이 아니다. 그 밖의 이름에는 사람, GitHub 계정, MCP client 이름이 있다. 가짜가 아닐 수 있다.

브로드캐스트(저장된 메시지 3,335개): 멘션이 거절된 메시지가 45개다. 대상은 `check` 26, `runtest` 4, `claude-mcp-client` 4, `codex-mcp-client` 3, `all` 3, 나머지 5개(`12` 등)다. 거절돼도 깨워진 대상은 모두 실제 이름이었다. 결과는 `ok:false` 응답뿐이었다.

### 1.2 지금 구조

받는 사람 후보를 글에서 뽑는 문법은 `Board_addressing` 이다. board 와 Keeper 는 이미 이 문법을 쓰고(이슈 #25601), 브로드캐스트와 board 도구 알림도 PR #46755(2026-10-29 병합)부터 같은 문법을 쓴다. 그 뒤에 "이 이름이 받는 사람인가"를 정하는 곳이 셋이다.

| 진입 | 확인하는 곳 | 기준 | 모르는 이름이면 |
|---|---|---|---|
| board 글·댓글 | `Board_audience.explicit_address_of_text` (`lib/board/board_audience.ml:36`) | `Agent_id.parse`. 영문자·숫자·`.`·`_`·`-` 1~64자, 콜론 하나. 등록부는 보지 않는다 | `targets` 글이 된다. 읽는 Keeper 가 자기 이름과 맞춰 보고 안 맞으면 조용히 버린다 |
| 브로드캐스트(MCP·HTTP) | `resolve_broadcast_mention_target` (`lib/server/server_bootstrap_loops.ml:157`) | Keeper 메타데이터. 이름이 없으면 모든 Keeper 의 `mention_targets` 별칭을 훑는다 (`lib/keeper/keeper_meta_store.ml:489`) | `Rejected Target_not_configured`. 응답 `ok` 가 false 다 (`lib/workspace/workspace_broadcast.ml:198`) |
| gRPC `Broadcast` | `mentions` 필드를 `@이름 ` 글로 바꿔서 위 길로 보낸다 (`lib/server/masc_grpc_service.ml:81`) | 위와 같다 | 위와 같다. 대상이 둘 이상이면 저장하지 않고 거절한다 (`:64`) |

첫 이름은 `Workspace_broadcast` 가 `Board_addressing.routing_target` 으로 고른다 (`lib/workspace/workspace_broadcast.ml:970`). board 도구의 알림도 같은 함수를 부른다 (`lib/mcp_tool_runtime_board.ml:253`).

Keeper 채팅 줄의 `mentions`(`lib/keeper/keeper_lane_mentions.ml`, RFC-0232 §3.3)도 같은 문법으로 후보를 뽑는다. 후보를 모양만 보고 `Keeper_id` 로 바꿔 줄에 기록하고, 읽는 Keeper 가 자기 이름·별칭과 맞춰 본다. 이 RFC 는 이 길을 바꾸지 않는다. (§9)

코드도 이 빈틈을 알고 있다. `lib/board/board_audience.ml:33` 은 "오탈자를 잡으려면 write boundary 에 Keeper 등록부가 필요하다"고 적고 있다.

### 1.3 기준을 더 조이면 안 되는 이유

- 모양: `check` 와 `alice` 는 모양이 같다. 문자 규칙을 조일수록 문자열 분류기만 는다.
- 거절: 글 속 말(`@types/node`, `@check`)을 쓰는 사람이 막힌다. 브로드캐스트의 `ok:false` 가 이미 그 결과다.
- 조용히 버리기: 지금 board 가 이렇게 한다. 오탈자 `@alcie` 도 같은 길로 사라진다.

구분할 수 있는 정보는 선언 하나다. Keeper 이름과 별칭은 이미 설정에 있다.

## 2. 목표와 하지 않는 것

목표

- 받는 사람이 되는 기준이 한 곳에 있다.
- `@check` 같은 글 속 말이 받는 사람이 되지 않는다.
- 선언에 없는 이름을 쓴 사람이 응답에서 본다.

하지 않는 것

- 저장된 글과 메시지의 형식을 바꾸지 않는다. 다만 댓글에는 글처럼 `audience` 를 기록하는 선택 칸을 하나 더한다 (D4, L2b). 옛 글과 옛 댓글의 기록은 그대로 둔다. 과거 데이터를 위한 읽기·변환 코드를 만들지 않는다.
- 새 거절 단계(Gate)를 만들지 않는다.
- 이름이 비슷한지로 오탈자를 맞히지 않는다.
- board 가 `@@all` 을 다루는 방식을 바꾸지 않는다. (§3.4)
- Keeper 채팅 줄의 `mentions` 를 바꾸지 않는다. (§1.2)

## 3. 제안

### 3.1 후보와 받는 사람은 다른 타입이다

```ocaml
(* lib/board_addressing/recipient_resolution.mli *)

(* 글에서 찾은 이름 중 이름 모양인 것. 아직 아무 뜻도 없다. *)
module Candidate : sig
  type t
  val of_string : string -> t option
  val to_string : t -> string
end

type 'recipient resolution =
  { recipients : 'recipient list  (* 글에 쓴 순서, 중복 없음 *)
  ; unresolved : string list      (* 후보였지만 선언에 없는 이름, 쓴 철자 그대로 *)
  }

val resolve :
  equal:('recipient -> 'recipient -> bool)
  -> declared:(Candidate.t -> ('recipient option, 'failure) result)
  -> Candidate.t list
  -> ('recipient resolution, 'failure) result
```

받는 사람 타입(`'recipient`)과 조회 실패 타입(`'failure`)은 부르는 쪽이 정한다. 이 잎 라이브러리는 Keeper 모듈을 부를 수 없다 (§4). 사람과 계정 이름도 Keeper 별칭으로 선언하므로(D2) L2c 의 받는 사람은 선언된 이름 하나이고, board 에서는 그 이름을 소문자로 담은 `Agent_id` 다. Keeper 의 이름이든 별칭이든 같다. 라우터가 기록된 대상을 Keeper 가 답하는 이름과 맞춰 보기 때문이다 (§3.2). `Targets` 가 이미 담는 타입이다. 받는 사람을 만드는 곳은 서버가 넘긴 조회(`Recipient_lookup`)뿐이고, 쓰기 경로는 `resolve` 가 돌려준 값만 `Targets` 에 넣는다. `Targets` 에 Keeper 만 들어가게 타입으로 막으려면 저장된 `audience` 를 읽는 쪽도 바꿔야 해서 L2c 에서 하지 않았다.

`declared` 는 부르는 쪽이 인자로 넘긴다. 전역 설정자나 시험용 우회 함수를 만들지 않는다. `resolve` 는 같은 철자를 한 번만 묻는다. 조회가 실패하면 그 자리에서 실패를 돌려주고 더 묻지 않으며, 그때까지 가른 결과는 버린다.

후보는 글에서 나온 아무 문자열인데, Keeper 메타 파일 이름은 이름 뒤에 접미사를 붙인 것이다 (`lib/core/keeper_runtime_root_entry.ml:21`). 그래서 이름 모양이 아닌 토큰은 후보가 되지 않는다. `Candidate.of_string` 은 ASCII 영문자·숫자·`_`·`-` 로만 된 이름을 받고, 길이는 정하지 않는다 (`Board_addressing.is_routable_target`). 경로 구분자나 `..` 이 든 토큰(`types/node`, `../x`)과 `alice's` 같은 토큰은 `None` 이어서 `declared` 에 닿지 않고 `unresolved` 에도 나오지 않는다.

이름 모양은 필요 조건이다. Keeper 이름 규칙(`Keeper_name.of_string`, `lib/keeper_registry/keeper_id.ml:17`, 128자까지)은 L2c 의 조회가 파일 경로를 만들기 전에 거치고, 이 규칙에 맞지 않는 후보에는 조회 실패가 아니라 `None` 을 돌려준다. 지금은 이 규칙을 거치지 않는 길이 있다. 브로드캐스트의 `resolve_broadcast_mention_target`(`lib/server/server_bootstrap_loops.ml:158`)이 `@이름` 에서 나온 값을 `read_effective_meta` 에 그대로 넘기고, 그 함수는 이름으로 바로 파일 경로를 만든다 (`keeper_meta_path`, `lib/keeper/keeper_types_profile.ml:772`). 이름 뒤에 `.json` 이 붙으므로 이름이 251자 이상이면 파일 이름이 한도(255바이트)를 넘어서 파일 열기가 `ENAMETOOLONG` 으로 실패한다. 브로드캐스트에서 이 실패는 `Deferred Target_state_unavailable` 이고 쓰기 오류가 아니다. L2c 가 같은 길을 그대로 쓰면 D5 때문에 이 실패가 쓰기 오류가 되므로, L2c 는 경로를 만들기 전에 위 이름 규칙을 거친다. board 글은 지금 64자를 넘는 이름을 대상으로 보지 않아서(`Agent_id`) 이런 글도 그냥 쓰인다.

`Keeper_id.t` 는 공백을 없애고 소문자로 바꿀 뿐 문자를 거르지 않는다 (`lib/keeper/keeper_identity.ml:42`). 그래서 타입이 위 제한을 대신하지 않는다.

`resolve` 는 철자를 바꾸지 않고 `declared` 에 넘긴다. 소문자로 바꿔서 Keeper 이름과 별칭에 맞춰 보는 일은 `declared` 가 한다. 별칭 조회가 지금도 이렇게 맞춘다 (`lib/keeper/keeper_meta_store.ml:466`). `@Alice` 와 `@alice` 는 `declared` 가 같은 이름(`alice`)으로 답하고 `resolve` 가 하나로 합친다. `unresolved` 에는 쓴 철자 그대로 나온다.

`None`(선언에 없음)과 `Error`(조회 실패)를 섞지 않는다. 지금 브로드캐스트도 둘을 나눈다. 선언 없음은 `Rejected Target_not_configured`, 조회 실패는 `Deferred Target_state_unavailable` 이다 (`lib/server/server_bootstrap_loops.ml:202`). 조회 실패를 글 속 말로 바꾸면 설정 오류가 조용히 사라진다. 쓰기에서 조회가 실패하면 쓰기를 오류로 돌려주고 아무것도 저장하지 않는다 (D5).

### 3.2 선언의 출처

1. Keeper 이름.
2. Keeper 의 `mention_targets` 별칭 (`.masc/config/keepers/<이름>.toml`).
3. 사람과 계정 이름. 받는 사람이어야 하면 어느 한 Keeper 의 별칭으로 선언한다 (D2).

새 파일이나 새 필드를 만들지 않는다.

선언의 기준은 게시판이 글을 Keeper 에게 보낼 때 쓰는 기준과 같다. 라우터는 Keeper 가 `mention_targets` 를 가지면 그 목록만 주소로 보고, 가지지 않으면 Keeper 이름을 주소로 본다 (`Keeper_lane_mentions.effective_target_ids`). 그래서 `mention_targets` 를 가진 Keeper 가 자기 이름을 목록에 넣지 않았으면 그 이름은 선언이 아니다. 선언으로 치면 아무도 받지 않는 대상이 기록되고 쓴 사람은 그 사실을 알 수 없다. 이 이름은 글 속 말이고 `unresolved` 에 나온다. 별칭은 소문자로 맞춘 이름 그대로 기록한다. 브로드캐스트는 목록과 상관없이 Keeper 이름을 먼저 찾아서 이 기준과 다르다. 지금도 다르고 이 RFC 는 바꾸지 않는다. 2026-10-30 에 읽은 설정 41개는 모두 목록에 자기 이름이 있어서 이 차이로 달라지는 Keeper 는 없다.

별칭 하나는 Keeper 한 명만 가리킨다. 같은 별칭을 둘 이상이 쓰면 지금도 조회가 오류로 끝난다 (`lib/keeper/keeper_meta_store.ml:466`, 오류 문구 `multiple persisted Keepers claim mention_target`). 그래서 `pangyo-preachers` 처럼 Keeper 여럿이 나눠 쓰는 계정은 별칭으로 선언할 수 없다. 이 RFC 는 이 규칙을 바꾸지 않는다.

2026-10-29 에 읽은 Keeper 설정 41개는 모두 `mention_targets` 를 가진다. 36개는 자기 이름뿐이고, 5개(`geek-scout`, `jazz-developer`, `e-masc-the-leader`, `mad-scientist`, `rondo`)가 별칭을 더 가진다. `jeong-sik`, `pangyo-preachers`, `be-sleepers`, `anyang-keepers` 는 어디에도 선언돼 있지 않다.

후보 문법은 영문자·숫자·`_`·`-` 만 이름으로 본다 (§3.1). 그래서 한글이나 공백이 든 별칭은 `@` 로 부를 수 없다. `mad-scientist` 의 `매드사이언티스트`, `geek-scout` 의 `긱스카웃`·`뉴스`, `e-masc-the-leader` 의 `release leader`·`리더`·`release manager`, `rondo` 의 `론도` 가 그렇다. 이 한계는 지금도 같고, 이 RFC 는 바꾸지 않는다. 점이 든 이름은 다르다. board 의 `Agent_id` 는 점을 받아서 지금은 `@vincent.dev` 가 대상으로 기록된다(글 1개). 이 RFC 뒤에는 글 속 말이다. 브로드캐스트와 알림은 이미 점을 받지 않는다. 사람과 계정 이름을 별칭으로 선언할 때(D2)도 이 문자로만 쓴다.

### 3.3 선언에 없는 이름은 글 속 말이다

거절하지 않는다. `@check` 가 든 글은 받는 사람이 없는 글이 된다. board 는 받는 사람이 없는 글에 이미 정해 둔 규칙을 그대로 따른다. 공개·내부 글은 `Discoverable`, 목록 밖(`Unlisted`) 글과 댓글은 `Thread_participants` 다 (`lib/board/board_audience.ml` 의 `audience_for_post`, `audience_for_comment`). `Direct` 글은 받는 사람이 하나는 있어야 해서, 선언된 받는 사람이 없으면 지금처럼 쓰기가 거절된다.

쓴 사람에게는 쓰기 응답에 `unresolved: ["check"]` 를 돌려준다. 응답에만 싣는 값이라 저장 형식은 바뀌지 않는다.

`unresolved` 만 더하면 고친 것이 아니다. 알려 주기만 하고 글은 계속 사라진다. 이 RFC 는 기준(§3.1~§3.2)과 알림(`unresolved`)을 함께 바꾼다.

선언에서 빠진 정상 이름도 글 속 말이 된다. 사람, 계정, MCP client 같은 `check`·`runtest`·`all` 이 아닌 이름이 든 글(72개)이 여기에 걸린다. 그 이름은 지금도 어떤 Keeper 에게도 닿지 않아서(§3.2) 이름으로 지정받아 깨어나는 Keeper 는 달라지지 않는다. 재생에서도 670개 글 모두 지정받는 Keeper 가 같다 (§7). 달라지는 것은 셋이다.

- 든 이름이 모두 선언에 없는 board 글(109개)은 대상 지정 글에서 받는 사람이 없는 글로 바뀐다. 일부만 없는 글(60개)은 받는 사람이 줄어든다.
- 받는 사람이 없는 공개·내부 글은 `Discoverable` 이어서, `board_interests` 가 있는 Keeper 마다 주의 판단 후보가 된다. 글쓴이 자신은 뺀다 (`lib/keeper/keeper_board_audience.ml` 의 `route_for_keeper`). 지금은 대상 지정 글이라 모든 Keeper 가 건너뛴다. 109개는 모두 internal 글이고, 설정 41개 중 38개가 `board_interests` 를 가진다. 재생은 이 후보를 견주지 않는다.
- 브로드캐스트 응답은 `ok:false` 에서 `unresolved` 표시로 바뀐다.

별칭을 나중에 선언해도 이미 쓴 글을 읽을 때 다시 해석하지 않는다. 글에 기록된 `audience` 와 메시지의 받는 사람은 쓸 때 정한 값 그대로다. 선언에 없는 이름이 든 글 169개도 같다. 글에 `audience` 가 기록돼 있으면 제목이나 본문이 바뀐 고치기에서만 그때의 선언으로 다시 정한다. `audience` 가 없는 이전 글은 같은 내용으로 고쳐도 그때의 쓰기 규칙으로 `audience` 를 계산하며, 선언 조회가 필요한 후보가 있으면 조회한다 (L2c).

### 3.4 소비자는 해석된 결과만 받는다

- board: 쓰기 경로가 `recipients` 로 `audience` 를 정해 기록한다. 비면 받는 사람이 없는 글의 기존 규칙(§3.3)을 따르고, 있으면 `Targets` 다. 글에는 `audience` 가 이미 기록된다 (`lib/board_types/board_types.ml:224`).
- 브로드캐스트 전달: 쓸 때 정한 Keeper 를 깨운다. 한 번에 한 명만 깨우므로 `recipients` 의 첫 번째다. 지금은 `routing_target` 이 고른 이름 하나를 쓴다 (`lib/board_addressing/board_addressing.ml:177`). 받는 사람은 별칭일 수 있어서 전달은 그 이름이 가리키는 Keeper 를 다시 찾는다. 글 속 말 때문에 `Rejected` 가 되는 일이 없어진다. 쓴 뒤 전달 전에 그 Keeper 의 메타가 없어졌으면 지금처럼 `Rejected Target_not_configured`, 읽지 못하면 `Deferred Target_state_unavailable` 이다 (`lib/server/server_bootstrap_loops.ml:202`). 응답의 `ok:false` 와 `mention_delivery` 로 나온다 (`lib/workspace/workspace_broadcast.ml:198`). 쓴 뒤 별칭이 다른 Keeper 로 옮겨지면 전달은 새 주인에게 간다. 게시판 스캔도 같다.
- 알림: 알림에 쓰는 이름도 `recipient` 에서 온다. PR #46755 의 문자 규칙(`is_routable_selector`, `is_routable_target`, `lib/board_addressing/board_addressing.ml:164`)은 이름이 파일 경로가 되기 전에 경로 구분자와 점을 막는다. L3 에서 `routing_target` 을 지운 뒤에도 이 막음은 남아야 한다. 직접 대상 이름의 막음은 `Candidate.of_string` 이 이미 하고 있고, `is_routable_target` 은 그 뒤에도 남는다 (§3.1). 선택자 이름(`is_routable_selector`, `-` 를 받지 않는다)의 규칙은 L3 에서 정한다.
- gRPC: `mentions` 필드를 글로 바꾸지 않고 후보로 바로 넘긴다. 선언에 없는 이름은 호출한 쪽이 명시한 값이 틀린 것이므로 오류로 돌려준다 (D3).
- Keeper 주의 판단: 글과 댓글에 기록된 `audience` 를 쓴다. 제목과 본문, 댓글 글자에서 다시 계산하지 않는다 (D4). 글자에서 `@이름` 을 다시 읽는 곳이 둘 남는다. 대기 중인 이벤트에 붙는 `explicit_mention` 표시(`match_observation`)와, `Thread_participants` 로 기록된 댓글 신호를 받은 Keeper 를 깨울지 정하는 `wake_reason` 의 `match_signal` 이다. 받는 사람을 정하지는 않지만 기록된 `audience` 와 갈라질 수 있다. 선언이 쓴 뒤에 바뀌면 기록은 받는 사람이 없는데 글자는 Keeper 를 부르는 일이 생긴다. L2d 에서 둘 다 기록된 `audience` 를 쓰게 한다.

`@@all` 같은 선택자는 후보가 아니다. board 에서는 `parse` 가 `Broadcast_all` 로 따로 내고 audience 는 `Broadcast` 다 (`lib/board/board_audience.ml:122`). 이 길은 그대로 둔다. 브로드캐스트에서는 지금 `routing_target` 이 선택자 이름도 받는 사람으로 돌려주어 전달이 `all` 이라는 Keeper 를 찾는다. `lib/workspace/workspace_broadcast.ml` 에 `all` 을 따로 다루는 곳은 없다. `routing_target` 은 선택자 옆에 쓴 `@이름` 을 놓치지 않으려고 만든 함수이므로(PR #46755), L3 에서 대신할 후보 추출도 그 성질을 지킨다. 선택자를 후보에서 어떻게 빼는지는 L3 전에 정한다. (§9)

글은 해석 결과를 이미 `audience` 로 기록한다. 댓글에는 그 칸이 없어서 같은 이름의 선택 칸을 하나 더한다 (D4). 이것 말고 해석 결과를 위한 저장 형식은 없다. 옛 글과 옛 댓글은 그대로 둔다.

### 3.5 `ok` 의 뜻은 바꾸지 않는다

글 속 말 때문에 `Rejected` 가 되는 일이 없어지면, `ok:false` 는 선언된 Keeper 에게 전달이 실제로 실패했을 때만 남는다. 필드를 나눌 이유가 줄어든다.

## 4. 어디에 두나

`lib/board/` 는 `Keeper_*` 모듈을 참조하지 않는다(2026-10-29 `origin/main` 에서 참조하는 파일 0개). Keeper 등록부는 `lib/keeper/` 에 있다. 의존 방향을 지키려면 해석은 Keeper 를 모르는 잎 라이브러리에 두고, 선언 조회는 서버 시작점에서 인자로 넘겨야 한다.

- 후보를 만드는 문법: `Board_addressing`. 지금 그대로 둔다.
- 해석: `lib/board_addressing/recipient_resolution.ml`. 선언 조회를 인자로 받는다.
- 해석을 부르는 곳은 쓰는 쪽(board 쓰기, 브로드캐스트 쓰기)이다. Keeper 쪽은 해석하지 않고 기록된 `audience` 를 쓴다 (D4).

## 5. 대안

| 안 | 내용 | 받지 않는 이유 |
|---|---|---|
| B | 모양만 맞으면 대상으로 둔다. 대상 중 Keeper 가 한 명도 없으면 일반 글로 본다 | "모양만 맞으면 대상"이라는 문자열 분류기가 그대로 남는다 |
| C | 글 속 `@` 는 말이다. 받는 사람은 명시 필드(`mentions`)로만 정한다 | 뜻이 가장 단순하다. 그러나 글에 `@이름` 을 쓰는 지금의 방식 전부와 도구·TUI 입력을 바꿔야 한다 |
| D | 지금대로 두고 `unresolved` 만 보여 준다 | 알려 주기만 한다. 글은 계속 사라진다 |
| E | 문자 규칙이나 정규식을 보강한다 | `check` 와 `alice` 는 모양이 같다. 보강할수록 문자열 분류기가 는다 |

## 6. 구현 순서

코드는 스택으로 나누어 올린다.

| 층 | 내용 |
|---|---|
| L1 | `Candidate` 와 `resolve`, 순수 시험. 선언은 인자로 받는다. 이름이 경로가 되기 전의 막음은 `Candidate.of_string` 에 둔다 (§3.1). 재생 도구 `tools/recipient_replay` 가 board 글을 센다 (§7) |
| L2a | Keeper 의 게시판 스캔과 `Board_dispatch` 의 글 신호(`create_post_once_by_fusion_run_id`, `update_post`)가 글에 기록된 `audience` 를 쓴다. 제목과 본문에서 다시 계산하지 않는다. `audience` 가 기록되지 않은 글은 스캔이 건너뛴다. 댓글은 아직 글자에서 읽는다. 스캔이 닿는 글에서 동작은 바뀌지 않는다 (D4) |
| L2b | 댓글에도 `audience` 를 기록한다. `add_comment_with_audience` 가 정한 값을 댓글과 함께 저장하고(`lib/board/board_core.ml`), 스캔이 그 값을 쓴다. 스캔이 댓글의 `audience` 를 글자에서 계산하는 길은 없어진다. `Thread_participants` 로 기록된 댓글에서 Keeper 를 깨우는 판단(`wake_reason`)은 아직 글자를 읽고, 그 읽기는 L2d 에서 바꾼다 (§3.4). 이미 쓴 댓글에는 값이 없고, 읽을 때 짐작하지 않는다 (D4) |
| L2c | board 쓰기 경로(글 만들기·고치기·댓글)가 `resolution` 으로 `audience` 를 정하고 응답에 `unresolved` 를 싣는다. 조회 함수는 `Board_dispatch.init_jsonl` 의 필수 인자(`~recipient_lookup`)로 서버 시작점에서 넘기고, 후보로 파일 경로를 만들기 전에 `Keeper_name.of_string` 을 거친다 (§3.1). 선언 여부는 라우터와 같은 `effective_target_ids` 로 가리고(§3.2), 전체 Keeper 설정 목록은 주소 계산마다 필요한 때 한 번만 읽는다(`Recipient_lookup.make_per_write`). 글 고치기는 락을 잡기 전에 조회하고, 락 안에서 계산에 쓴 값이 그대로일 때만 그 결과를 쓴다. 경합으로 값이 바뀌면 락을 놓고 다시 계산하므로 설정도 다시 읽을 수 있다. 기록된 audience 가 있고 정규화한 제목과 본문이 그대로면 그 audience 를 유지하고 조회하지 않는다. audience 가 없는 이전 글은 같은 내용으로 고쳐도 audience 를 계산한다. 이때 선언 조회가 필요한 주소가 있으면 조회하며, 조회가 실패하면 편집은 저장하지 않는다. 제목·본문·저자가 그대로여서 audience 만 새로 기록된 경우 `content_updated_at` 은 유지되고 `Board_post_updated` 신호는 나가지 않는다. 읽기가 먼저 시작한 백엔드에는 조회가 없어서 주소가 든 글은 거절되고, 이후 `init_jsonl` 이 조회를 넣으면 풀린다. `unresolved` 는 MCP 도구 `masc_board_post`·`masc_board_post_update`·`masc_board_comment` 의 응답에 실린다 |
| L2d | Keeper 가 글자에서 `@이름` 을 다시 읽는 두 곳(`match_observation`, `wake_reason` 의 `match_signal`)이 기록된 `audience` 를 쓴다. 읽는 쪽을 지우는 일이고 새 상태는 없다. 다만 `match_observation` 은 큐에 쌓인 자극에 `audience` 가 없어서, 글은 그 자리에서 읽는 글의 값을, 댓글은 댓글 목록을 읽어서 가져와야 한다 (§3.4) |
| L3 | 브로드캐스트 쓰기와 알림이 `resolution` 을 쓰고, 전달은 정해 둔 받는 사람으로 Keeper 를 찾는다. `Board_addressing.routing_target` 을 지운다. 지우기 전에 후보 추출이 선택자 옆의 `@이름` 을 놓치지 않는지 시험한다 (§3.4). 재생 도구에 저장된 메시지를 더한다 (§7) |
| L4 | gRPC `mentions` 를 후보로 바로 넘기고, 선언에 없는 이름은 오류로 돌려준다 (D3) |

각 층은 자기 시험을 가진다. 저장 형식은 L2b 의 댓글 `audience` 한 칸만 바뀌고, 그 칸이 없는 옛 댓글도 읽히므로 마이그레이션이 없다. 층을 합칠지는 구현 때 크기를 보고 정한다. 어느 쪽이든 층마다 임시 호환 코드를 만들지 않는다.

## 7. 검증

- 재생: `tools/recipient_replay --keepers <Keeper 설정 폴더> --posts <board_posts.jsonl>` 가 저장된 board 글에 새 규칙을 돌려서 받는 사람이 바뀌는 글을 모두 나열한다. 이름을 뽑는 문법과 후보·분류는 쓰기 경로가 쓸 코드 그대로이고, 선언만 Keeper 설정의 `mention_targets` 에서 읽는다. 쓰기 경로의 조회는 저장된 Keeper 메타를 읽으므로 둘은 다른 읽기다. 기대는 `check`·`runtest`·`all` 과 사람·계정 이름이 받는 사람에서 빠지고, 선언된 Keeper 앞으로 쓴 글은 그대로인 것이다. 빠지는 글은 하나씩 눈으로 확인한다. 시스템 글은 쓰기 경로가 대상을 읽지 않으므로 돌리지 않고 따로 센다. 글 줄은 서버가 글을 읽는 디코더(`Board_votes_json.post_of_yojson`)로 읽는다. 서버가 읽지 못하는 줄은 읽지 못한 줄로 세고 종료 코드가 1 이 된다.
- 재생 결과(2026-10-29): 대상 지정 글 686개 중 시스템 글 16개를 빼고 670개를 돌렸다. 501개는 그대로이고, 109개는 받는 사람이 비고, 60개는 받는 사람이 줄어든다. 글에서 다시 뽑은 Keeper 가 기록과 다른 글은 0개이고, 조회가 실패한 글도 0개다. 재생은 이름으로 지정받는 Keeper 만 견준다. 받는 사람이 빈 글이 `Discoverable` 이 되어 주의 판단 후보가 되는 것은 견주지 않는다 (§3.3). 도구는 board 글만 돌린다. 메시지는 L3 에서 더한다. 위 숫자는 읽지 못한 줄이 0개이고 종료 코드가 0 인 실행의 것이다. 읽지 못한 줄이 있어 종료 코드가 1 인 실행의 숫자는 이 문서에 옮기지 않는다.
- 시험: 선언된 이름, 별칭, 같은 별칭을 Keeper 둘이 쓰는 설정, 모르는 이름, 코드 조각 안의 이름, 이름이 섞인 글, 이름 모양이 아닌 토큰(`types/node`, `../x`. 후보가 되지 않아 `declared` 에 닿지 않는다), `@@` 선택자 옆의 `@이름`, 대소문자(`@Alice` 가 Keeper `alice` 에 맞고 `unresolved` 에는 쓴 철자로 나온다), 메타를 못 읽는 Keeper 가 있는 설정(쓰기가 오류로 끝나고 저장되지 않는다), Keeper 이름보다 긴 이름(129자 이상이고, 이름 뒤에 `.json` 이 붙어 파일 이름이 한도를 넘는 251자 이상을 포함한다. 쓰기가 오류로 끝나지 않고 `unresolved` 로 나온다. L2c). `Keeper_id` 는 소문자로 바꾸고, board 의 `Agent_id` 는 대소문자를 구분한다.
- 응답: 선언에 없는 이름이 `unresolved` 로 나온다. 조회가 실패하면 쓰기가 오류로 끝난다 (D5). gRPC 는 선언에 없는 이름도 오류다 (D3).
- 재생 도구는 일회용으로 두지 않고 저장소에 둔다. 출력에 글 제목이 들어가므로 결과 목록은 저장소에 넣지 않는다.

## 8. 결정

### 정한 것 (2026-10-29)

D1. 선언에 없는 `@이름` 은 글 속 말이다. 받지 않은 안: 대상 중 Keeper 가 없으면 일반 글(§5 B), 글 속 `@` 폐지(§5 C).

D2. 사람과 계정 이름은 Keeper 별칭 `mention_targets` 로 선언한다. 새 필드와 새 파일은 없다. 별칭 하나는 Keeper 한 명만 가리키므로(§3.2) 여럿이 나눠 쓰는 계정은 선언하지 않는다. 받지 않은 안: 사람 목록을 설정에 새로 둔다.

D3. gRPC `mentions` 에서 선언에 없는 이름은 오류로 돌려준다. 명시한 값은 후보가 아니라 주장이다. 받지 않은 안: 글 속 말로 둔다.

D4. Keeper 쪽은 기록된 `audience` 를 쓴다. 글은 쓸 때 `audience` 가 정해져 기록되고, 기록이 없으면 읽을 때 짐작하지 않는다는 것이 타입의 약속이다 (`lib/board_types/board_types.ml:224`). 실시간 전달 길(`lib/keeper/keeper_keepalive_signal.ml:505`)은 신호에 실려 온 기록된 값을 쓴다. 그런데 Keeper 의 게시판 스캔과 `Board_dispatch` 의 두 곳(`create_post_once_by_fusion_run_id`, `update_post`)은 제목과 본문에서 audience 를 다시 계산했다. 스캔이 글자를 읽는 것은 글에 audience 를 저장하기 전부터였다. 2026-07-23 의 #25378 은 글자에서 `@이름` 을 찾던 검사를 `classify` 로 바꿨을 뿐이다. 해석을 쓸 때 한 번만 하면 선언이 바뀌어도 쓸 때와 읽을 때 결과가 어긋나지 않는다. L2a 에서 이 세 곳이 기록된 값을 쓰게 바꾼다.

글에 audience 를 저장하기 시작한 것은 #41041 이고 2026-10-04 05:32 KST 에 병합됐다. audience 가 없는 글은 2026-10-29 복사본의 6,779개 중 2,251개다. 병합 전에 쓴 글이 2,230개이고 병합 뒤에 쓴 글이 21개이며, 마지막 글은 10-04 17:21 KST 에 만들어졌다. 기록이 없는 글은 스캔이 건너뛴다. 스캔은 그런 글을 `board_events` 실패 개수에 올리고 로그를 남긴 뒤 같은 글의 댓글과 다음 글로 넘어간다. 그래도 스캔이 이 글들에 닿지는 않는다. Keeper 의 읽음 위치(cursor)는 서버 메모리에만 있고, 처음 읽을 때 게시판에서 `updated_at` 이 가장 큰 글로 맞춰진다 (`collect_board_events_with_cursor_policy`, `current_post_cursor`). 글 신호는 글의 `content_updated_at` 이 읽음 위치보다 뒤일 때만 만들어진다. 새 댓글이나 투표는 글을 다시 나열하게 할 뿐 글의 audience 를 읽게 하지 않는다. 기록된 값이 지금의 글자 규칙과 다른 글도 16개 있다. 모두 10-05~10-16(UTC)에 쓴 `Unlisted` 의 `System_post` 이고, 기록은 `Targets` 인데 시스템 글에서 글자를 읽지 않게 한 #44697(2026-10-22 02:37 KST 병합)의 규칙으로 계산하면 `Thread_participants` 다. 스캔이 이 글들에 닿으면 기록대로 이름이 든 Keeper 를 깨우지만, 같은 이유로 닿지 않는다.

댓글에도 글처럼 선택 칸 `audience` 를 기록한다 (사용자 결정, 2026-10-29). 댓글은 쓸 때 정한 값(`comment_creation.audience`)이 실시간 신호에만 실려 가고 저장되지 않았고, 스캔은 댓글 글자에서 다시 읽었다. 선언을 쓰면 이 둘이 어긋난다. 이미 쓴 댓글에는 칸이 없고, 읽을 때 짐작하지 않는다. 기록이 없는 댓글은 글과 같이 스캔이 건너뛴다. 이 일은 L2b 다. 스캔이 댓글의 `audience` 를 글자에서 계산하는 길은 없어지지만, `Thread_participants` 로 기록된 댓글에서 Keeper 를 깨울지 정하는 `wake_reason` 은 아직 글자에서 `@이름` 을 읽는다. 쓸 때 선언된 이름은 `Targets` 로 기록되므로 이 읽기는 선언이 나중에 바뀐 경우에만 기록과 갈라진다. L2d 가 이 읽기를 기록으로 바꾼다.

받지 않은 안: Keeper 쪽도 선언 조회를 받아 다시 계산한다. 구조는 그대로지만 결과가 어긋날 수 있다. 같은 이유로 댓글에 한해 스캔이 조회를 받아 다시 계산하는 안(저장하지 않는 쪽)도 받지 않았다.

D5. 선언 조회가 실패하면 쓰기를 오류로 돌려주고 아무것도 저장하지 않는다 (§3.1). 받는 사람을 모른 채 기록하면 나중에 고칠 수 없다. 받지 않은 안: 글은 저장하고 받는 사람 없음으로 기록한 뒤 응답에 실패를 싣는다. 이 결정에는 대가가 있다. 자기 이름을 주소로 가진 Keeper 의 이름은 그 Keeper 한 명의 메타만 읽는다. 그 밖의 이름은 모든 Keeper 의 메타를 읽고, 하나라도 못 읽으면 조회 전체가 실패한다 (`lib/keeper/keeper_meta_store.ml:439` 의 `collect`). 그래서 메타 하나가 깨진 동안 Keeper 이름이 아닌 `@이름` 이 든 글을 쓰지 못한다. 모든 Keeper 의 메타를 모으는 전체 조회는 주소 계산 하나당 필요한 때 한 번만 실행된다. 글 고치기 경합으로 다시 계산하면 그때마다 다시 실행될 수 있다. 읽는 시간은 Keeper 설정 41개를 둔 임시 폴더에서 쟀다(2026-10-30, 이 맥, 파일 캐시가 따뜻한 상태, 11번의 중앙값). 자기 이름 하나는 0.08ms, 다섯 개는 0.39ms 이다. 별칭 하나나 모르는 이름 하나는 3.3ms 이고, 모르는 이름이 다섯 개든 스무 개든 3.3~4.2ms 이다. 도는 서버에서는 재지 않았다.

## 9. 확인하지 못한 것

- `check`·`runtest`·`all` 이 아닌 이름이 든 글 72개가 실제로 그 사람에게 닿아야 했던 글인지.
- Keeper 채팅 줄의 `mentions` 에 선언에 없는 이름이 들어가면 생기는 일. 이 RFC 는 그 길을 바꾸지 않는다.
- 받는 사람이 비는 글 109개가 board 목록·검색과 사람이 보는 화면(운영자 받은편지 등)에서 보이는지. 이 RFC 가 다루는 것은 Keeper 의 주의 판단 경로다. L2c 전에 §7 재생으로 확인한다. `codex-mcp-client`(24)·`claude-mcp-client`(7) 이름이 든 글 31개는 그 client 가 board 도구로 자기 앞 글을 찾는 길이 있는지도 본다.
- 재생 도구가 읽는 Keeper 설정의 `mention_targets` 와, 쓰기 경로의 조회가 읽는 저장된 Keeper 메타가 같은 별칭을 내는지. L2c 에서는 견주지 못했다. 켜기 전에 같은 시점의 설정으로 둘을 견준다.
- 브로드캐스트에서 `@@all` 이 지금 거절되는지. §1.1 의 `all` 3개가 `@all` 인지 `@@all` 인지 가르지 못했다.
- `@이름` 에서 나온 값이 `read_effective_meta` 에 닿는 다른 길이 있는지. 확인한 것은 브로드캐스트의 `resolve_broadcast_mention_target` 하나이고, 나머지 호출처는 모두 읽지 못했다.
- 이 문서의 코드 위치는 `origin/main` `51fd971c9ed` 기준이다. `keeper_world_observation.ml:1388`, `keeper_keepalive_signal.ml:505`, `keeper_types_profile.ml:772` 는 `73b05a68a36` 에서 읽었다.
