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
- 동작을 바꾸지 않는 것이 목표예요. 변환 결과의 인증 종류와 바인딩, 평가 시점을 검토하고 변환 전후 A1 기준선([#46546](https://github.com/jeong-sik/masc/pull/46546))을 다시 재요. A1의 무자격 요청 상태 코드 비교만으로 모든 권한 동등성을 증명하지는 못해요.
- 도구가 안전하게 다룰 수 있는 곳을 변환하고 나머지는 사람이 결정해요. 자동·수동 변경 모두 리뷰해요. A4a([#46590](https://github.com/jeong-sik/masc/pull/46590))가 먼저 병합돼서 타입, 등록 함수, `Unclassified`는 이미 main에 있어요. 옛 등록 함수와 `Unclassified`는 마지막 층 A4d가 지워요.
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

등록 호출을 변환 도구(`route_auth_codemod`)로도 셌어요. 다음 표는 당시 도구와 main `05fde304293` 위에 A4a를 얹은 트리에서 35개 파일의 `Router.*` 등록 381곳을 센 기록이에요(`ws_get` 2곳은 대상이 아니에요). 도구가 이후 이름 붙은 핸들러 지원과 범위 검사를 바꾸었으므로 현재 변환 가능 수나 최종 결정표의 크기로 쓰지 않아요.

| 모양 | 곳 수 | 도구가 |
|---|---:|---|
| `fun request reqd -> W … (fun …) request reqd`, 또는 래퍼를 부분 적용한 `W … (fun …)` | 285 | 고쳐 써요 |
| 위와 같은 모양인데 `~tool_name`이 계산식이라, 요청마다 하던 계산이 등록 때 한 번으로 바뀜 | 11 | `--allow-early-evaluation`을 줄 때만 고쳐 쓰고 목록으로 보여 줘요 |
| 도우미 함수 호출(`authorized (fun …)` 11곳, `post` 6곳, `serve_graphiql_asset` 4곳 등) | 36 | 건드리지 않고 목록에 남겨요 |
| 이름 붙은 핸들러 | 33 | 건드리지 않고 목록에 남겨요 |
| 몸통이 래퍼 호출이 아닌 핸들러(래퍼가 `match`·`let` 안쪽에 있거나 아예 없어요) | 16 | 건드리지 않고 목록에 남겨요 |

그 당시 집계는 도구 변환 296곳(78%), 수동 결정 85곳이었어요. 위 래퍼 없음 43곳은 `ws_get`(`/ws`) 한 곳을 빼면 그 85곳 안에 있어요. A4b에서는 실제 사용할 도구 head와 서버 source를 고정해 전체 등록 집합을 다시 세고, 변환·보류·수동 결정 건수를 기록해요.

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

현재 래퍼와 하나씩 맞아요. 핸들러가 받는 값(서버 상태, 토큰 ID, 호출자)이 종류마다 달라서 GADT로 써요. 구현(A4a)에서는 두 모듈로 나뉘어요.

- `Route_access.t`(`lib/route_access.ml`): 함수 타입이 없는 데이터예요. `Http_server_eio.Router.route`가 이것을 들고 있어서 핸들러를 실행하지 않고도 경로 표를 읽을 수 있어요.
- `Server_route.auth`(`lib/server/server_route.ml`): 핸들러 타입을 나르는 GADT예요. 등록 함수가 이것을 받아 `Server_auth` 래퍼를 씌워요.

```ocaml
type _ auth =
  | Always_public : request_handler auth                     (* 엄격 설정에서도 열림 *)
  | Public_read : state_handler auth                         (* 기본은 열림, 엄격 설정에서는 read 인증 *)
  | Public_read_on_canonical_host : { port : int } -> state_handler auth  (* Public_read, 앞에서 호스트 이름을 정규화 *)
  | Read_auth : state_handler auth
  | Permission : Masc_domain.permission -> state_handler auth
  | Token_permission : Masc_domain.permission -> token_handler auth
  | Private_token_permission : Masc_domain.permission -> token_handler auth
  | Tool : { tool_name : string } -> state_handler auth
  | Tool_actor : { tool_name : string } -> actor_handler auth
  | Self_authenticated : Route_access.self_authenticated_reason -> request_handler auth
```

- `Always_public`은 `is_public_read_path`를 대신해요. 그 목록은 변환이 끝나면 지워요. 래퍼가 없고 누구에게나 같은 답을 주는 경로(health 3개, 정적 파일, graphiql, `/`, `/dashboard/assets/`, play 페이지와 agent guide)와 `GET /api/v1/board/flairs`가 여기에 들어가요. flairs는 공개 목록에도 없어서 엄격 설정에서 닫히지 않는 경로예요([#46569](https://github.com/jeong-sik/masc/issues/46569)). 종류를 적는다고 이 동작이 바뀌지는 않아요.
- `Self_authenticated`는 핸들러가 직접 인증하는 경로예요. 사유는 닫힌 목록이고 A4b에서 여섯이 됐어요. 근거는 A1 기준선과 핸들러 코드예요.

  | 사유 | 경로 | 근거 |
  |---|---|---|
  | `Mcp_transport` | `/mcp`와 프로필 경로의 GET·POST·DELETE, `/`(POST), `/ag-ui/events`, `/events/presence` | 전송이 토큰을 직접 확인하고 `WWW-Authenticate`와 함께 401을 줘요 |
  | `Oauth_protocol` | OAuth 엔드포인트와 discovery 문서 8개, 콜백 페이지 2개 | 호출자가 자격을 얻기 전에 도는 경로예요 |
  | `Websocket_upgrade` | `/ws`, IDE LSP 프록시 | 핸들러가 업그레이드 전에 자격을 확인해요. `/ws`는 업그레이드 요청만 확인하고, 업그레이드가 아닌 `GET /ws`는 자격 없이 discovery 문서를 줘요. IDE LSP 프록시는 모든 요청을 확인해요 |
  | `Browser_lane` | `/browser-lane/{poll,result,ping,disconnect}` | `with_lane`이 lane 토큰을 확인하고 없으면 403을 줘요 |
  | `Loopback_dev_token` | `/api/v1/dashboard/dev-token` | loopback이 아니거나 엄격 설정이면 404예요. 아니면 `with_public_read`를 핸들러 안에서 불러서(서버가 준비되기 전 503, workspace precondition 오류 400·409) 자격 없이 dashboard 토큰을 줘요([#46560](https://github.com/jeong-sik/masc/issues/46560)) |
  | `Subpath_dispatch` | `/api/v1/keepers/` prefix의 GET·POST | 핸들러가 하위 경로에 따라 래퍼를 골라요. 하위 경로별 종류는 경로표에 없어요 |

  `Subpath_dispatch`는 "종류가 없다"를 이름으로 적은 것이에요. 이 두 등록을 하위 경로마다 나누는 일은 따로 해요.
- `Public_read_on_canonical_host`는 `Public_read`와 같은 접근이라서 경로 표에는 `public_read`로 적혀요. 다른 점은 순서 하나예요. `localhost`처럼 정규 호스트의 별칭으로 오는 요청을 서버 준비 상태, workspace precondition, 자격을 보기 전에 정규 호스트로 리다이렉트해요(`with_canonical_loopback_host`는 인증 검사가 아니라 호스트 이름 검사예요). `/dashboard` 페이지 3곳이 원래 이 순서였고, 그대로 두려고 이 종류를 더했어요. 호스트 검사를 `Public_read` 안쪽에 두면 별칭 호스트에서 서버가 준비되기 전에는 503, workspace precondition이 틀리면 400과 409를 받아요.

### 3.2 등록 함수

```ocaml
val Server_route.get : 'h auth -> string -> 'h -> Router.t -> Router.t
```

`get`, `post`, `add`, `prefix_get`, `prefix_post`, `prefix_put`, `prefix_delete`가 있어요. 코드에서 쓰이는 등록 함수만 만들었어요. 정확한 경로의 `put`, `delete`, `any`는 쓰는 곳이 없어서 없고, 쓰게 되면 그때 더해요. `ws_get`은 업그레이드 핸들러가 직접 인증하므로 종류를 받지 않고 항상 `Self_authenticated Websocket_upgrade`를 기록해요.

등록 함수는 종류에 맞는 `Server_auth` 래퍼를 핸들러에 씌우고, 종류를 같은 호출에서 기록해요. 종류와 핸들러를 따로 받는 함수는 라우터가 공개하지 않아요. 그래서 `Permission`이라 적고 인증 없는 핸들러를 넘기는 등록은 쓸 수 없어요. 등록 함수는 라우터 모듈의 함수자 `Router.Make_typed`가 만들어요. `Server_auth`는 `masc.server`에 있어서 라우터가 직접 부를 수 없으니, 래퍼 여덟 개(`Server_auth`의 일곱 개와 호스트 검사 `with_canonical_loopback_host`)를 함수자 인자(`Router.Wrappers`)로 받아요. `Server_route`가 이 함수자를 `Server_auth`로 적용하는 유일한 곳이에요. 아무것도 검사하지 않는 래퍼로 함수자를 적용하면 이 보장을 우회할 수 있어요. 그것은 타입이 아니라 리뷰가 막고, 적용이 한 곳뿐인지는 `rg Make_typed`로 보여요. 라우터의 `route` 레코드에는 `access : Route_access.t` 필드가 있고 인벤토리가 이것을 읽어요. 라우터의 옛 등록 함수(`Router.get` 등)는 `Route_access.Unclassified`를 기록하고, 마지막 층(A4d)에서 지워요. 그 뒤에는 모든 경로의 `access`가 이 함수자를 거친 값이에요.

### 3.2.1 경로표는 하나의 상태예요

`Router.routes`는 등록한 줄을 순서대로 모두 돌려주고, `Router.effective_routes`는 디스패치가 실제로 고르는 경로만 돌려줘요. 같은 메서드와 정확한 경로를 두 번 등록하면 나중 것이 이기고, 같은 접두사도 나중 것이 앞서요. 그래서 어느 경로에 어떤 종류가 적용되는지는 `effective_routes`를 읽어요(인벤토리와 C4가 읽는 표). 한 등록이 여러 메서드를 가지면 일부 메서드만 덮어써질 수 있고, 그때는 덮어써지지 않은 메서드만 남아요.

등록 줄과 메서드 인덱스는 같은 공유 상태예요. 등록 함수에 넘긴 옛 라우터 참조로 `routes`, `route_count`, `resolve`를 불러도 같은 표를 봐요.

지금 main에는 같은 경로가 두 번 등록된 곳이 있어요. `make_routes`가 `Server_routes_http_routes_workspace.add_routes`를 두 번 부르고, 9개 경로 10줄이 겹쳐요. 두 번째가 이기고 핸들러가 같아서 응답은 달라지지 않아요.

### 3.3 HTTP/2

H2 게이트웨이는 갈래마다 인증 래퍼를 고르지 않아요. 요청이 오면 HTTP/1 라우터에게 같은 요청의 종류를 물어요. `Router.resolve`가 돌려주는 `route.access`예요. 게이트웨이는 그 종류에 맞는 H2 게이트를 걸고 갈래의 핸들러를 불러요.

그래서 표에 종류가 있는 경로는 HTTP/1과 HTTP/2에서 다른 종류를 가질 수 없어요. 종류를 적는 곳이 HTTP/1 등록 하나뿐이에요. 둘이 어긋났는지 보는 시험은 필요 없고, 경로를 HTTP/1에 새로 등록하면 같은 경로의 H2 갈래가 그 종류를 받아요. 표에 종류가 없는 하위 경로(`Subpath_dispatch`)는 이 보장 밖이에요. 아래에서 따로 다뤄요.

- 라우터는 `Server_runtime_bootstrap`이 H2 핸들러를 만드는 자리에서 넘겨요. 지금은 그 자리에 라우터가 있는데도 넘기지 않아요.
- H2 갈래는 자기가 받는 핸들러 모양만 말해요. 서버 상태만 받는지, 인증된 행위자도 받는지예요. 게이트는 종류를 HTTP/1의 `Server_auth`와 같은 판정 함수로 풀어서 걸어요. 종류가 갈래의 모양과 맞지 않거나 H2가 아직 구현하지 않은 종류면 요청을 거절해요. 열지 않아요.
- 종류가 `Always_public`인 경로와, `Self_authenticated`의 이유가 `Mcp_transport`, `Oauth_protocol`, `Websocket_upgrade`인 경로는 게이트가 인증을 걸지 않아요. 핸들러가 직접 인증하는 `/mcp`, OAuth, `/ws`가 이쪽이에요. 나머지 이유(`Browser_lane`, `Loopback_dev_token`, `Subpath_dispatch`)는 H2에 갈래가 없거나 표가 종류를 갖고 있지 않아서 요청을 거절해요. 종류나 이유가 하나 늘면 이 판정이 컴파일되지 않아요.
- `Subpath_dispatch`는 열지 않아요. HTTP/1은 `/api/v1/keepers/` prefix 핸들러 안에서 하위 경로에 따라 공개 읽기나 `CanAdmin` 같은 권한을 고르고, 표에는 `Self_authenticated`만 남아요. 종류만 읽는 게이트는 하위 경로의 권한을 알 수 없어서, 열면 하위 경로가 자격 없이 열릴 수 있어요. 그래서 이 prefix 아래 H2 갈래 5곳(`hitl`, `child-content`, `native-tasks`, `github-identity`, `github-login`)은 갈래가 권한을 직접 적고 옛 래퍼를 그대로 불러요. 이 5곳의 권한은 HTTP/1 핸들러 안과 H2 갈래에 따로 적혀 있어서 어긋날 수 있고, 이 층은 그걸 닫지 않아요. 닫으려면 하위 경로마다 종류가 표에 있어야 해요. 지금 라우터는 정확한 경로와 prefix만 알아서 `/api/v1/keepers/<이름>/child-content/receivers`처럼 가운데에 변수가 낀 경로를 등록할 수 없어요. 그런 경로를 받는 라우터가 먼저 필요하고, 그건 이 RFC 다음 층이에요.
- HTTP/1 라우터에 없는 경로는 404, 라우터에 없는 메서드는 405예요. H2에만 있던 경로는 `namespace-truth` 별명 하나였고 A4c에서 지워요. H2에만 있는 경로를 새로 열려면 이 규칙을 먼저 바꾸는 RFC가 필요해요.
- 이 층은 HTTP/2 응답이 HTTP/1에 맞춰 바뀌는 첫 층이에요. 이 층이 닫는 것은 [#46675](https://github.com/jeong-sik/masc/issues/46675)(엄격 설정에서 `/.well-known/agent.json`과 `agent-card.json`을 HTTP/2만 자격 없이 200으로 줘요)와 H2에만 남은 `namespace-truth`예요. [#46676](https://github.com/jeong-sik/masc/issues/46676)의 나머지(쿼리 전제조건과 호스트 리다이렉트를 H2가 안 지켜요, `github-identity`가 admin에게 500이에요)는 핸들러가 두 벌이라서 생기는 차이라 남아요. 변환 전후로 A1 기준선의 HTTP/2 전체를 돌려 바뀐 응답 목록을 PR 근거로 남기고, 목록의 모든 줄이 HTTP/1과 같아지는 쪽인지 읽어요.

핸들러까지 하나로 합치는 단일 디스패처는 이 RFC 범위가 아니에요. 핸들러가 HTTP/1과 HTTP/2에 두 벌인 동안은 응답이 어긋날 수 있어요(#46676의 쿼리 전제조건과 호스트 리다이렉트). 이 층은 인증 종류가 한 곳에서 나오게 할 뿐이에요.

### 3.4 하지 않는 것

- 인증 동작을 바꾸지 않는 것이 목표예요. 변환 후에도 별도로 검증해요.
- CORS(`with_cors` 201곳), rate limit, 요청 본문 검사는 옮기지 않아요. 인증 래퍼만 바꿔요.
- `Self_authenticated` 경로 안쪽의 인증을 타입으로 풀지 않아요.
- 다계정 판정(`Auth_gate.decide`)은 C4가 만들어요. 이 RFC는 C4가 읽을 route 표를 만들어요.

## 4. 검증

1. A1 기준선을 변환 전과 후에 다시 재요. 기본과 엄격 설정의 `results.json`, `extra.json`에서 상태 코드가 하나라도 다르면 실패예요. 이는 그 요청들의 무자격 상태 코드 비교이고 인증된 호출, 권한별 거부, prefix 하위 경로와 HTTP/2 전체의 동등성을 대신하지 않아요.
2. 인벤토리 도구가 경로·메서드·종류를 출력해요. 그 표를 evidence로 남기고, 종류가 바뀐 줄은 PR diff로 리뷰해요.
3. 변환하는 동안 `Always_public` 경로 집합과 `is_public_read_path`가 양쪽으로 같은지 시험해요. 변환이 끝나면 목록을 지우고 시험도 함께 지워요.
4. 등록할 때 종류를 안 적으면 컴파일이 실패해요.
5. 종류와 핸들러를 따로 받는 등록 함수는 `http_server_eio.mli`에 없어요. `Router.Make_typed`를 적용하는 곳이 `server_route.ml` 한 곳인지는 `rg Make_typed`로 확인해요.
6. 경로표 시험이 같은 경로의 재등록(권한이 다른 경우 포함), 일부 메서드만 덮어쓰는 경우, 정확한 경로와 접두사의 우선순위, 옛 참조로 읽는 목록·개수·조회를 확인해요.

## 5. 단계

문제가 둘이에요. 하나는 종류 없는 등록이 계속 새로 생긴다는 것(§1.4)이고, 다른 하나는 사람이 쓰는 큰 diff로는 움직이는 main을 못 따라간다는 것이에요. 도구로 변환을 돕되, 도구와 결정표뿐 아니라 실제 변환 diff의 인증·바인딩도 리뷰해요.

계획서에 층으로 더하는 일은 [계획](../superpowers/plans/2026-10-27-multi-account-oidc-runtime-authorization.md) §3의 A4a~A4d가 해요. 층마다 병합 시점에 컴파일되고 동작이 같아야 해요. 처음에는 A4a~A4d를 스택 하나로 만들어 맨 위 PR로 한꺼번에 병합하려 했지만, A4a는 스택이 만들어지기 전에 승인을 받아서 2026-10-28 09:25Z에 키퍼가 혼자 병합했어요(병합 보호 조건을 모두 채운 PR이에요). 승인된 층은 스택이 만들어지기 전에 병합될 수 있어요. A4b~A4d는 네이티브 스택으로 만들어 맨 위 PR로 병합하는 것을 목표로 하고, 그렇게 되지 않아도 각 층이 위 조건을 지켜요.

1. **A4a** 종류 타입, `route.access`, 등록 함수, 임시 `Unclassified`, 인벤토리의 `access` 출력, 변환 도구 `route_auth_codemod`. 도구는 서버 코드와 닿지 않아 별도 PR로 내요. 컴파일러 파서로 등록을 읽고 해당 글자 범위만 고쳐 써요. `--write`는 파일을 바꾸고, `--strict`는 바꾸지 못한 등록이 남으면 실패해요. 같은 경로라고 말할 수 있는 모양만 바꾸고, 나머지는 이유와 함께 목록에 남겨요.
2. **A4b** 변환 한 층이에요. 사용하려는 도구의 정확한 head에서 열린 변경 요청을 해소하고 독립 소스 리뷰를 받은 뒤 변환해요. 고정된 서버 source와 도구 head에서 전체 등록을 다시 세고 도구가 남긴 곳과 수동 변경은 결정표에 종류와 사유를 적어요. 이름 붙은 핸들러는 다른 파일의 사용까지 확인하고, 변환 diff마다 원래 래퍼·종류·식별자 바인딩 범위가 보존되는지 읽어요. 계산식 인자를 `--allow-early-evaluation`으로 옮기려면 각 식의 호출 간 값 불변성, 부작용·예외, 정의와 등록 위치의 바인딩이 같은 근거를 기록해요. 근거가 없으면 자동 변환을 수락하지 않고 수동으로 결정해요. 바꾼 뒤 컴파일러가 알려 주는 안 쓰게 된 `open Server_auth`를 지우고, A1 기준선을 다시 재고, 병합 직전에 main 위에서 도구를 다시 돌려 그 사이 늘어난 등록을 반영해요.
3. **A4c** HTTP/2 게이트웨이가 HTTP/1 라우터에서 경로의 종류를 읽게 해요(§3.3).
4. **A4d** 두 번에 나눠 내요. 앞부분은 옛 등록 함수와 `Unclassified`를 지워요. HTTP/2 게이트웨이는 이 함수들을 부르지 않아서 A4c를 기다리지 않아요. 이 부분이 들어가면 종류 없는 등록은 컴파일되지 않아요. 뒷부분은 `is_public_read_path`와 결정표를 지워요. HTTP/2 게이트웨이가 `is_public_read_path`를 더는 부르지 않는 A4c 뒤에 와요.

옛 등록 함수를 지우는 순간 열려 있던 다른 PR이 그 함수를 쓰면 컴파일이 깨져요. 병합 시각은 masc에 미리 알리고, 그 PR들은 `route_auth_codemod --write`로 맞춰요. 도구는 열려 있던 PR이 모두 옮겨진 뒤 따로 지워요.

## 6. 위험과 열린 질문

- 래퍼가 겹치는 순서. `with_cors (with_public_read ...)`처럼 여러 래퍼가 겹쳐 쓰이는 곳에서 변환이 순서를 지키는지 확인해야 해요.
- prefix 등록 하나가 하위 경로를 안에서 나눠 서로 다른 인증을 거는 경우(`/api/v1/keepers/` 2곳). 종류 하나로는 표현이 안 돼요. 하위 경로마다 등록을 나누거나, prefix 등록이 하위 경로 표를 받게 해야 해요. 이 모양이 이 2곳뿐인지는 래퍼를 안 쓰고 안에서 따로 인증하는 prefix 핸들러까지 읽어야 알 수 있어요. A1은 prefix 아래를 재지 못했으니(`/probe-a1` 한 칸) 변환 때 하위 경로를 따로 재야 해요.
- 수동 결정 수는 사용하는 도구와 source head에 따라 달라져요. 정의가 다른 파일에 있는 핸들러는 자기가 인증하는지 공개인지 정의를 읽고 `Self_authenticated`의 사유나 `Always_public`을 골라야 해요. 래퍼를 안쪽에서 쓰는 도우미와 이름 붙은 핸들러는 핸들러 본문을 읽어요.
- 도구의 오분류는 여러 경로에 동시에 영향을 줘요. 래퍼가 `request`와 `reqd`를 전달하는 구조만으로 인자 평가 시점이나 이름 결속이 같다고 보장할 수 없어요. 도구의 현재 head와 테스트, 모든 변환 diff와 결정표, 각 조기 평가 식의 근거, 실행 중 경로표와 원본 래퍼를 대조해요. 바꾼 모듈의 컴파일과 인증된 허용·권한 부족 거부, 관련 prefix 하위 경로 및 H1/H2 시험도 확인해요. A1 재측정은 그 표본의 무자격 상태 코드 회귀를 확인하는 별도 증거예요. `--strict`는 보류된 등록을 드러내지만 변환된 등록의 동등성을 증명하지 않아요.
- A4b 병합 순간 열려 있던 다른 세션의 PR이 옛 등록 함수를 써서 컴파일이 깨질 수 있어요. `--write`로 한 줄에 맞출 수 있고, 병합 시각을 미리 알려요.
- §1의 래퍼 수는 같은 파일 안의 핸들러만 따라간 값이에요. 다른 파일에 정의된 핸들러의 인증은 결정표를 만들 때 정의를 읽어 확인해요.

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
