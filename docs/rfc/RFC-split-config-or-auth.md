# RFC: `Config_or_auth` 를 설정과 인증으로 가른다

## 요약

`Keeper_terminal_reason.Config_or_auth` 는 설정 오류와 인증·권한 거부를 한 variant 에 담는다.
이 variant 는 조건 없이 `Disp_operator_action_required` 로 가고, Keeper 는 거기서 멈춰 운영자 응답을 기다린다.

두 실패는 운영자가 할 수 있는 일이 다르다. 설정 오류는 값을 고치면 풀린다.
인증·권한 거부는 호스트에 자격 증명이 멀쩡히 있어도 나므로, 운영자가 `gh auth login` 을 다시 해도 풀리지 않는 경우가 있다.
같은 갈래로 묶여 있는 한 Keeper 는 둘을 구분해 보고할 수 없고, 운영자는 매번 어느 쪽인지 직접 확인해야 한다.

## 왜 지금

2026-09-21 에 `~/me/.masc/keepers/*/execution-receipts/2026-09/*.jsonl` 전량을 셌다.
21명 Keeper · 56,824 턴이다.

| 항목 | 값 |
|---|---|
| `operator_action_required` | 2,113 |
| 그 2,113건의 `operator_disposition_reason` | 전부 `preflight_config_error` |
| 그중 `config_error` (설정) | 1,261 (59.7%) |
| 그중 `api_error_authorization` (권한) | 852 (40.3%) |
| 그 밖의 코드 | 0 |

sandbox 별로도 갈리지 않는다. 세 레인 모두에서 난다.

| sandbox | 차단 / 전체 | 비율 |
|---|---|---|
| microvm | 1,793 / 48,473 | 3.7% |
| docker | 182 / 1,879 | 9.7% |
| remote_ssh | 138 / 6,477 | 2.1% |

docker 의 비율이 microvm 의 2.6배다. sandbox 종류가 원인이 아니라는 뜻이다.

Keeper 별로는 `analyst` 624/5,194 (12.0%), `goo-yang-bong` 270/2,379 (11.3%),
`kidsnote-slack-context-collector` 269/1,839 (14.6%) 순이다.

## 지금 구조

`lib/keeper_runtime/keeper_terminal_reason.ml:59`

```ocaml
let is_config_or_auth_wire wire =
  match wire with
  | "config_error" | "api_error_auth" | "api_error_authorization" -> true
  | _ ->
    String.equal wire wire_provider_error_auth
    || String.equal wire wire_provider_error_authorization
    || String.starts_with ~prefix:wire_provider_error_invalid_config_prefix wire
;;
```

여섯 가지 wire 가 한 variant 로 들어간다. 설정 쪽 둘(`config_error`,
`provider_error_invalid_config*`)과 인증·권한 쪽 넷이다.

`lib/keeper/keeper_execution_receipt.ml:138`

```ocaml
let preflight_config_failure =
  match terminal_reason with
  | Keeper_terminal_reason.Config_or_auth _ -> true
  | _ -> false
in
...
| _ when preflight_config_failure ->
  Disp_operator_action_required, Reason_preflight_config_error
```

variant 가 하나이므로 정책도 하나다.

`.mli:75` 는 이 갈래가 먼저 걸러진다는 점을 이미 적어 두었다.

> Config/auth-like provider codes still land in `[Config_or_auth]` because that bucket is ranked earlier.

## 무엇이 문제인가

1. **이름이 두 가지를 담는다.** `Config_or_auth` 의 `or` 가 그것이다.
   타입이 구분을 포기했으므로 아래쪽 어디에서도 구분할 수 없다.
2. **정책이 하나다.** 설정이든 인증이든 운영자를 세운다.
   인증·권한 852건에서 운영자가 할 일이 없으면 그 시간은 그대로 버려진다.
3. **순위가 먼저라 더 빨려든다.** provider 쪽 인증 코드도 이 갈래로 들어온다.
   나중에 provider 실패를 따로 다루려 해도 이 버킷을 먼저 통과한다.

## 제안

### 1. variant 를 둘로 가른다

