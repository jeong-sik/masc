---
rfc: "settings-typed-delivery"
title: "설정은 env 이름이 아니라 typed 값으로 읽는 곳에 닿는다"
status: Draft
created: 2026-09-02
updated: 2026-09-02
author: vincent
related: ["0032"]
---

# RFC: 설정은 env 이름이 아니라 typed 값으로 읽는 곳에 닿는다

## 0. Summary

Keeper 런타임 설정은 지금 env 이름을 전달 경로로 쓴다. `runtime.toml` 의 값은 부팅 때 그
설정의 env 이름으로 boot override 저장소에 실리고, 읽는 곳은 그 env 이름으로 문자열을 다시
꺼내 파싱한다. 그래서 한 설정이 TOML 키, env 이름, 저장소 키라는 세 문자열을 가지고,
"같은 설정인가" 는 레지스트리 행의 프로즈로만 이어진다.

이 RFC 는 설정을 부팅 경계에서 한 번 파싱한 typed 레코드로 만들고, 읽는 곳이 그 레코드의
필드를 읽게 한다. env 와 TOML 은 그 레코드를 채우는 두 입력이 되고, 전달 경로에서는
사라진다. 우선순위(env > TOML > 기본값)와 운영자가 `export MASC_…` 로 값을 주는 방식은
그대로다. 바뀌는 것은 "값이 어디를 거쳐 읽는 곳에 닿는가" 뿐이다.

계기는 2026-09-02 헌법 정합 작업이다. "TOML 이 있는 env 는 env 쪽을 지운다" 로 적었던
항목 세 개(`MASC_KEEPER_PROVIDER_CALL_DEADLINE_SEC` ↔ `turn.provider_call_deadline_sec`,
`MASC_KEEPER_BOOTSTRAP_ENABLED` ↔ `bootstrap.enabled`,
`MASC_KEEPER_HEARTBEAT_INTERVAL_SEC` ↔ `heartbeat.interval_sec`)를 코드에서 보니 env
이름이 중복이 아니라 TOML 값의 전달 경로였다. 지우려면 전달 경로부터 바꿔야 한다.

## 1. 지금

- 인벤토리: `lib/config/keeper_runtime_setting_registry.ml` 의 행 55개. TOML 키를 가진
  행 30개(`Toml_and_env`), env 전용 25개(`Env_only`). #32575 이후 모든 행이 살아 있다.
- 전달: `Keeper_runtime_config.load_and_apply` 가 서버 부팅에서 `runtime.toml` 을 읽고,
  `resolve_one` 이 행마다 "그 env 가 안 잡혀 있으면 TOML 값을 env 이름으로
  `Config_boot_overrides.set`" 한다(`lib/keeper_runtime/keeper_runtime_config.ml:59-80`).
  저장소는 env 이름 → 문자열 맵이다.
- 읽기: `Env_config_keeper` 의 값 17개가 모듈 초기화 시점에 `get_int ~default:300
  "MASC_KEEPER_HEARTBEAT_INTERVAL_SEC"` 모양으로 읽는다(`env_config_keeper.ml:464`).
  `Env_config_core.raw_value_opt` 가 실제 env → boot 저장소 순으로 문자열을 찾는다
  (`env_config_core.ml:23-29`). 파싱은 읽는 곳마다 한다.
- 현재값 보고: `Keeper_runtime_config.effective_setting_value` 가 env 이름 문자열 29개를
  `match` 로 분기해 각 getter 를 부른다(`keeper_runtime_config.ml:448-522`). 새 행을
  더하면 이 match 에도 손으로 한 줄을 더해야 하고, 빠뜨려도 컴파일러는 모른다.
- 출처 보고: `Keeper_runtime_resolved.source_of_env_name` 이
  `Config_boot_overrides.source` 의 문자열 라벨 `"env" | "boot_override" | "default"` 를
  variant 로 되돌리고, 모르는 라벨이면 예외를 낸다(`keeper_runtime_resolved.ml:22-30`).
- 읽는 곳 증명: 행의 `~consumers:[ "Env_config_keeper.KeeperKeepalive"; … ]` 는 모듈
  이름 문자열이다. `validate_registry` 는 TOML 행의 이 목록이 비어 있지 않은지만 본다.
- 편집 뒤: 대시보드가 `runtime.toml` 을 검증·저장하지만, 부팅 스냅샷이 재기동 전까지 옛
  값을 내므로 지운 키는 `pending_restart` 로 보고된다(`keeper_runtime_config.ml:399`).
- 테스트: boot 저장소가 프로세스 전역이라 `Config_boot_overrides.reset_for_tests` 를
  테스트 파일 8개가 부른다.
- 라이브: `~/.zshenv` 가 `MASC_KEEPER_*` 4개를 export 하고 그중
  `MASC_KEEPER_BOOTSTRAP_ENABLED=true` 가 autoboot 를 켠다. `~/me/.masc/config/runtime.toml`
  의 `[turn]` 에는 `stream_idle_timeout_sec`, `provider_call_deadline_sec` 두 키만 있다.
