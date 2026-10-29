---
rfc: "at-name-resolves-to-declared-recipient"
title: "글 속 @이름은 선언된 받는 사람일 때만 대상이 된다"
status: Draft
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

D1·D2 는 2026-10-29 에 정했다. 열린 결정은 D3, D4, D5 다. (§8)

이 RFC 는 코드를 바꾸지 않는다. 구현은 RFC 가 `Active` 가 된 뒤 스택으로 나누어 올린다. (§6)

## 1. 문제

### 1.1 측정

측정은 2026-10-29 에 `~/me/.masc` 에서 했고 이슈 #46747 댓글에 적혀 있다. 이 RFC 를 쓰면서 다시 재지는 않았다.

board 글(`board_posts.jsonl`, 측정 시점 6,717개):

| 구분 | 글 수 |
|---|---|
| 대상 지정(`targets`) 글 | 674 |
| 그중 대상이 Keeper 이름·별칭이 아닌 글 | 139 |
| 그중 `@check` 51, `@all` 7, `@runtest` 7 | 65 |

65개는 받는 사람을 쓴 글이 아니다. 나머지 139 − 65 = 약 74개는 `jeong-sik`, `pangyo-preachers`, `be-sleepers`, `anyang-keepers` 같은 사람과 GitHub 계정이 대상이다. 가짜가 아닐 수 있다. 한 글이 토큰을 여러 개 가질 수 있어서 글 수는 정확하지 않다.

브로드캐스트(저장된 메시지 3,335개): 멘션이 거절된 메시지가 45개다. 대상은 `check` 26, `runtest` 4, `claude-mcp-client` 4, `codex-mcp-client` 3, `all` 3, 나머지 5개(`12` 등)다. 거절돼도 깨워진 대상은 모두 실제 이름이었다. 결과는 `ok:false` 응답뿐이었다.

### 1.2 지금 구조

