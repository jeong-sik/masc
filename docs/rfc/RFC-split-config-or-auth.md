# RFC: `Config_or_auth` 를 설정과 인증으로 가른다

## 요약

`Keeper_terminal_reason.Config_or_auth` 는 설정 오류와 인증·권한 거부를 한 variant 에 담는다.
이 variant 는 조건 없이 `Disp_operator_action_required` 로 가고, Keeper 는 거기서 멈춰 운영자 응답을 기다린다.

묶인 두 쪽이 실제로 무엇인지 세어 보면 갈라야 할 이유가 드러난다.
인증 쪽 852건은 자격 증명 문제가 아니라 **사용량 한도**다 — 838건이 주간 한도,
14건이 5시간 한도이고, 제공자가 그것을 `api_error_authorization` 으로 알린다.

한도는 이 저장소에 **두 종류**가 있고 서로 다른 문으로 나간다.
짧은 주기 한도(`api_error_rate_limited`)는 자동으로 다음 런타임에 넘긴다(2,699건).
주간·5시간 한도(`api_error_authorization`)는 운영자를 세운다(852건).
두 집합의 교집합은 **0건**이다. 같은 "한도"인데 한쪽만 자동 경로를 쓴다.

운영자를 세우는 것 자체는 틀리지 않았다. 주간 한도는 일주일 동안 그 런타임을
못 쓰게 하므로 사람이 슬롯을 옮겨야 하고, 실제로 그렇게 했다(아래).
문제는 그 판정이 **설정 오류와 한 이름을 쓰는 것**이다.

설정 쪽 1,261건은 런타임 능력·세션 불일치다. `multimodal_input` 532건,
`preserve_thinking` 347건, `official_client_session.*` 337건 순이다.
일부는 설정으로 끌 수 있고 일부는 런타임이 맞춰야 한다.

같은 갈래로 묶여 있는 한 Keeper 는 둘을 구분해 보고할 수 없고,
기다리면 풀릴 한도 초과가 운영자를 세운다.

## 왜 지금

2026-09-21 에 `<base-path>/.masc/keepers/*/execution-receipts/2026-09/*.jsonl` 전량을 셌다
(`<base-path>` 는 `MASC_BASE_PATH` 또는 `--base-path` 가 정한다).
21명 Keeper · 56,824 턴이다.

| 항목 | 값 |
|---|---|
| `operator_action_required` | 2,113 |
| 그 2,113건의 `operator_disposition_reason` | 전부 `preflight_config_error` |
| 그중 `config_error` (설정) | 1,261 (59.7%) |
| 그중 `api_error_authorization` | 852 (40.3%) |
| 그 밖의 코드 | 0 |

852건의 본문을 읽으면 권한이 아니라 한도다.

| 메시지 | 건수 |
|---|---|
| `You've reached your weekly (7-day) usage limit` | 838 |
| `You've reached your 5-hour usage limit` | 14 |

1,261건도 마찬가지로 종류가 갈린다.

| 메시지 | 건수 |
|---|---|
| `Invalid config 'multimodal_input': provider glm:glm-5.3 cannot accept …` | 532 |
| `Invalid config 'preserve_thinking': Claude Code official-client runtime …` | 347 |
| `Invalid config 'official_client_session.claim': input_rejected(…)` | 232 |
| `Invalid config 'official_client_session.context_admission': …` | 105 |
| `Invalid config 'official_client_session.phase': …` | 17 |

`Config_or_auth` 가 받는 wire 는 여섯인데 **실제로 도는 것은 둘뿐이다**.

| wire | 09월 턴 수 |
|---|---|
| `config_error` | 1,261 |
| `api_error_authorization` | 852 |
| `api_error_auth` | 0 |
| `provider_error_auth` | 0 |
| `provider_error_authorization` | 0 |
| `provider_error_invalid_config*` | 0 |

날짜로는 한쪽이 몰려 있다. 설정은 11일에 퍼지고 가장 많은 날이 09-03 의 385건(31%),
한도는 7일에 퍼지고 09-19 하루가 424건(50%)이다. 한도 쪽은 쿼터가 터진 날에 몰린다.

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
2. **이유 코드가 하나다.** 설정이든 인증이든 `preflight_config_error` 로 나간다.
   운영자는 두 쪽에 실제로 다르게 대응한다. 한도 쪽에는 런타임을 옮기고
   (감사 로그 `runtime_config_write`), 설정 쪽에는 toml 을 고친다.
   대응이 갈리는데 이유 코드가 같으면 화면에서 둘을 구분할 수 없다.
