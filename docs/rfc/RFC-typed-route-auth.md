---
rfc: "typed-route-auth"
title: "HTTP 경로의 인증 종류를 등록할 때 타입으로 적게 한다"
status: Draft
created: 2026-10-28
updated: 2026-10-28
author: claude
related: []
---

# RFC: HTTP 경로의 인증 종류를 등록할 때 타입으로 적게 한다 (typed-route-auth)

## 0. 요약

지금은 경로를 등록하는 호출이 인증 종류를 받지 않아요. 핸들러가 안에서 `with_public_read` 같은 래퍼를 직접 불러요. 그래서 어떤 경로가 자격 없이 열려 있는지는 코드를 읽거나 서버를 띄워 요청을 보내 봐야 알아요.

- 제안: 등록 함수가 인증 종류를 필수 인자로 받아요. 종류는 닫힌 합타입이고, 그 종류에 맞는 래퍼는 등록 함수가 씌워요. 라우터가 경로마다 종류를 들고 있어서 표로 뽑을 수 있어요.
- 동작은 바꾸지 않아요. 변환 전과 후에 A1 기준선([#46546](https://github.com/jeong-sik/masc/pull/46546))을 다시 재서 같은지 봐요.
- 스택 하나로 만들고 맨 위 PR로 한꺼번에 병합해요. 중간 층에만 `Unclassified`가 있고 main에는 들어가지 않아요.
- 이 방향은 다계정 계획 §6의 결정 3에 대한 사용자 선택이에요(2026-10-28).

## 1. 지금 상태

main `8af7c5616e6`에서 읽었어요.

| 항목 | 값 | 출처 |
|---|---|---|
| 경로 등록 호출 | 약 385곳 (`Router.get` 199, `post` 143, `prefix_get` 25, `add` 6, `ws_get` 4, `prefix_post` 3, `prefix_delete` 3, `prefix_put` 2) | `rg -o 'Router\.[a-z_]*'` |
| 등록이 있는 파일 | 36개 | 같은 검색 |
| HTTP/2 게이트웨이의 경로 | 약 72개 (`server_h2_gateway.ml` 62, `server_h2_gateway_routes_extra.ml` 10) | `rg` 로 센 `match` 갈래 |
| 자격 없이 200을 주는 경로(HTTP/1.1) | 기본 설정 113, 엄격 설정 21 | A1 `docs/evidence/2026-10-28-auth-route-baseline/` |

핸들러 안의 인증 래퍼는 이렇게 나뉘어요. 등록 호출 뒤에 처음 나오는 래퍼를 정규식으로 센 값이라 근사예요.

| 래퍼 | 곳 수 |
|---|---:|
| `with_public_read` | 124 |
| `with_token_permission_auth` | 119 |
| `with_tool_actor_auth` | 28 |
| `with_tool_auth` | 12 |
| `with_permission_auth` | 12 |
| `with_read_auth` | 7 |
| `with_canonical_loopback_host` | 3 |
| 분류하지 못함 | 79 |

분류하지 못한 79곳은 이름 붙은 핸들러(`get_package_catalog`처럼 다른 곳에서 정의), 파일 안의 지역 래퍼(`authorized`), 자기가 인증하는 경로(OAuth 등)예요. 정확한 분류는 정규식이 아니라 컴파일러가 해야 해요.

### 1.1 공개 여부가 두 곳에 있어요

`with_public_read`는 엄격 설정에서 `is_public_read_path`(`server_auth.ml:1023`부터 약 47줄, 문자열 비교)에 없는 경로만 `with_read_auth`로 바꿔요. 경로가 공개인지 정하는 곳이 등록(래퍼)과 허용 목록 둘이에요. 목록 안의 주석도 "목록 항목이 있어야 그 래퍼가 실제로 공개가 된다"고 적어 둬요(`server_auth.ml:1053` 근처). HTTP/2 게이트웨이가 같은 판정을 한 번 더 해요(`server_h2_gateway.ml:303`). 목록과 래퍼는 사람이 맞춰야 해요.

### 1.2 HTTP/2가 따로예요

HTTP/2는 라우터가 아니라 별도 `match`로 경로를 처리하고 `with_h2_public_read`(38곳), `with_h2_token_permission_auth`(17곳), `with_h2_read_auth`(4곳) 같은 래퍼를 따로 써요. A1에서 HTTP/2는 79개 조합만 처리했고, `GET /api/v1/dashboard/namespace-truth`는 HTTP/2에서만 자격 없이 200이었어요.

### 1.3 설계가 이미 표를 요구해요

다계정 설계 §5.3은 "route 표의 모든 항목이 `Reject`를 반환함을 보이는 시험이 있어야 다계정을 연다"고 해요. 그 표를 읽을 수 있는 곳이 지금은 없어요.

## 2. 문제

1. 새 경로가 인증을 빼먹어도 컴파일이 통과해요.
2. 공개 여부가 래퍼와 문자열 목록 두 곳에 있어서 어긋날 수 있어요.
3. HTTP/1과 HTTP/2가 같은 경로를 서로 다르게 처리해도 알 길이 없어요.
4. 다계정이 요구하는 route 표를 사람이 손으로 만들어야 해요.

## 3. 제안

### 3.1 인증 종류

현재 래퍼와 하나씩 맞아요. 핸들러가 받는 값(서버 상태, 토큰 ID, 호출자)이 종류마다 달라서 GADT로 써요. 이름은 초안이에요.

```ocaml
type _ t =
  | Always_public : handler t                                (* 엄격 설정에서도 열림 *)
  | Public_read : state_handler t                            (* 기본은 열림, 엄격 설정에서는 read 인증 *)
  | Read_auth : state_handler t
  | Permission : Masc_domain.permission -> state_handler t
  | Token_permission : Masc_domain.permission -> token_handler t
  | Private_token_permission : Masc_domain.permission -> token_handler t
  | Tool : { tool_name : string } -> state_handler t
  | Tool_actor : { tool_name : string } -> actor_handler t
  | Loopback_host : state_handler t
  | Self_authenticated : self_authenticated_reason -> handler t
```

- `Always_public`은 `is_public_read_path`를 대신해요. 그 목록은 변환이 끝나면 지워요.
- `Self_authenticated`는 핸들러가 직접 인증하는 경로예요(OAuth 프로토콜, MCP 전송 등). 사유는 닫힌 목록으로 두고, 어떤 사유가 필요한지는 변환 도구가 센 뒤에 정해요.
- `Loopback_host`가 인증 종류인지 호스트 검사라는 다른 축인지는 구현 때 확인해요(§6).

### 3.2 등록 함수

```ocaml
val Server_route.get : 'h Route_auth.t -> string -> 'h -> routes -> routes
```

등록 함수가 종류에 맞는 `Server_auth` 래퍼를 씌워서 `Http_server_eio.Router`에 넣어요. 라우터의 `route` 레코드에는 핸들러 타입이 없는 사본(`access`)을 더해서 인벤토리가 읽게 해요. 의존 방향은 그대로예요. `access` 데이터는 라우터와 같은 라이브러리에, 래퍼를 잇는 코드는 server 쪽에 둬요.

### 3.3 HTTP/2

H2 게이트웨이의 갈래도 같은 `Route_auth.t`를 써요. 같은 경로를 HTTP/1과 HTTP/2가 서로 다른 종류로 등록하면 시험이 실패해요. 한쪽에만 있는 경로는 시험 안에 사유와 함께 이름으로 적어요. 그 목록을 고치면 리뷰에서 보여요.

### 3.4 하지 않는 것

- 인증 동작을 바꾸지 않아요.
- CORS(`with_cors` 201곳), rate limit, 요청 본문 검사는 옮기지 않아요. 인증 래퍼만 바꿔요.
- `Self_authenticated` 경로 안쪽의 인증을 타입으로 풀지 않아요.
- 다계정 판정(`Auth_gate.decide`)은 C4가 만들어요. 이 RFC는 C4가 읽을 route 표를 만들어요.

## 4. 검증

1. A1 기준선을 변환 전과 후에 다시 재요. 기본과 엄격 설정의 `results.json`, `extra.json`에서 상태 코드가 하나라도 다르면 실패예요.
2. 인벤토리 도구가 경로·메서드·종류를 출력해요. 그 표를 evidence로 남기고, 종류가 바뀐 줄은 PR diff로 리뷰해요.
3. 변환하는 동안 `Always_public` 경로 집합과 `is_public_read_path`가 양쪽으로 같은지 시험해요. 변환이 끝나면 목록을 지우고 시험도 함께 지워요.
4. 등록할 때 종류를 안 적으면 컴파일이 실패해요.

## 5. 단계

계획서에 층으로 더하는 일은 이 RFC가 병합된 뒤 별도 문서 PR로 해요. 아래는 초안이고 층 수는 재지 않은 추정이에요.

스택 하나를 만들고 맨 위 PR로 병합해요(masc 규칙).

1. 종류 타입, `route.access`, 등록 함수를 만들어요. 옛 등록 함수는 `Unclassified` 종류로 연결하고 인벤토리가 `access`를 출력해요.
2. 파일 묶음별로 변환해요. 36개 파일을 층당 20k token 이하로 나누면 6~8층쯤 돼요.
3. 마지막 층에서 `Unclassified`와 옛 등록 함수를 지우고, `is_public_read_path`를 지우고, H2 갈래를 옮기고, 시험을 더해요.

`Unclassified`는 스택 안에만 있어요. 스택이 한꺼번에 들어가므로 main에는 일부만 변환된 상태가 없어요.

계획의 27층에 층이 더해지면 목표(`병합 27/27`)의 분모가 바뀌어요. 목표를 고치는 건 사용자 확인 뒤에 해요.

## 6. 위험과 열린 질문

- 래퍼가 겹치는 순서. `with_cors (with_public_read ...)`처럼 여러 래퍼가 겹쳐 쓰이는 곳에서 변환이 순서를 지키는지 확인해야 해요.
- 한 핸들러가 래퍼를 둘 쓰거나 안에서 조건부로 인증하는 경우(`with_optional_board_reaction_actor`). 종류 하나로 표현이 안 될 수 있어요.
- 이름 붙은 핸들러 79곳은 도구가 자동으로 못 바꿔요. 손으로 바꾸고 컴파일러에게 확인받아요.
- `Loopback_host`가 인증 종류인지 호스트 검사라는 별도 축인지 정해야 해요.
- 크기. 등록 385곳이 모두 바뀌는 큰 스택이에요. 층당 20k token 한도 안에서 나눠야 해요.
- 위 래퍼 분포는 근사예요. 변환 도구가 센 값으로 바꿔야 해요.

## 7. 대안

| 안 | 장점 | 단점 |
|---|---|---|
| 측정기만 둔다 | 코드가 안 바뀌어요 | 새 경로가 인증 없이 열려도 컴파일러가 못 잡아요. 다시 재는 걸 잊으면 끝이에요 |
| 새 등록 함수만 타입, 기존은 점진 이전 | 첫 PR이 작아요 | 두 방식이 오래 같이 남고 "N곳 중 M곳만 고친" 상태가 main에 있어요 |
| 라우터 앞단에서 인증을 일괄 처리 | 핸들러에서 인증이 사라져요 | 핸들러가 받는 토큰 ID·호출자를 못 넘겨요. 동작이 바뀔 위험이 크고 설계가 더 커요 |

선택은 첫 번째가 아니라 타입 등록이에요(사용자 결정, 2026-10-28). 단점은 큰 스택, 래퍼 순서 위험, 층 증가예요.

## 8. 참고

- 계획 [`2026-10-27-multi-account-oidc-runtime-authorization.md`](../superpowers/plans/2026-10-27-multi-account-oidc-runtime-authorization.md) §3의 A1·C3·C4, §6 결정 3
- 설계 [`2026-10-27-multi-account-oidc-runtime-authorization-design.md`](../superpowers/specs/2026-10-27-multi-account-oidc-runtime-authorization-design.md) §5.3
- A1 기준선 #46546, 진행판 #46477
- 코드: `lib/http_server_eio.mli`(`Router`), `lib/server/server_auth.ml`(`with_public_read` 1308줄, `is_public_read_path` 1023줄), `lib/server/server_h2_gateway.ml`
