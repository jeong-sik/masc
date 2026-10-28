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
- 변환은 사람이 쓰는 diff가 아니라 도구가 만든 결과로 해요. 스택 하나로 만들고 맨 위 PR로 한꺼번에 병합해서, 중간 층에만 `Unclassified`가 있고 main에는 들어가지 않아요.
- 이 방향은 다계정 계획 §6의 결정 3에 대한 사용자 선택이에요(2026-10-28).

## 1. 지금 상태

main `8af7c5616e6`에서 읽었어요.

| 항목 | 값 | 출처 |
|---|---|---|
| 경로 등록 호출 | 383곳, 파일 35개 | 컴파일러 파서로 센 값(아래) |
| HTTP/2 게이트웨이의 경로 | 약 72개 (`server_h2_gateway.ml` 62, `server_h2_gateway_routes_extra.ml` 10) | `rg` 로 센 `match` 갈래 |
| 자격 없이 200을 주는 경로(HTTP/1.1) | 기본 설정 113, 엄격 설정 21 | A1 `docs/evidence/2026-10-28-auth-route-baseline/` |

등록 호출은 OCaml 5.5 컴파일러의 파서(`Pparse`)로 `Router.get`·`post`·`prefix_get` 같은 호출을 찾고, 핸들러 안의 인증 래퍼를 읽어서 셌어요. 이름 붙은 핸들러와 지역 래퍼는 같은 파일 안에서 정의를 따라갔고, 다른 파일에 있는 핸들러는 따라가지 않았어요. 파싱 실패는 없었어요. 이 도구는 아직 저장소에 넣지 않았어요.

| 핸들러의 인증 래퍼 | 곳 수 |
|---|---:|
| `with_token_permission_auth` | 131 |
| `with_public_read` | 129 |
| `with_tool_actor_auth` | 36 |
| `with_permission_auth` | 15 |
| `with_tool_auth` | 12 |
| `with_read_auth` | 11 |
| `with_private_token_permission_auth` | 1 |
| 래퍼 둘 이상 | 5 |
| 래퍼 없음 | 43 |

- 래퍼 둘 이상 5곳은 두 가지예요. `/dashboard` 페이지 3곳은 `with_canonical_loopback_host`와 `with_public_read`를 함께 써요. `/api/v1/keepers/` prefix 등록 2곳은 하위 경로마다 다른 래퍼를 걸어요(핸들러 안에서 `match`로 나눠요). 등록 하나가 논리 경로 여러 개인 셈이에요.
- 래퍼 없음 43곳은 다른 파일에 있는 핸들러 22(MCP 전송 `handle_post_mcp`·`handle_delete_mcp`, `health_handler`, graphiql·playground 정적 파일, `/ag-ui/events`, `/events/presence`, `handle_telemetry`), 같은 파일 안의 핸들러 16(OAuth 엔드포인트, `with_lane`을 쓰는 browser lane, `/ws`, play 페이지, lane addon의 OAuth callback), 인라인 5(`/api/v1/board/flairs`, `/dashboard/assets/`, `/`, `/mcp`, play guide)예요. 자기가 인증하거나 아예 공개인 경로가 대부분이에요. 이 안쪽의 인증은 따라가지 않았어요.

등록 호출을 핸들러의 **모양**으로도 셌어요. 변환 도구가 줄을 고쳐 쓰려면 래퍼가 어떤 모양으로 붙어 있는지가 중요해서예요. 같은 파서로 센 값이에요(main `05fde304293`).

| 모양 | 곳 수 | 도구가 |
|---|---:|---|
| S1 `fun request reqd -> W … (fun …) request reqd` | 288 | 고쳐 써요 |
| S2 `W … (fun …)` (부분 적용) | 12 | 고쳐 써요 |
| 같은 파일의 도우미가 래퍼를 감싼 것(`authorized (fun …)` 11곳, 서로 다른 도우미 12곳) | 23 | 도우미 정의가 표준 래퍼의 부분 적용이면 별칭으로 읽고, 아니면 손으로 |
| 이름 붙은 핸들러이고 정의가 S1 | 12 | 정의가 한 곳에서만 쓰이면 고쳐 쓰고, 아니면 손으로 |
| 래퍼가 `match`·`let`·`if` 안쪽에 있거나 정의가 다른 모양 | 5 | 손으로 |
| 래퍼 없음 | 43 | 결정표에서 종류를 읽어요 |