3. **순위가 먼저라 더 빨려든다.** provider 쪽 인증 코드도 이 갈래로 들어온다.
   나중에 provider 실패를 따로 다루려 해도 이 버킷을 먼저 통과한다.

## 제안

### 1. variant 를 둘로 가른다

```ocaml
type t =
  ...
  | Config_invalid of string     (* config_error, provider_error_invalid_config* *)
  | Authorization_refused of string
                                 (* api_error_auth, api_error_authorization,
                                    provider_error_auth, provider_error_authorization *)
  ...
```

`Config_or_auth` 는 남기지 않는다. 남기면 호출자가 옛 갈래를 계속 고를 수 있다.
컴파일러가 모든 소비자를 강제로 방문하게 한다.

이름을 `Auth_denied` 가 아니라 `Authorization_refused` 로 둔다.
실측에서 이 wire 가 실어 나른 것은 자격 증명 거부가 아니라 사용량 한도였다.
wire 가 말하는 것은 "제공자가 이 요청을 authorization 으로 거절했다"까지이고,
그 안의 이유는 wire 로 알 수 없다. 이름이 실체보다 넓게 말하지 않게 한다.

### 2. 판정을 갈래마다 따로 쓴다

```ocaml
| Keeper_terminal_reason.Config_invalid _ ->
  Disp_operator_action_required, Reason_config_invalid
| Keeper_terminal_reason.Authorization_refused _ ->
  (* 열어 둔 결정 2 가 정한 대로 운영자를 세우는 쪽을 유지한다 *)
  Disp_operator_action_required, Reason_authorization_refused
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

1. **한도와 자격 증명 거부를 wire 로 가를 수 있는가.** 지금은 못 가른다.
   제공자가 주간·5시간 한도를 `api_error_authorization` 으로 알리므로,
   같은 wire 가 "기다리면 풀림"과 "사람이 고쳐야 함"을 둘 다 실어 나른다.
   메시지 본문을 읽어 가르는 것은 문자열 분류기를 하나 더 만드는 일이라 하지 않는다.
   제공자 응답에 구분 가능한 필드(`retry-after`, 오류 코드)가 있는지 먼저 확인해야 한다.
2. **`Authorization_refused` 의 disposition.** 지금처럼 운영자를 세우는 쪽을 유지한다.
   주간 한도는 일주일 동안 그 런타임을 못 쓰게 하므로 사람이 슬롯을 옮겨야 하고,
   `retry_later` 로 보내면 일주일 내내 같은 벽에 부딪힌다.
   감사 로그가 그것을 그대로 보여 준다. `<base-path>/.masc/audit/` 의
   `runtime_config_write` 316건은 전부 운영자 창구가 썼고(`masc-tui` 257,
   `admin` 34, `dashboard` 14, 나머지 11) 키퍼가 쓴 것은 0건이다.
   09-19 이후 assignment 지시 33건은 모두 적용됐고, 지시부터 그 런타임의
   첫 턴까지 중앙 4.4분이다.
   짧은 주기 한도는 `fail_open_next_runtime` 으로 자동 처리되므로 여기 섞이지 않는다.
   바꿀 것은 처분이 아니라 **이름**이다 — 설정 오류와 같은 이유 코드를 쓰는 것.
3. **`Config_invalid` 안의 두 종류.** `multimodal_input`·`preserve_thinking` 은
   런타임 능력 불일치이고 `official_client_session.*` 는 세션 상태다.
   둘 다 운영자가 toml 로 끌 수 있는 것은 아니다. 이 RFC 는 가르지 않고,
   필요하면 별도 RFC 로 연다.
4. **대시보드 표시.** 두 이유를 따로 보여줄지, 합쳐 보여주고 상세에서 가를지.

## 근거 기록

- 실측 스크립트와 출력: 2026-09-21 세션, `execution-receipts` 전량 집계.
- 숫자는 이 문서에 박아 두었다. 다시 재려면 같은 경로를 같은 방식으로 세면 된다.
  재면서 달라지면 이 문서의 숫자가 아니라 그때의 측정이 맞다.
