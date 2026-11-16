---
rfc: "a-request-reads-its-bearer-once-at-the-door"
title: "요청 하나는 bearer 를 입구에서 한 번 읽고, 그 결과를 끝까지 들고 간다"
status: Draft
created: 2026-11-16
updated: 2026-11-16
author: claude
supersedes: []
superseded_by: null
related: ["0340", "main-domain-scheduler-latency"]
---

# 요청 하나는 bearer 를 입구에서 한 번 읽고, 그 결과를 끝까지 들고 간다

- 상태: 초안.
- 계기: 2026-11-16 Claude Code 의 masc MCP 연결이 `CONNECT_TIMEOUT`(10초)으로 거듭 끊겼다. 앞선 고침은 #52390(HTTP 입구), #52404(`tools/list` 의 Add-on 노출)이다.
- 먼저 있는 결정:
  - #51752: 입구 판정(`verify_mcp_auth` 등)이 늘 `None` 인 `'a option` 을 돌려주던 것을 `unit` 으로 줄였다. 오지 않는 `Some` 을 약속했기 때문이다. 「자격을 확인해서 통과」와 「자격이 필요 없어서 통과」를 갈라야 하는 호출처가 생기면 그때 닫힌 variant 를 돌려주라고 적었다. D1 의 요청 주체가 그 variant 다.
  - RFC-0340 「Request identity」: bearer 가 붙은 요청은 credential 신원으로 풀려야 한다. 풀리지 않으면 `invalid_token` 이다. 문자열 `dashboard` 로 바꾸지 않는다.
  - `specs/auth/AuthIdentityFSM.tla`: I1 `IdentityBindsToken`(풀린 주체가 요청 token 의 주인이다), I2 `NoSilentRewrite`(풀린 주체는 token 으로 정해진다), I3 `FailClosedDefault`(token 이 없으면 Pending 이나 Deny).
  - static bearer 는 요청마다 owner 의 현재 파일 전체와 맞아야 한다. 캐시를 다시 만든 뒤에도 같다(`Auth.find_static_credential_by_token` 의 `.mli` 설명). 이 RFC 는 이 결정을 바꾸지 않는다. 요청마다 한 번은 지금처럼 owner 파일을 읽는다.
  - 호출자 신원(`Mcp_server_eio_caller_identity`): 호출자가 누구인지는 bearer credential 이 정한다. display alias 는 credential 이 이미 가진 이름을 바꾸지 못한다.
  - `Auth.verify_token` 의 alias 규칙: 생성된 nickname 은 stable prefix 가 가진 token 을 쓸 수 있다. 단, 그 token 이 그 prefix 로 풀릴 때만이다. Keeper transport alias(`keeper-<name>-agent`)는 canonical alias credential 이 없는 동안에만 stable keeper token 을 쓴다.
- 코드 좌표는 `origin/main` `083b130b1699` 에서 읽었다. 측정값은 11-16 Codex(gpt-6.1-sol) 측정 보고서와 #52390 본문의 값이다.

## 읽기 전에 — 말의 뜻

- **읽기**: `Auth_credential_base.run_blocking_io`(`auth_credential_base.ml:58`)를 한 번 거치는 일이다. 파일 하나를 stat 하거나 읽는 일이 systhread 로 가고, 끝나면 owner domain 이 fiber 를 다시 깨운다. 붐비면 이 왕복 하나에 몇 초가 든다.
- **bearer 조회**: token 에서 credential 을 찾는 일이다. OAuth access 기록을 먼저 보고, 없으면 static 색인(60초 TTL, 식으면 auth 디렉터리 전체를 다시 훑는다)에서 찾은 뒤 owner 의 현재 파일과 대조한다. 조회 한 번은 읽기 여러 번이다.
- **입구**: HTTP 인증 단계다. `/mcp` 는 `Server_auth.verify_mcp_auth_unscoped`(`server_auth.ml:258`)가 맡는다. 응답 헤더의 `mcp_http_auth` 구간이 이 단계다.
- **아래 층**: 입구 뒤에 요청을 다루는 층이다. 신원 단계(`Mcp_identity` 구간), MCP dispatch, 도구 실행이다.
- **요청 주체**: 입구가 bearer 를 읽어 얻은 결과다. 지금은 `Server_auth.admitted_bearer = { agent_name; role }`(`server_auth.ml:231`)이고, 입구 밖으로 나가지 않는다.