도구가 곧바로 고쳐 쓰는 것은 300곳(78%)이에요. 도우미 23곳과 이름 붙은 핸들러 12곳은 도구가 같은 파일의 정의를 따라가 읽을 수 있는 만큼 고쳐 쓰고, 나머지는 손으로 고쳐요. 이 35곳의 정의는 아직 읽지 않았어요. 그래서 손으로 고쳐야 하는 곳은 최소 5곳, 최대 40곳이에요. 래퍼 없음 43곳은 핸들러를 바꾸지 않고 종류만 적어요.

### 1.1 공개 여부가 두 곳에 있어요

`with_public_read`는 엄격 설정에서 `is_public_read_path`(`server_auth.ml:1023`부터 약 47줄, 문자열 비교)에 없는 경로만 `with_read_auth`로 바꿔요. 경로가 공개인지 정하는 곳이 등록(래퍼)과 허용 목록 둘이에요. 목록 안의 주석도 "목록 항목이 있어야 그 래퍼가 실제로 공개가 된다"고 적어 둬요(`server_auth.ml:1053` 근처). HTTP/2 게이트웨이가 같은 판정을 한 번 더 해요(`server_h2_gateway.ml:303`). 목록과 래퍼는 사람이 맞춰야 해요.

A1에서 엄격 설정에서도 자격 없이 200을 준 경로 21개를 등록 방식과 맞춰 보니 이래요. 7개는 `with_public_read`이면서 목록에 있는 경로(favicon 2, `/api/v1/gate/*` 4, multimodal 1)예요. 13개는 래퍼 없이 일부러 열었거나 자기가 인증하는 쪽(`/health` 계열, `/ws`, 정적 파일, graphiql, play, OAuth callback)이에요. 나머지 1개 `GET /api/v1/board/flairs`는 바로 옆 `GET /api/v1/board/sub-boards`가 `with_public_read`라 엄격 설정에서 401인데, 이 경로만 래퍼도 목록 항목도 없이 열려 있어요. 응답은 flair 이름 목록이라 민감하지는 않지만, 등록하면서 인증을 빼먹어도 컴파일이 통과한다는 문제가 실제로 일어난 예예요.

### 1.2 HTTP/2가 따로예요

HTTP/2는 라우터가 아니라 별도 `match`로 경로를 처리하고 `with_h2_public_read`(38곳), `with_h2_token_permission_auth`(17곳), `with_h2_read_auth`(4곳) 같은 래퍼를 따로 써요. A1에서 HTTP/2는 79개 조합만 처리했고, `GET /api/v1/dashboard/namespace-truth`는 HTTP/2에서만 자격 없이 200이었어요.

### 1.3 설계가 이미 표를 요구해요

다계정 설계 §5.3은 "route 표의 모든 항목이 `Reject`를 반환함을 보이는 시험이 있어야 다계정을 연다"고 해요. 그 표를 읽을 수 있는 곳이 지금은 없어요.

### 1.4 대상이 움직여요

같은 35개 파일의 등록 호출 수예요(`git grep`으로 날짜별 커밋을 읽었어요).

| 시점 | 등록 호출 |
|---|---:|
| 14일 전 | 355 |
| 7일 전 | 364 |
| 3일 전 | 372 |
| 지금 | 383 |

하루 2~4곳씩 늘고, 이 파일들을 고친 커밋은 3일에 22개, 7일에 53개예요. 손으로 쓴 큰 변환은 리뷰를 기다리는 동안 새 등록이 쌓여서 계속 다시 맞춰야 하고, 승인은 head에 묶여 있어서 그때마다 다시 받아요.

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
  | Self_authenticated : self_authenticated_reason -> handler t