```ocaml
type t =
  ...
  | Config_invalid of string     (* config_error, provider_error_invalid_config* *)
  | Auth_denied of string        (* api_error_auth, api_error_authorization,
                                    provider_error_auth, provider_error_authorization *)
  ...
```

`Config_or_auth` 는 남기지 않는다. 남기면 호출자가 옛 갈래를 계속 고를 수 있다.
컴파일러가 모든 소비자를 강제로 방문하게 한다.

### 2. 판정을 갈래마다 따로 쓴다

```ocaml
| Keeper_terminal_reason.Config_invalid _ ->
  Disp_operator_action_required, Reason_config_invalid
| Keeper_terminal_reason.Auth_denied _ ->
  (* 정책은 열어 둔 결정 1 *)
```

`Reason_preflight_config_error` 도 둘로 나눈다. 대시보드가 이 문자열을 읽으므로
(`lib/server/server_dashboard_http_composite_claims.ml:349`) 그쪽도 같이 바꾼다.

### 3. 분류기를 wire 목록 두 개로 나눈다

`is_config_or_auth_wire` 를 `is_config_invalid_wire` 와 `is_auth_denied_wire` 로 가른다.
두 함수 모두 지금처럼 canonical wire 만 받는다. 부분 문자열 검사를 늘리지 않는다.

## 영향 범위

`rg -n 'Config_or_auth' --glob '*.ml' --glob '*.mli' -c` 기준 3파일 12곳이다.

| 파일 | 곳 | 역할 |
|---|---|---|
| `lib/keeper_runtime/keeper_terminal_reason.mli` | 2 | 타입 선언, 문서 |
| `lib/keeper_runtime/keeper_terminal_reason.ml` | 4 | 타입 정의, 분류기, `to_wire` |
| `lib/keeper/keeper_execution_receipt.ml` | 6 | 판정과 receipt 이유 |

문자열 `"preflight_config_error"` 는 대시보드에도 있다
(`lib/server/server_dashboard_http_composite_claims.ml:349`).
variant grep 에는 안 잡히므로 같이 고친다.

## 검증

- `to_wire` 왕복: 여섯 wire 각각이 새 variant 로 분류되고 원래 문자열로 되돌아오는지.
- exhaustive match: `Config_or_auth` 를 지우면 컴파일러가 모든 소비자를 짚는다.
  그 목록이 위 표의 12곳과 일치하는지 확인한다.
- receipt 판정: `Config_invalid` 는 `operator_action_required` 를 유지하고,
  `Auth_denied` 는 열어 둔 결정 1 이 정해진 뒤 그에 맞는 테스트를 쓴다.
- 라이브: 이 변경 뒤 하루치 receipt 에서 두 이유가 각각 나오는지,
  합이 지금의 `preflight_config_error` 와 같은지 센다.

## 하지 않는 것

- 인증 실패를 자동으로 복구하지 않는다. 이 RFC 는 갈래를 나누는 데까지다.
- 부분 문자열 검사를 새로 만들지 않는다. wire 목록은 지금처럼 닫힌 집합이다.
- `Config_or_auth` 를 별칭으로 남기지 않는다. 남기면 분리가 선택이 된다.

## 열어 둔 결정

1. **`Auth_denied` 의 disposition.** 운영자를 세우는 게 맞는지, 아니면
   `retry_later` 나 `fail_open_next_runtime` 인지. 852건의 원인을 더 봐야 정해진다.
   현재 `api_error_authorization` 만 852건이고 다른 세 wire 는 0건이라,
   실제로 도는 인증 실패가 한 종류인지 먼저 확인해야 한다.
2. **대시보드 표시.** 두 이유를 따로 보여줄지, 합쳐 보여주고 상세에서 가를지.

## 근거 기록

- 실측 스크립트와 출력: 2026-09-21 세션, `execution-receipts` 전량 집계.
- 숫자는 이 문서에 박아 두었다. 다시 재려면 같은 경로를 같은 방식으로 세면 된다.
  재면서 달라지면 이 문서의 숫자가 아니라 그때의 측정이 맞다.