- 래칫: `scripts/env-read-baseline.json` 이 코드의 env 읽기 수를 위로 못 늘게 막는다.

## 2. 문제

1. 한 설정이 문자열 셋을 가진다. TOML 키, env 이름, 저장소 키. 셋을 잇는 것은 레지스트리
   행 하나의 필드 배치뿐이고, 읽는 곳은 그중 env 이름을 다시 문자열로 든다.
2. env 이름을 축으로 한 문자열 분류기가 둘 있다. `effective_setting_value` 의 29-arm
   match 와 `source_of_env_name` 의 라벨 변환. 헌법의 semantic string matching 금지에
   걸린다.
3. 읽는 곳 증명이 프로즈다. 컴파일러가 "이 행을 읽는 코드가 있다" 를 보장하지 않는다.
   #32500 이 지운 부고 주석과 #32575 가 지운 묘비 행은 그 프로즈가 낡아서 생겼다.
4. 파싱이 읽는 곳마다 흩어져 있다. 같은 문자열을 `get_int` 가 매번 해석하고, 잘못된
   값은 모듈 초기화에서 `Config_error` 예외로 터진다. Parse, don't validate 의 반대다.
5. 테스트가 프로세스 전역 저장소를 리셋하는 백도어에 기댄다.

## 3. 목표 / 비목표

목표

- 설정 하나에 선언 하나. 이름·TOML 키·env 이름·타입·범위·기본값·reload class 가 한
  값에 들어 있고, 레지스트리 행과 대시보드 JSON 은 그 선언에서 파생된다.
- 부팅 경계에서 한 번 파싱한 typed 레코드 `Keeper_settings.t`. 읽는 곳은 필드를 읽는다.
- 출처는 필드마다 typed 값(`Env | Toml | Default`)으로 로드 시점에 고정된다.
- 위 세 쌍 같은 "중복" 은 개념이 사라진다. 필드가 정체성이고 env 와 TOML 은 그 필드의
  두 입력이다.

비목표

- env 를 입력에서 빼는 것. 운영자는 계속 `export MASC_…` 로 값을 준다.
- 우선순위 변경. env > TOML > 기본값 그대로.
- `runtime.toml` 의 키 이름·섹션 변경. 파일은 그대로 읽힌다.
- 런타임 hot reload 추가. reload class 는 유지하고 §4.6 에서 경계만 정한다.
- 대시보드·TUI 화면 변경. 와이어 필드 이름은 §4.5 의 범위에서만 움직인다.

## 4. 설계

### 4.1 선언

```ocaml
type 'a field =
  { name : string                       (* 사람이 부르는 이름, 로그·대시보드용 *)
  ; env_name : string
  ; toml_key : string option            (* None 이면 env 전용 *)
  ; parse : string -> ('a, string) result
  ; default : 'a
  ; range : 'a range
  ; reload : reload_class
  }

type packed = Packed : 'a field -> packed
val all : packed list                    (* 레지스트리 행은 여기서 파생 *)
```

선언은 값 하나이고, 지금 레지스트리가 프로즈로 들고 있던 `value_kind`·`value_range`·
`default_display` 는 `parse`/`default`/`range` 에서 나온다. `~consumers` 문자열 목록은
없어진다. 읽는 곳은 §4.3 의 필드 접근이고, 안 읽는 필드는 컴파일러 경고 69(쓰기만 하는
필드)와 dead-export 래칫이 잡는다.

### 4.2 로드

```ocaml
val load
  :  env:(string -> string option)
  -> toml:Keeper_toml_loader.toml_doc option
  -> (t * source_map, issue list) result
```

부팅에서 한 번 부른다. 필드마다 env 문자열 → TOML 값 → 기본값 순으로 첫 번째 있는 것을
`parse` 하고, 실패는 지금의 `validation_issue`(`Unknown_key | Type_mismatch |
Out_of_range | Invalid_schema_version`) 와 같은 typed 값으로 모아 돌려준다. 예외로
터지던 `Config_error` 는 이 경계에서 issue 가 된다. `env` 를 인자로 받으므로 테스트는
가짜 env 를 넘기고 전역 저장소를 리셋하지 않는다.

### 4.3 읽기

`Env_config_keeper.KeeperKeepalive.interval_sec` 같은 getter 는 서명을 유지한 채
`Keeper_settings.current ()` 의 필드를 돌려준다. `current` 는 부팅에서 채운 `Atomic`
스냅샷이다. 읽는 시점에 env 를 찾지 않는다. `Env_config_core.raw_value_opt` 로 가던
17개 읽기가 사라지고 `scripts/env-read-baseline.json` 의 수가 그만큼 내려간다.

### 4.4 중복의 소멸