```

- `Always_public`은 `is_public_read_path`를 대신해요. 그 목록은 변환이 끝나면 지워요.
- `Self_authenticated`는 핸들러가 직접 인증하는 경로예요. 위 래퍼 없음 43곳을 보면 사유 후보는 MCP 전송, OAuth 엔드포인트, WebSocket 업그레이드, browser lane, play 페이지예요. 사유는 닫힌 목록으로 두고 변환 도구가 센 뒤에 확정해요.
- `with_canonical_loopback_host`는 단독으로 쓰이지 않고 `with_public_read`와 함께 `/dashboard` 페이지 3곳에만 나와요. 인증 종류가 아니라 호스트 검사라는 별도 축이라서, 등록 함수의 선택 인자(`?host:Loopback_only`)로 두어요.

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

문제가 둘이에요. 하나는 종류 없는 등록이 계속 새로 생긴다는 것(§1.4)이고, 다른 하나는 사람이 쓰는 큰 diff로는 움직이는 main을 못 따라간다는 것이에요. 그래서 변환을 도구로 만들고, 리뷰할 것을 diff에서 도구와 결정표로 옮겨요.

계획서에 층으로 더하는 일은 [계획](../superpowers/plans/2026-10-27-multi-account-oidc-runtime-authorization.md) §3의 A4a~A4d가 해요. 스택 하나를 맨 위 PR로 병합해요(masc 규칙).

1. **A4a** 종류 타입, `route.access`, 등록 함수, 임시 `Unclassified`, 인벤토리의 `access` 출력, 변환 도구 `route_auth_codemod`. 도구는 컴파일러 파서로 등록을 읽고 해당 줄만 고쳐 써요. `--check`는 도구 출력이 트리와 같은지 보고, `--fix <파일>`은 다른 브랜치의 옛 등록을 바꿔요. 정하지 못하는 등록은 결정표를 요구해요.
2. **A4b** 변환 한 층이에요. 도구가 300곳(S1·S2)을 고쳐 쓰고, 같은 파일의 도우미와 이름 붙은 핸들러 35곳은 정의를 읽을 수 있는 만큼 고쳐 써요. 래퍼 없음 43곳은 결정표에서 종류를 읽어 종류만 적어요. 도구가 못 읽는 곳(5~40곳)은 사람이 고치고 결정표에 종류와 사유를 적어요. `--check`는 도구가 맡은 곳이 도구 출력과 같은지, 모든 등록의 종류가 결정표와 같은지 봐요. 리뷰는 도구와 결정표, 그리고 사람이 고친 곳의 diff를 읽어요. 바꾼 뒤 A1 기준선을 다시 재고, 병합 직전에 main 위에서 도구를 다시 돌려 그 사이 늘어난 등록을 반영해요.
3. **A4c** HTTP/2 게이트웨이를 같은 타입으로 옮기고 H1/H2 대조 시험을 더해요.
4. **A4d** `Unclassified`, 옛 등록 함수, `is_public_read_path`, 결정표를 지워요.

`Unclassified`와 결정표는 스택 안에만 있어요. 스택이 한꺼번에 들어가므로 main에는 일부만 변환된 상태가 없어요. 이후 새 등록은 종류 없이 컴파일되지 않아요. 병합 시각은 masc에 미리 알리고, 그 뒤 열려 있던 다른 PR은 `route_auth_codemod --fix`로 맞춰요.

## 6. 위험과 열린 질문

- 래퍼가 겹치는 순서. `with_cors (with_public_read ...)`처럼 여러 래퍼가 겹쳐 쓰이는 곳에서 변환이 순서를 지키는지 확인해야 해요.
- prefix 등록 하나가 하위 경로를 안에서 나눠 서로 다른 인증을 거는 경우(`/api/v1/keepers/` 2곳). 종류 하나로는 표현이 안 돼요. 하위 경로마다 등록을 나누거나, prefix 등록이 하위 경로 표를 받게 해야 해요. 이 모양이 이 2곳뿐인지는 래퍼를 안 쓰고 안에서 따로 인증하는 prefix 핸들러까지 읽어야 알 수 있어요. A1은 prefix 아래를 재지 못했으니(`/probe-a1` 한 칸) 변환 때 하위 경로를 따로 재야 해요.
- 결정표로 닫히는 곳이 43곳, 손으로 고치는 곳이 5~40곳이에요. 래퍼 없음 43곳은 다른 파일의 핸들러 22곳을 포함해서, 자기가 인증하는지 공개인지 정의를 읽고 `Self_authenticated`의 사유나 `Always_public`을 골라야 해요. 손으로 고치는 곳은 핸들러 본문을 건드려요. 도우미와 이름 붙은 핸들러 35곳 가운데 몇 곳이 손으로 남을지는 정의를 읽어 봐야 알아요.
- 도구가 틀리면 383곳이 한꺼번에 틀려요. 도구의 시험과 `--check`, A1 기준선 재측정이 이 위험을 막는 장치예요. 도구가 읽지 못하는 모양은 결정표에 없으면 실패하게 해서 조용히 넘기지 않아요. 도구가 S1·S2를 고쳐 쓴 결과가 원래 동작과 같다는 것은 등록 함수가 `fun request reqd -> W … handler request reqd`를 그대로 만들어 주므로 구조로 보장되고, A1 기준선 재측정이 그것을 확인해요.
- A4b 병합 순간 열려 있던 다른 세션의 PR이 옛 등록 함수를 써서 컴파일이 깨질 수 있어요. `--fix`로 한 줄에 맞출 수 있고, 병합 시각을 미리 알려요.
- 위 수치는 같은 파일 안의 핸들러만 따라간 값이에요. 변환 도구는 다른 파일의 핸들러도 따라가야 해요.

## 7. 대안

| 안 | 장점 | 단점 |
|---|---|---|
| 측정기만 둔다 | 코드가 안 바뀌어요 | 새 경로가 인증 없이 열려도 컴파일러가 못 잡아요. 다시 재는 걸 잊으면 끝이에요 |
| 새 등록 함수만 타입, 기존은 점진 이전 | 첫 PR이 작아요 | 두 방식이 오래 같이 남고 "N곳 중 M곳만 고친" 상태가 main에 있어요 |
| 타입 API를 먼저 병합하고, 안 바뀐 파일은 예외로 표시한 채 파일별로 따로 병합 | main이 움직여도 스택이 막히지 않아요 | "N곳 중 M곳만 고친" 상태와 예외 목록이 며칠 main에 남아요. 예외 목록이 새 문자열 목록이 돼요 |
| 손으로 쓴 변환 스택 | 도구가 필요 없어요 | main에 새 등록이 하루 2~4곳씩 생겨서 리뷰를 기다리는 동안 계속 다시 맞춰야 해요(§1.4) |
| 라우터 앞단에서 인증을 일괄 처리 | 핸들러에서 인증이 사라져요 | 핸들러가 받는 토큰 ID·호출자를 못 넘겨요. 동작이 바뀔 위험이 크고 설계가 더 커요 |

선택은 첫 번째가 아니라 타입 등록이에요(사용자 결정, 2026-10-28). 단점은 큰 스택, 래퍼 순서 위험, 층 증가예요.

## 8. 참고

- 계획 [`2026-10-27-multi-account-oidc-runtime-authorization.md`](../superpowers/plans/2026-10-27-multi-account-oidc-runtime-authorization.md) §3의 A1·C3·C4, §6 결정 3
- 설계 [`2026-10-27-multi-account-oidc-runtime-authorization-design.md`](../superpowers/specs/2026-10-27-multi-account-oidc-runtime-authorization-design.md) §5.3
- A1 기준선 #46546, 진행판 #46477
- 코드: `lib/http_server_eio.mli`(`Router`), `lib/server/server_auth.ml`(`with_public_read` 1308줄, `is_public_read_path` 1023줄), `lib/server/server_h2_gateway.ml`