## 0. 요약

11-16 측정에서 `initialize` 한 번이 31.7초 걸렸고, 그중 31.5초가 입구 인증이었다. `tools/list` 는 19번 중 6번이 10초를 넘겼다. 그때 load average 는 455~531(16코어)이었다.

원인은 두 겹이다.

1. 읽기 한 번이 비싸다. owner domain 이 붐비면 왕복 하나에 2~3초가 든다. 이 문제는 RFC-main-domain-scheduler-latency 가 다룬다.
2. 요청 하나가 같은 bearer 를 여러 층에서 다시 읽는다. 층마다 raw token(`?auth_token : string option`)을 받아 스스로 판정하기 때문이다. 이 RFC 는 이 문제를 다룬다.

#52390 과 #52404 는 두 자리를 고쳤다. `tools/call` 은 아직 bearer 를 4~8번 조회한다(§1.2). 같은 고침을 자리마다 하면, raw token 을 받는 다음 층이 같은 일을 또 만든다.

제안은 이렇다. 입구가 bearer 를 한 번 읽어 typed 요청 주체를 만든다. 아래 층은 raw token 대신 그 주체를 받는다. raw token 으로 신원을 정하는 함수는 입구만 부를 수 있게 막는다.

성공 기준은 하나다. `initialize`, `tools/list`, `tools/call`(호출 이름이 token 주인과 같을 때)에서 입구 밖의 `auth-credential-io` 읽기가 0번이다.

## 1. 지금 동작

### 1.1 읽기 한 번의 값

`auth_credential_base.ml:58` 의 `run_blocking_io` 는 `Eio_guard.run_in_systhread ~label:"auth-credential-io"` 다. 이 label 은 Eio suspend 사유로 runtime events 에 남는다.

- 11-16 측정의 health 표본에서 main scheduler lag p99 는 638.7ms, 최대 2,150.8ms 였다.
- #52390 의 측정 프로그램은 20ms 씩 domain 을 붙잡는 fiber 를 옆에 두었다. 그 상태에서 입구 인증 한 번이 기다린 slice 는 27.6/35.9/30.0 에서 17.1/18.8/17.9 로 줄었다. 읽기 횟수가 줄어든 만큼 줄었다.

왕복 한 번의 값은 이 RFC 의 범위가 아니다.

### 1.2 요청 하나가 읽는 자리

코드에서 센 자리다. 실제 읽기 횟수는 §4 의 계기로 잰다.