받는 사람 후보를 글에서 뽑는 문법은 `Board_addressing` 이다. board 와 Keeper 는 이미 이 문법을 쓰고(이슈 #25601), 브로드캐스트와 board 도구 알림도 PR #46755(2026-10-29 병합)부터 같은 문법을 쓴다. 그 뒤에 "이 이름이 받는 사람인가"를 정하는 곳이 셋이다.

| 진입 | 확인하는 곳 | 기준 | 모르는 이름이면 |
|---|---|---|---|
| board 글·댓글 | `Board_audience.explicit_address_of_text` (`lib/board/board_audience.ml:36`) | `Agent_id.parse`. 영문자·숫자·`.`·`_`·`-` 1~64자, 콜론 하나. 등록부는 보지 않는다 | `targets` 글이 된다. 읽는 Keeper 가 자기 이름과 맞춰 보고 안 맞으면 조용히 버린다 |
| 브로드캐스트(MCP·HTTP) | `resolve_broadcast_mention_target` (`lib/server/server_bootstrap_loops.ml:157`) | Keeper 메타데이터. 이름이 없으면 모든 Keeper 의 `mention_targets` 별칭을 훑는다 (`lib/keeper/keeper_meta_store.ml:439`) | `Rejected Target_not_configured`. 응답 `ok` 가 false 다 (`lib/workspace/workspace_broadcast.ml:198`) |
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

- 저장된 글과 메시지의 형식을 바꾸지 않는다. 옛 글의 기록은 그대로 둔다. 과거 데이터를 위한 읽기·변환 코드를 만들지 않는다.
- 새 거절 단계(Gate)를 만들지 않는다.
- 이름이 비슷한지로 오탈자를 맞히지 않는다.
- `@@all` 방송의 뜻을 바꾸지 않는다.
- Keeper 채팅 줄의 `mentions` 를 바꾸지 않는다. (§1.2)

## 3. 제안

### 3.1 후보와 받는 사람은 다른 타입이다

```ocaml
(* 스케치. 이름과 모양은 구현 층에서 정한다. *)

(* 글에서 찾은 토큰. 아직 아무 뜻도 없다. Board_addressing 이 만든다. *)
type candidate = Candidate of string

(* 선언 조회를 통과한 이름. 구현에서는 .mli 로 감싸서 그 길로만 만들게 한다. *)
type recipient = Keeper of Keeper_identity.Keeper_id.t

(* 조회가 실패했다. Keeper 메타를 못 읽었거나, 같은 별칭을 Keeper 둘 이상이 쓴다. *)
type lookup_failure = Lookup_failure of string

type resolution =
  { recipients : recipient list  (* 글에 쓴 순서, 중복 없음 *)
  ; unresolved : string list     (* 후보였지만 선언에 없는 이름 *)
  }

val resolve :
  declared:(string -> (recipient option, lookup_failure) result)
  -> candidate list
  -> (resolution, lookup_failure) result
```

`declared` 는 부르는 쪽이 인자로 넘긴다. 전역 설정자나 시험용 우회 함수를 만들지 않는다.

`None`(선언에 없음)과 `Error`(조회 실패)를 섞지 않는다. 지금 브로드캐스트도 둘을 나눈다. 선언 없음은 `Rejected Target_not_configured`, 조회 실패는 `Deferred Target_state_unavailable` 이다 (`lib/server/server_bootstrap_loops.ml:202`). 조회 실패를 글 속 말로 바꾸면 설정 오류가 조용히 사라진다. 쓰기에서 조회 실패를 어떻게 다룰지는 D5 다.

### 3.2 선언의 출처

1. Keeper 이름.
2. Keeper 의 `mention_targets` 별칭 (`.masc/config/keepers/<이름>.toml`).
3. 사람과 계정 이름. 받는 사람이어야 하면 어느 한 Keeper 의 별칭으로 선언한다 (D2).

새 파일이나 새 필드를 만들지 않는다.

별칭 하나는 Keeper 한 명만 가리킨다. 같은 별칭을 둘 이상이 쓰면 지금도 조회가 오류로 끝난다 (`lib/keeper/keeper_meta_store.ml:439`, 오류 문구 `multiple persisted Keepers claim mention_target`). 그래서 `pangyo-preachers` 처럼 Keeper 여럿이 나눠 쓰는 계정은 별칭으로 선언할 수 없다. 이 RFC 는 이 규칙을 바꾸지 않는다.

2026-10-29 에 읽은 Keeper 설정 40개는 모두 `mention_targets` 를 가진다. 35개는 자기 이름뿐이고, 5개(`geek-scout`, `jazz-developer`, `e-masc-the-leader`, `mad-scientist`, `rondo`)가 별칭을 더 가진다. `jeong-sik`, `pangyo-preachers`, `be-sleepers`, `anyang-keepers` 는 어디에도 선언돼 있지 않다.

### 3.3 선언에 없는 이름은 글 속 말이다

거절하지 않는다. `@check` 가 든 글은 받는 사람이 없는 글이 된다. board 에서는 기존 규칙대로 `Discoverable` 이다.

쓴 사람에게는 쓰기 응답에 `unresolved: ["check"]` 를 돌려준다. 응답에만 싣는 값이라 저장 형식은 바뀌지 않는다.

`unresolved` 만 더하면 고친 것이 아니다. 알려 주기만 하고 글은 계속 사라진다. 이 RFC 는 기준(§3.1~§3.2)과 알림(`unresolved`)을 함께 바꾼다.

선언에서 빠진 정상 이름도 글 속 말이 된다. 사람과 계정 이름(약 74개 글)이 여기에 걸린다. 그 이름은 지금도 어떤 Keeper 에게도 닿지 않아서(§3.2) 깨어나는 Keeper 는 달라지지 않는다. 달라지는 것은 두 가지다. board 글이 대상 지정 글에서 `Discoverable` 글로 바뀌고, 브로드캐스트 응답이 `ok:false` 에서 `unresolved` 표시로 바뀐다.

### 3.4 소비자는 해석된 결과만 받는다

- board: 쓰기 경로가 `recipients` 로 `audience` 를 정해 기록한다. 비면 `Discoverable`(기존 규칙)이고, 있으면 `Targets` 다. 글에는 `audience` 가 이미 기록된다 (`lib/board_types/board_types.ml:224`).
- 브로드캐스트 전달: 쓸 때 정한 `recipients` 의 Keeper 를 깨운다. 전달할 때 별칭을 다시 찾지 않는다. 글 속 말 때문에 `Rejected` 가 되는 일이 없어진다.
- 알림: 알림에 쓰는 이름도 `recipient` 에서 온다. PR #46755 가 넣은 문자 규칙(`is_routable_selector`, `is_routable_target`)은 해석 전의 임시 방어선이라 필요 없어진다.
- gRPC: `mentions` 필드를 글로 바꾸지 않고 후보로 바로 넘긴다. 선언에 없는 이름은 호출한 쪽이 명시한 값이 틀린 것이므로 오류로 돌려준다 (D3).
- Keeper 주의 판단: D4 로 남긴다.

해석 결과를 위한 새 저장 형식은 없다. 옛 글의 `audience` 는 그대로 둔다.

### 3.5 `ok` 의 뜻은 바꾸지 않는다

글 속 말 때문에 `Rejected` 가 되는 일이 없어지면, `ok:false` 는 선언된 Keeper 에게 전달이 실제로 실패했을 때만 남는다. 필드를 나눌 이유가 줄어든다.

## 4. 어디에 두나

`lib/board/` 는 `Keeper_*` 모듈을 참조하지 않는다(2026-10-29 `origin/main` 에서 참조하는 파일 0개). Keeper 등록부는 `lib/keeper/` 에 있다. 의존 방향을 지키려면 해석은 선언 조회를 아는 층에서 하고, 조회 함수는 서버 시작점에서 인자로 넘겨야 한다.

- 후보를 만드는 문법: `Board_addressing`. 지금 그대로 둔다.
- 해석: 선언 조회를 인자로 받는 새 모듈. 위치는 L1 에서 정한다.
- 해석을 부르는 곳은 쓰는 쪽(board 쓰기, 브로드캐스트 쓰기)이다. Keeper 쪽은 D4 를 따른다.

## 5. 대안

| 안 | 내용 | 받지 않는 이유 |
|---|---|---|
| B | 모양만 맞으면 대상으로 둔다. 대상 중 Keeper 가 한 명도 없으면 일반 글로 본다 | 선언이 필요 없다. 그러나 사람·계정 앞으로 쓴 글(약 74개)이 Keeper 주의 판단에 들어가고, "모양만 맞으면 대상"이라는 문자열 분류기가 그대로 남는다 |
| C | 글 속 `@` 는 말이다. 받는 사람은 명시 필드(`mentions`)로만 정한다 | 뜻이 가장 단순하다. 그러나 글에 `@이름` 을 쓰는 지금의 방식 전부와 도구·TUI 입력을 바꿔야 한다 |
| D | 지금대로 두고 `unresolved` 만 보여 준다 | 알려 주기만 한다. 글은 계속 사라진다 |
| E | 문자 규칙이나 정규식을 보강한다 | `check` 와 `alice` 는 모양이 같다. 보강할수록 문자열 분류기가 는다 |

## 6. 구현 순서

코드는 이 RFC 가 `Active` 가 된 뒤에 올린다. 스택으로 나눈다.

| 층 | 내용 |
|---|---|
| L1 | 타입과 `resolve`, 순수 시험. 선언은 인자로 받는다 |
| L2 | board 쓰기 경로가 `resolution` 으로 `audience` 를 정하고 응답에 `unresolved` 를 싣는다. 조회 함수는 서버 시작점에서 넘긴다. Keeper 쪽은 D4 에 따라 고친다 |
| L3 | 브로드캐스트 쓰기와 알림이 `resolution` 을 쓰고, 전달은 정해 둔 받는 사람으로 Keeper 를 찾는다. `Board_addressing.routing_target` 을 지운다 |
| L4 | gRPC `mentions` 를 후보로 바로 넘긴다 |

각 층은 자기 시험을 가진다. 저장 형식이 바뀌지 않아서 마이그레이션이 없다.

## 7. 검증

- 재생: 저장된 board 글과 메시지에 새 규칙을 돌려서 결과가 바뀌는 글을 모두 나열한다. 기대는 `check`·`runtest`·`all` 65개와 사람·계정 약 74개가 받는 사람에서 빠지고, 선언된 Keeper 앞으로 쓴 글은 그대로인 것이다. 빠지는 글은 하나씩 눈으로 확인한다.
- 시험: 선언된 이름, 별칭, 같은 별칭을 Keeper 둘이 쓰는 설정, 모르는 이름, 코드 조각 안의 이름, 이름이 섞인 글, 대소문자. `Keeper_id` 는 소문자로 바꾸고, board 의 `Agent_id` 는 대소문자를 구분한다.
- 응답: 선언에 없는 이름이 `unresolved` 로 나온다. 조회 실패는 D5 에서 정한 대로 나온다.
- 재생 스크립트는 일회용으로 두지 않고 L1 과 함께 저장소에 남긴다.

## 8. 결정

### 정한 것 (2026-10-29)

D1. 선언에 없는 `@이름` 은 글 속 말이다. 받지 않은 안: 대상 중 Keeper 가 없으면 일반 글(§5 B), 글 속 `@` 폐지(§5 C).

D2. 사람과 계정 이름은 Keeper 별칭 `mention_targets` 로 선언한다. 새 필드와 새 파일은 없다. 별칭 하나는 Keeper 한 명만 가리키므로(§3.2) 여럿이 나눠 쓰는 계정은 선언하지 않는다. 받지 않은 안: 사람 목록을 설정에 새로 둔다.

### 열린 것

D3. gRPC `mentions` 에서 선언에 없는 이름. **오류로 돌려준다**(명시한 값은 후보가 아니라 주장이다) / 글 속 말로 둔다.

D4. Keeper 쪽 해석 시점. 글을 쓸 때 `audience` 가 정해져 기록되고(`lib/board_types/board_types.ml:224`), `Board_dispatch` 는 이를 붙인 신호(`addressed_board_signal`, `lib/board/board_dispatch.ml:99`)를 내보낸다. 그런데 Keeper 쪽 `classify`(`lib/keeper/keeper_board_audience.ml:42`)는 audience 가 없는 `board_signal` 의 제목과 본문에서 audience 를 다시 계산한다. **Keeper 가 기록된 `audience` 를 쓰게 한다**(해석을 쓸 때 한 번만 한다. 선언이 바뀌어도 쓸 때와 읽을 때 결과가 어긋나지 않는다) / Keeper 쪽도 선언 조회를 받아 다시 계산한다(구조는 그대로지만 결과가 어긋날 수 있다).

D5. 조회가 실패했을 때 쓰기(§3.1). **쓰기를 오류로 돌려준다**(받는 사람을 모른 채 기록하면 나중에 고칠 수 없다) / 글은 저장하고 받는 사람 없음으로 기록한 뒤 응답에 실패를 싣는다. Keeper 이름과 정확히 같은 이름은 그 Keeper 한 명의 메타만 읽는다. 그 밖의 이름은 모든 Keeper 의 메타를 읽고, 하나라도 못 읽으면 조회 전체가 실패한다 (`lib/keeper/keeper_meta_store.ml:439` 의 `collect`). 첫 안이면 메타 하나가 깨진 동안 Keeper 이름이 아닌 `@이름` 이 든 글을 쓰지 못한다.

## 9. 확인하지 못한 것

- 사람·계정 약 74개 글이 실제로 그 사람에게 닿아야 했던 글인지.
- Keeper 쪽 `classify` 가 audience 를 신호에서 받지 않고 다시 계산하는 이유 (D4).
- Keeper 채팅 줄의 `mentions` 에 선언에 없는 이름이 들어가면 생기는 일. 이 RFC 는 그 길을 바꾸지 않는다.
- 별칭 조회 비용. 지금은 모든 Keeper 의 메타를 읽는다. board 쓰기마다 부를 때 얼마나 드는지 재지 않았다.
- 65개 글이 board 목록과 검색에서는 보이는지. 이 RFC 가 다루는 것은 Keeper 의 주의 판단 경로다.
- 이 문서의 코드 위치는 `origin/main` `c2a74339c34` 기준이다.
