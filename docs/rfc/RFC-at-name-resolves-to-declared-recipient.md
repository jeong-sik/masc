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
2. 선언된 이름은 Keeper 이름과 `mention_targets` 별칭이다. 사람과 계정 이름을 어떻게 선언할지는 열린 결정이다. (§3.2, §8)
3. 선언에 없는 이름은 글 속 말이다. 거절하지 않는다. 쓴 사람에게는 응답의 `unresolved` 로 알려 준다. (§3.3)
4. 해석은 한 곳에서 하고, board·브로드캐스트·알림은 해석된 결과를 타입으로 받는다. 글을 다시 읽지 않는다. (§3.4)

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

- 저장된 글과 메시지의 형식을 바꾸지 않는다. 과거 데이터를 위한 읽기·변환 코드를 만들지 않는다.
- 새 거절 단계(Gate)를 만들지 않는다.
- 이름이 비슷한지로 오탈자를 맞히지 않는다.
- `@@all` 방송의 뜻을 바꾸지 않는다.

## 3. 제안

### 3.1 후보와 받는 사람은 다른 타입이다

```ocaml
(* 스케치. 이름과 모양은 구현 층에서 정한다. *)

(* 글에서 찾은 토큰. 아직 아무 뜻도 없다. Board_addressing 이 만든다. *)
type candidate = Candidate of string

(* 선언 조회를 통과한 이름. 구현에서는 .mli 로 감싸서 그 길로만 만들게 한다. *)
type recipient = Keeper of Keeper_identity.Keeper_id.t

type resolution =
  { recipients : recipient list  (* 글에 쓴 순서, 중복 없음 *)
  ; unresolved : string list     (* 후보였지만 선언에 없는 이름 *)
  }

val resolve :
  declared:(string -> recipient option) -> candidate list -> resolution
```

`declared` 는 부르는 쪽이 인자로 넘긴다. 전역 설정자나 시험용 우회 함수를 만들지 않는다.

### 3.2 선언의 출처

1. Keeper 이름.
2. Keeper 의 `mention_targets` 별칭.
3. 사람과 계정 이름. 방법은 열린 결정 D2 다.

설정에 이미 있는 것만 쓴다. 새 파일이나 새 필드는 D2 에서 필요하다고 정할 때만 만든다.

### 3.3 선언에 없는 이름은 글 속 말이다

거절하지 않는다. `@check` 가 든 글은 받는 사람이 없는 글이 된다. board 에서는 기존 규칙대로 `Discoverable` 이다.

쓴 사람에게는 쓰기 응답에 `unresolved: ["check"]` 를 돌려준다. 저장하지 않는 읽기용 값이라 저장 형식은 바뀌지 않는다.

`unresolved` 만 더하면 고친 것이 아니다. 알려 주기만 하고 글은 계속 사라진다. 이 RFC 는 기준(§3.1~§3.2)과 알림(`unresolved`)을 함께 바꾼다.

대가가 있다. 선언에서 빠진 정상 이름도 글 속 말이 된다. 사람과 계정 이름(약 74개 글)이 여기에 걸린다. 그래서 D2 를 먼저 정한다.

### 3.4 소비자는 해석된 결과만 받는다

- board: `recipients` 가 비면 받는 사람이 없는 글이고, 있으면 `Targets` 다.
- 브로드캐스트 전달: `recipients` 의 Keeper 를 깨운다. 글 속 말 때문에 `Rejected` 가 되는 일이 없어진다.
- 알림: 알림에 쓰는 이름도 `recipient` 에서 온다. PR #46755 가 넣은 문자 규칙(`is_routable_selector`, `is_routable_target`)은 해석 전의 임시 방어선이라 필요 없어진다.
- gRPC: `mentions` 필드를 글로 바꾸지 않고 후보로 바로 넘긴다. 선언에 없는 이름은 호출한 쪽이 명시한 값이 틀린 것이므로 오류로 돌려준다 (D3).

해석 결과는 저장하지 않는다. 쓸 때(응답)와 읽을 때(주의 판단)에 같은 함수로 다시 계산한다. Keeper 를 추가하거나 지우면 옛 글의 해석도 바뀐다. 이 점은 D4 로 남긴다.

### 3.5 `ok` 의 뜻은 바꾸지 않는다