| 단계 | 자리 | 읽는 것 | `initialize` | `tools/list` | `tools/call` |
|---|---|---|---|---|---|
| 입구 | `Server_auth.admit_bearer`(`server_auth.ml:231`, #52390) | auth 설정, internal Keeper hash, bearer 조회, workspace secret. OAuth 면 `verify_token` | 1 | 1 | 1 |
| OAuth step-up | `Server_oauth_step_up.required_scope`(`server_mcp_transport_http.ml:475`) | auth 설정, OAuth access 기록. loopback 이고 공개·등록 도구 호출일 때만 | – | – | 0~1 |
| 신원 단계 | `body_with_canonical_http_actor`(`server_mcp_transport_http.ml:538`) → `Server_auth.dashboard_actor_for_request` | bearer 조회 | – | – | 1 |
| 신원 단계 | `Server_auth.is_verified_internal_keeper_request`(`server_mcp_transport_http.ml:542`) | internal Keeper hash | 읽음 | 읽음 | 읽음 |
| dispatch | `require_auth`(`mcp_server_eio_protocol.ml:61`), `Requires_auth` 메서드만 | auth 설정, bearer 조회 | – | 1 | 1 |
| Add-on 노출 | `addon_exports_for_request`(`mcp_server_eio_protocol.ml:322`, #52404) | bearer 조회(372행), Add-on 도구가 있으면 role 판정 한 번 | – | 1 | Add-on 도구면 1 |
| 호출자 신원 | `Mcp_server_eio_caller_identity.resolve`(`mcp_server_eio_caller_identity.ml:245`) | internal runtime 이면 internal hash(254행). `resolve_agent_from_token`(264행). 이름이 임시면 한 번 더(157행) | – | – | 1~2 |
| 실행 권한 | `mcp_server_eio_execute.ml:233`·`240`·`248` | `is_auth_enabled`, 그리고 `check_permission`·`authorize_tool` → `resolve_role` 전체: auth 설정, workspace secret, internal hash, owner 파일 두 번 | – | – | 1 |
| 도구별 | `lane_access_for_caller`·`browser_principal_for_caller`·`board_reader_for_caller`(`mcp_server_eio_execute.ml:17`·`41`·`59`) | bearer 조회 | – | – | 0~3 |
| **bearer 조회 합계** | | | **1** | **3** | **4~8** |

auth 설정과 internal hash 도 단계마다 다시 읽는다. `tools/call` 하나가 auth 설정을 3~4번, internal hash 를 2~4번 읽는다.

stdio 는 `Mcp_server_eio.run_stdio`(`mcp_server_eio.ml:161`)가 요청마다 auth 설정을 읽고 bearer 를 한 번 조회한다. dashboard WebSocket 은 `dashboard/hello` 에서 한 번 판정하고 세션에 남긴다. 두 경로는 이미 요청마다 한 번이다.

### 1.3 왜 이렇게 되었나

아래 층은 `?auth_token : string option` 을 받는다. 이 타입은 「아직 아무도 읽지 않은 token」이라는 뜻이라, 층마다 스스로 읽는다. `mcp_server_eio_protocol.ml` 한 파일에서만 `auth_token` 을 넘기는 자리가 38곳이다.

#52390 은 입구에 `admitted_bearer` 를 만들었다. 하지만 `runtime.handle_request ?auth_token`(`server_mcp_transport_http.ml:548`)에는 여전히 raw token 이 넘어간다. 입구가 얻은 답은 입구에서 버려진다.

### 1.4 `tools/call` 의 이름과 token

`tools/call` 은 인자에 `agent_name` 을 받을 수 있다. 호출자 신원 단계가 이 이름, 세션에 남은 이름, 생성된 nickname 중 하나를 고른다. 실행 권한 단계의 `Auth.authorize_tool ~agent_name ~token` 은 그 이름과 token 의 짝을 `verify_token` 으로 확인한다.

- 이름이 token 주인과 같으면, `verify_token` 은 입구가 이미 대조한 owner 파일을 다시 읽는다. #52390 이 입구에서 증명한 것과 같은 동치다.
- 이름이 token 주인과 다르면, `verify_token` 은 그 이름의 파일과 alias 규칙을 본다. 이 판정은 입구의 답만으로는 할 수 없다.

## 2. 목표와 하지 않는 것

### 2.1 목표

1. HTTP `/mcp` 요청 하나는 bearer 를 입구에서 한 번 조회한다.
2. 아래 층은 raw token 대신 입구가 만든 요청 주체를 받는다. 신원 단계, dispatch 의 `require_auth`, Add-on 노출, `tools/call` 실행이 대상이다.
3. 판정 결과는 바뀌지 않는다. 허용·거절, 주체 이름, role, 오류 종류(401·403·503)가 모두 같다. I1~I3, RFC-0340, alias 규칙도 그대로다.
4. 아래 층이 raw token 으로 신원을 다시 정할 수 없게 타입과 검사로 막는다.

### 2.2 하지 않는 것

- 왕복 한 번의 값을 줄이는 일. RFC-main-domain-scheduler-latency 가 다룬다.
- 요청 사이에 bearer 조회 결과를 남기는 캐시. 요청마다 owner 파일과 대조한다는 결정(머리말)을 지킨다.
- auth 저장소를 메모리 스냅샷으로 바꾸는 일(§3.1 후보 B). §7 의 열린 질문으로 남긴다.
- `tools/call` 의 이름 고르기 규칙(alias, nickname, 세션 이름) 변경.

## 3. 설계

### 3.1 후보

| 후보 | 하는 일 | 장점 | 단점 |
|---|---|---|---|
| A. 입구에서 요청 주체를 만들어 넘긴다 | 입구가 typed 주체를 만들고, 아래 층 서명이 `?auth_token` 대신 그 주체를 받는다 | 요청마다 조회 한 번. 타입이 재조회를 막는다. 판정 규칙은 그대로다 | 서명 변경이 넓다(transport → protocol → execute, 38곳 이상). 이름이 token 주인과 다른 `tools/call` 은 따로 다뤄야 한다 |
| B. auth 저장소를 메모리 스냅샷으로 둔다 | auth 설정·hash·색인·credential 을 메모리에 두고, masc 가 쓸 때 바꾼다. 다른 프로세스가 쓴 것은 디렉터리 stat 으로 알아챈다 | 서명을 안 바꾸고 모든 자리가 싸진다. 요청 사이 읽기도 준다 | 「요청마다 owner 현재 파일과 대조」 결정을 바꾼다. 폐기·교체가 보이는 시점이 스냅샷 갱신에 달린다. stat 한 번은 남는다. 파생 상태가 권위처럼 쓰일 수 있다 |
| C. 요청 범위 메모 | fiber-local 에 token → 조회 결과를 요청 동안 남긴다 | 변경이 작다 | 숨은 상태다. 층마다 여전히 raw token 을 받으니, 메모를 거치지 않는 새 층이 같은 일을 다시 만든다. 메모의 수명이 타입에 보이지 않는다 |
| D. 자리마다 고친다 | #52390·#52404 방식을 남은 자리에 반복한다 | 한 번에 작다 | 같은 원인을 N곳에서 손으로 고친다. 다음 층이 또 생긴다 |

### 3.2 결정: 후보 A

**D1. 요청 주체 타입.** `Auth` 에 `private` 타입을 둔다.

```ocaml
type request_principal = private
  | Auth_off
      (* auth 가 꺼져 있다. 지금처럼 Admin 이다. *)
  | Anonymous of { agent_hint : string option }
      (* token 이 없다. require_token 이 꺼져 있을 때만 입구를 지난다. *)
  | Bearer of
      { agent_name : string
      ; role : agent_role
      ; resolved : resolved_bearer
      ; token : string
      }
```

- 값은 입구의 함수만 만든다. `resolved_bearer`·`token_credential` 이 #52404 에서 `private` 가 된 것과 같은 방법이다.
- `token` 은 이름이 token 주인과 다른 `tools/call`(D5)과 OAuth `verify_token` 에 쓴다. 신원을 다시 정하는 데는 쓰지 않는다.

**D2. 입구가 만들어 넘긴다.**

- `Server_auth.admit_bearer` 가 `request_principal` 을 돌려준다.
- `runtime.handle_request` 는 `?auth_token` 대신 `~principal` 을 받는다. 내부 서명이라 hard cut 이다. 호환용 인자를 남기지 않는다.
- stdio(`run_stdio`)와 내부 Keeper runtime 경로도 같은 입구 함수를 거친다.

**D3. dispatch.** `require_auth` 는 주체로 판정한다. `Requires_auth` 메서드는 `Bearer _` 와 `Auth_off` 를 통과시킨다. `Anonymous` 는 auth 가 켜져 있으면 `Missing_token` 이다. 조회는 없다.

**D4. 신원 단계.**

- `body_with_canonical_http_actor` 는 `dashboard_actor_for_request` 대신 주체의 `agent_name` 을 쓴다.
- `is_verified_internal_keeper_request` 는 `resolved = Internal_keeper_bearer` 로 답한다. `x-masc-keeper-name` 헤더 확인은 이미 입구(`identify_bearer`)에서 했다.

**D5. `tools/call` 실행.**

- 호출자 신원 단계는 credential 주인을 주체에서 읽는다(지금 `resolve_agent_from_token`, 264행).
- 실행 권한은 호출 이름에 따라 나뉜다.

| 호출 이름 | 판정 | 읽기 |
|---|---|---|
| 주체의 `agent_name` 과 같다 | `Auth.authorize_tool_for_role ~role:주체.role` | 0 |
| 다르다 | 지금처럼 `Auth.authorize_tool ~agent_name ~token:(Some 주체.token)` | 지금과 같음 |
| 주체가 `Auth_off` | `Admin` 으로 `authorize_tool_for_role` | 0 |
| 주체가 `Anonymous` | 지금처럼 `Auth.authorize_tool ~token:None` | 지금과 같음 |

- 이름이 다른 경우는 alias 규칙을 지금 코드 그대로 쓴다. 규칙을 주체 위의 순수 함수로 옮기는 일은 §7 의 열린 질문이다.
- `lane_access_for_caller`, `browser_principal_for_caller`, `board_reader_for_caller` 는 주체의 role 과 `agent_name` 을 쓴다.

**D6. raw token 함수 가두기.** 아래 층이 `Auth.find_credential_by_token`, `Auth.resolve_agent_from_token`, `Auth.check_permission ~token`, `Auth.authorize_tool ~token` 을 새로 부르면 CI 가 실패한다.

- 허용 목록은 입구 파일(`lib/server/server_auth.ml`, `lib/mcp_server_eio.ml` 의 stdio 입구)과 D5 의 「이름이 다르다」 자리다.
- 검사는 `rg` 로 하고, 허용 목록 밖에서 부르는 자리를 출력하며 실패한다.

### 3.3 남는 비용

- 요청마다 bearer 조회 한 번은 남는다. 붐비면 그 한 번이 여전히 몇 초다. 이 비용은 scheduler RFC 몫이다.
- 이름이 token 주인과 다른 `tools/call` 은 지금처럼 다시 읽는다.
- 서명 변경이 넓다. §6 처럼 단계로 나눈다.
- 입구에서 판정한 뒤 요청이 끝날 때까지 credential 이 바뀌어도, 그 요청은 입구의 답으로 끝난다. 지금은 아래 층이 다시 읽어서 이 변화를 잡을 때가 있다. 같은 변화는 다음 요청이 잡는다. #52390 이 입구에서 받아들인 것과 같은 창이다.

## 4. 기록과 관측

### 4.1 계기

- `auth-credential-io` suspend 횟수를 runtime events 로 센다. 11-16 측정이 쓴 `rtev_fibers.exe` 를 그대로 쓴다. 서버 코드는 바꾸지 않는다.
- 응답 헤더의 `mcp_http_auth`, `Mcp_identity`, `Mcp_dispatch` 구간을 같이 기록한다. 이 구간들은 이미 있다.

### 4.2 기준선과 비교

- 단계 0 에서 `initialize`, `tools/list`, `tools/call`(이름이 token 주인과 같은 공개 도구, 예: `masc_status`)을 각각 20번 보낸다. 요청마다 읽기 횟수와 구간 시간을 남긴다.
- 단계마다 같은 계기, 같은 요청으로 다시 잰다. 부하(load average)를 같이 적는다.

### 4.3 성공 기준

| 요청 | 입구 밖 `auth-credential-io` |
|---|---|
| `initialize` | 0 |
| `tools/list` | 0 |
| `tools/call`, 이름 = token 주인 | 0 |
| `tools/call`, 이름 ≠ token 주인 | 지금 이하 |

## 5. 시험

### 5.1 L1: 판정이 같다

지금 함수(`check_permission`, `authorize_tool`, `resolve_agent_name_for_auth`)를 기준으로 쓴다. 같은 요청을 예전 경로와 새 경로에 넣고 허용·거절, 주체 이름, role, 오류 종류를 비교한다.

- token 종류: static Worker·Admin·Player, OAuth access, internal Keeper(헤더 있음·없음), workspace secret, 만료, 모르는 token, 형식이 틀린 token, token 없음.
- 설정: auth 꺼짐, auth 켜짐 + `require_token` 켜짐·꺼짐.
- `tools/call` 이름: token 주인, 생성 nickname, Keeper transport alias(canonical alias credential 있음·없음), 다른 agent.

### 5.2 L2: 읽기 횟수

테스트 서버에서 요청 하나를 보내고, runtime events 의 `auth-credential-io` 를 입구 구간 안팎으로 나눠 센다. §4.3 의 표를 그대로 단언한다.

### 5.3 L3: TLA+

`AuthIdentityFSM.tla` 에 아래 층을 더한다.

- `Next`: 아래 층은 입구가 정한 주체만 읽는다.
- `BugAction`: 아래 층이 token 으로 주체를 다시 정하고, 그 사이 credential 이 바뀌어 다른 답을 얻는다.
- 새 invariant `OneIdentityPerRequest`: 한 요청 안의 모든 층이 같은 주체를 본다.
- 정상 cfg 는 통과하고, buggy cfg 는 실패해야 한다.

## 6. 단계

| 단계 | 내용 | 확인 |
|---|---|---|
| 0 | 계기와 기준선. §4.2 의 측정을 남긴다 | 측정 기록이 PR 에 붙는다 |
| 1a | `Auth.request_principal` 타입과 입구 함수 `Auth.admit_request`. `/mcp`·observer 판정이 이것을 쓴다. 판정 함수의 반환은 아직 `unit` 이라 transport 와 시험 stub 은 그대로다 | L1 의 입구 부분 |
| 1b | transport `deps` 의 판정이 요청 주체를 돌려주고, `runtime.handle_request` 에 `~principal` 을 더한다. 아래 층은 아직 raw token 도 받는다 | L1, 시험 stub 갱신 |
| 2 | dispatch `require_auth` 와 신원 단계를 주체로 바꾼다(D3, D4) | L1, `initialize`·`tools/list` 의 L2 |
| 3 | `tools/call` 실행과 도구별 조회를 주체로 바꾼다(D5). `?auth_token` 을 지운다 | L1 전체, `tools/call` 의 L2 |
| 4 | raw token 함수 허용 목록 검사(D6)와 TLA+ 갱신 | CI 검사, TLC 정상·buggy |

## 7. 열린 질문

1. 아래 층에서 raw token 이 신원 판정 말고 다른 데 쓰이는가. 예를 들어 Add-on worker 나 Keeper stream 으로 전달되는가. 단계 1 전에 `auth_token` 을 넘기는 자리를 모두 분류한다. 판정에만 쓰이면 D1 의 `token` 필드는 D5 의 「이름이 다르다」와 OAuth `verify_token` 에만 남는다.
2. 후보 B(메모리 스냅샷)를 따로 할 것인가. 「요청마다 owner 현재 파일과 대조」 결정을 바꾸므로 운영자 결정이 먼저 필요하다. 이 RFC 가 끝난 뒤 남는 조회 한 번이 여전히 문제일 때 다시 묻는다.
3. 이름이 token 주인과 다른 `tools/call` 의 alias 규칙을 주체 위의 순수 함수로 옮길 것인가. canonical alias credential 이 있는지는 여전히 파일을 봐야 하므로, 읽기가 0 이 되지는 않는다.
4. stdio 는 프로세스가 사는 동안 token 이 고정이다. 요청마다 한 번 대조하는 결정을 stdio 에도 그대로 둘 것인가. 이 RFC 는 그대로 둔다.