`MASC_KEEPER_HEARTBEAT_INTERVAL_SEC` 와 `heartbeat.interval_sec` 는 `interval_sec`
필드의 `env_name` 과 `toml_key` 다. 지울 것이 없고, "env 쪽을 지운다" 는 문장은 성립하지
않는다. `~/.zshenv` 의 export 는 그대로 첫 번째 입력으로 읽힌다.

### 4.5 현재값과 출처

`effective_setting_value` 의 29-arm match 는 `all` 을 순회하며 `Packed f` 마다 현재
스냅샷의 값을 `f` 의 표시 함수로 문자열화하는 한 함수로 바뀐다. 출처는 `load` 가 돌려준
`source_map` 의 typed 값이라 `source_of_env_name` 과 `Config_boot_overrides.source` 의
라벨 변환이 없어진다. 대시보드 JSON 의 `keeper_setting_schema` 와
`settings_projection` 은 같은 필드 이름을 유지한다. 대시보드 TS 는 둘 다 `unknown` 으로
통과시키고 있어(#32575 리뷰) 읽는 쪽 변경은 없다.

### 4.6 reload 경계

`Keeper_settings.reload` 는 `load` 를 다시 돌려 스냅샷을 바꾸되, `reload = Process_restart`
인 필드는 부팅 값을 유지하고 그 사실을 `source_map` 에 `Pending_restart` 로 적는다.
지금 `"pending_restart"` 문자열이 하던 일을 typed 로 하는 것이고, hot reload 자체를 새로
넣는 것은 아니다. 언제 `reload` 를 부를지는 이 RFC 밖이다.

## 5. 단계

| PR | 내용 | 동작 변화 | 증명 |
|---|---|---|---|
| 1 | `field`/`packed` 선언과 `all`. 레지스트리 행을 `all` 에서 파생 | 없음 | `schema_to_yojson`·`settings_projection_to_yojson` 바이트 동일 핀 |
| 2 | `Keeper_settings.load` + 부팅 배선. getter 는 스냅샷 필드 반환 | 없음 | 라이브 `runtime.toml` + `~/.zshenv` 로 부팅한 두 바이너리의 projection JSON 동일 |
| 3 | `Config_boot_overrides` 의 keeper 설정 쓰기·`effective_setting_value` match·`source_of_env_name` 삭제. `reset_for_tests` 호출 8곳 제거 | 없음 | env-read 래칫 하락, dead-export 래칫 |
| 4 | RFC-0032 와의 관계 정리(§7), `docs/ENV-CONTRACT.md` 갱신 | 문서 | — |

각 PR 은 ≤20k 토큰 단위로 나누고, 적대 리뷰를 병렬로 붙인다. 로컬 dune 빌드 없이 CI
`@check` 와 위 핀으로 검증한다.

## 6. 검증

- PR1: 레지스트리 JSON 바이트가 변경 전후 같다. 행 수 55, TOML 30, env 전용 25 그대로.
- PR2: 같은 입력(라이브 파일·env)으로 부팅한 `settings_projection` JSON 이 같다.
  `validate_doc` 의 issue 목록이 기존 픽스처 전부에서 같다.
- PR3: `rg 'raw_value_opt|get_int|get_bool|get_float' lib/config/env_config_keeper.ml` 0건.
  `Config_boot_overrides` 를 keeper 설정이 더 이상 부르지 않는다.
- 전체: 경고 69 가 읽히지 않는 필드를 내면 그 필드는 선언에서 지운다.

## 7. RFC-0032 와의 관계

RFC-0032(Environment Knob Unification, Draft, 2026-05-05)는 §3 에서 "env 가 소스로
남고 카탈로그는 그것을 설명한다" 를 비목표로 못 박았다. §2.1 의 카탈로그는 OCaml
레지스트리로 이미 있다. 이 RFC 는 0032 의 그 비목표를 뒤집는다. env 는 입력으로 남지만
소스는 typed 레코드다. 0032 를 Superseded 로 돌릴지, 카탈로그 부분만 Implemented 로
닫고 나머지를 이 RFC 로 넘길지는 PR4 에서 정한다.

## 8. 트레이드오프

- 얻는 것: 문자열 분류기 둘과 프로즈 증명이 사라진다. 설정 추가가 선언 한 값으로 끝난다.
  테스트가 전역 상태를 리셋하지 않는다.
- 내는 것: `Env_config_keeper` 의 모듈 초기화 시점 계산이 `load` 이후로 옮겨진다. 지금은
  "TOML 로더가 이 모듈 초기화 전에 돈다" 는 주석(`env_config_keeper.ml:1-11`)이 순서를
  보장한다. 새 순서는 `current ()` 가 로드 전에 불리면 typed 실패를 내는 것으로 명시한다.
- 안 바뀌는 것: 운영자 인터페이스. `export MASC_…` 도, `runtime.toml` 도 그대로다.