글 속 말 때문에 `Rejected` 가 되는 일이 없어지면, `ok:false` 는 선언된 Keeper 에게 전달이 실제로 실패했을 때만 남는다. 필드를 나눌 이유가 줄어든다.

## 4. 어디에 두나

`lib/board/` 는 `Keeper_*` 모듈을 참조하지 않는다(2026-10-29 `origin/main` 에서 참조하는 파일 0개). Keeper 등록부는 `lib/keeper/` 에 있다. 의존 방향을 지키려면 해석은 선언 조회를 아는 층에서 하고, 조회 함수는 서버 시작점에서 인자로 넘겨야 한다.

- 후보를 만드는 문법: `Board_addressing`. 지금 그대로 둔다.
- 해석: 선언 조회를 인자로 받는 새 모듈. 위치는 L1 에서 정한다.
- board 쓰기 응답과 Keeper 주의 판단(`Keeper_board_audience`)이 같은 해석을 쓴다.

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
| L2 | board 쓰기 응답과 Keeper 주의 판단이 `resolution` 을 쓴다. 조회 함수는 서버 시작점에서 넘긴다 |
| L3 | 브로드캐스트 전달과 알림이 `resolution` 을 쓰고, `Board_addressing.routing_target` 을 지운다 |
| L4 | gRPC `mentions` 를 후보로 바로 넘긴다 |

각 층은 자기 시험을 가진다. 저장 형식이 바뀌지 않아서 마이그레이션이 없다.

## 7. 검증

- 재생: 저장된 board 글과 메시지에 새 규칙을 돌려서 결과가 바뀌는 글을 모두 나열한다. 기대는 `check`·`runtest`·`all` 65개가 받는 사람에서 빠지고, 선언된 Keeper 앞으로 쓴 글은 그대로인 것이다. 사람·계정 약 74개의 변화는 D2 의 선택에 달려 있어서 따로 센다.
- 시험: 선언된 이름, 별칭, 모르는 이름, 코드 조각 안의 이름, 이름이 섞인 글, 대소문자. `Keeper_id` 는 소문자로 바꾸고, board 의 `Agent_id` 는 대소문자를 구분한다.
- 응답: 선언에 없는 이름이 `unresolved` 로 나온다.
- 재생 스크립트는 일회용으로 두지 않고 L1 과 함께 저장소에 남긴다.

## 8. 열린 결정

D1. 선언에 없는 `@이름` 의 뜻. **글 속 말(이 RFC 의 제안)** / 대상 중 Keeper 가 없으면 일반 글(§5 B) / 글 속 `@` 폐지(§5 C).

D2. 사람과 계정 이름(`jeong-sik`, `pangyo-preachers` 등)을 어떻게 선언할까. **Keeper 별칭 `mention_targets` 에 붙인다**(새 필드가 없다) / 사람 목록을 설정에 새로 둔다. 계정 이름은 Keeper 여럿이 나눠 쓴다. `pangyo-preachers` 는 brother 와 father 가 같은 계정이다. 별칭을 겹쳐 쓸 때 브로드캐스트가 어떻게 되는지는 확인하지 못했다. `persisted_keeper_for_mention_target` 은 별칭이 맞는 Keeper 를 모두 모은다.

D3. gRPC `mentions` 에서 선언에 없는 이름. **오류로 돌려준다**(명시한 값은 후보가 아니라 주장이다) / 글 속 말로 둔다.

D4. 해석 시점. **읽을 때마다 다시 계산한다**(저장 상태가 없다. Keeper 를 바꾸면 옛 글의 해석도 바뀐다) / 쓸 때 계산해서 글에 붙여 저장한다(옛 글이 안 바뀌지만 저장 형식과 과거 데이터 문제가 생긴다).

## 9. 확인하지 못한 것

- 사람·계정 약 74개 글이 실제로 그 사람에게 닿아야 했던 글인지.
- 별칭을 둘 이상의 Keeper 가 나눠 쓸 때 브로드캐스트의 동작.
- 65개 글이 board 목록과 검색에서는 보이는지. 이 RFC 가 다루는 것은 Keeper 의 주의 판단 경로다.
- 이 문서의 코드 위치는 `origin/main` `1b9fc04cafc`(PR #46755 병합 커밋) 기준이다.
