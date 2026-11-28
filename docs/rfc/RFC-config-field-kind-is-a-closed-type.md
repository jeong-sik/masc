---
rfc: "config-field-kind-is-a-closed-type"
title: "설정 필드의 종류를 닫힌 타입 하나로 정하고 여러 줄 글을 그 종류로 둔다"
status: Draft
created: 2026-11-28
updated: 2026-11-28
author: claude
related: []
---

# RFC config-field-kind-is-a-closed-type: 설정 필드의 종류를 닫힌 타입 하나로 정하고 여러 줄 글을 그 종류로 둔다

- 상태: **초안.** 운영자가 「C 는 RFC부터」를 골랐다(2026-11-28). 이 RFC 가 승인되기 전에는 구현하지 않는다.
- 계기: 운영자가 「Keeper Prompt 편집이 불편하다」고 했다. 대시보드와 TUI 의 Keeper 설정 화면에서 `keeper.instructions` 를 한 줄 입력으로 고친다.
- 코드 좌표는 `origin/main` `99eea6d98bdc9` 에서 읽었다.

## 0. 요약

- Keeper 31개 가운데 24개의 `keeper.instructions` 가 여러 줄이다. 가장 긴 것은 61줄, 9 KB 다.
- 대시보드 Keeper 설정 탭은 이 값을 `<input type="text">` 로 고친다. 이 입력은 값에서 줄바꿈을 지운다. 한 글자만 고쳐 저장해도 61줄이 한 줄로 저장된다.
- 서버가 필드 종류를 문자열로 보내고, 세 클라이언트 자리가 그 문자열을 따로 비교한다. 여러 줄 글이라는 종류는 어디에도 없다.
- 이 RFC 는 네 가지를 정한다.
  1. 서버가 필드 종류를 닫힌 합타입 하나로 만들고, 여러 줄 글(`Text`)을 그 한 갈래로 둔다(D1).
  2. TUI 디코더는 서버가 쓰는 이름만 받고, `Text` 는 여러 줄 입력으로 연다(D2).
  3. 대시보드는 응답 경계에서 종류를 한 번 해석하고, 화면은 그 타입으로 빠짐없이 나눈다(D3).
  4. 옛 이름을 읽는 호환 코드는 만들지 않는다(D4).

## 1. 지금 모습

### 1.1 서버가 종류를 만드는 곳

`GET /api/v1/config/schema` 는 필드마다 `"type"` 문자열을 싣는다. 그 문자열을 만드는 곳이 여덟 군데다.

| 위치 | 대상 | 만드는 방법 |
|---|---|---|
| `lib/server/server_dashboard_http_candle_config.ml:1607`·`:1630`·`:1655` | `runtime.default` 같은 라우팅 필드 | 문자 그대로 `"string"` |
| 같은 파일 `:1725`→`:1754` | 환경 변수 registry 행 | `Registry.value_kind_label`(`lib/config/keeper_runtime_setting_registry.ml:1013`) 또는 `"secret"` |
| 같은 파일 `:1814`→`:1849` | `runtime.toml` 의 나머지 값 | TOML 값의 모양을 보고 고른 문자열. `cache-retention` 키 이름만 따로 `"enum"` |
| 같은 파일 `:1932` | Provider 설명 필드 | 호출자가 넘긴 `~type_str` |
| 같은 파일 `:2101`→`:2121` | Keeper 필드 | `field ~type_str` 인자. `instructions` 는 `:2204` 에서 `"string"` |
| 같은 파일 `:2139`→`:2154` | Keeper runtime 배정 | 직접 고른 문자열 |

- `enum_values` 는 종류와 따로 실린다. `"enum"` 인데 값 목록이 없는 필드도 서버 타입으로는 만들 수 있다.
- 종류 이름은 `"boolean"`·`"integer"`·`"float"`·`"string"`·`"enum"`·`"string_list"`·`"structured"`·`"secret"` 여덟 개다.

### 1.2 클라이언트가 종류를 읽는 곳

- TUI `decode_field_kind`(`lib/masc_tui/protocol/wire_config.ml:273`)는 위 여덟 이름에 더해 `"bool"`·`"int"`·`"table_array"`·`"secret_ref"` 도 받는다. 서버는 이 네 이름을 보내지 않는다.
- TUI 는 모르는 이름이 하나라도 오면 설정 응답 전체를 거절한다(`decode_list`, 같은 파일 `:505`).
- TUI 는 `Field_string` 을 한 줄 입력(`Form.Text_val`, `lib/masc_tui/screens_core/overlays.ml:594`)으로 연다. `Form.Multiline_val` 은 이미 있지만 설정 필드에는 쓰이지 않는다.
- 대시보드는 `ConfigFieldSpec.type` 을 `string` 으로 둔다(`dashboard/src/api/config-schema.ts:11`). 모양이 틀린 필드는 말없이 건너뛴다(같은 파일 `:112` 의 `continue`).
- 대시보드에서 종류 문자열을 비교하는 곳이 셋이다.
  - `patchOpForField`(`config-schema.ts:62`): 서버가 보내지 않는 `'bool'`·`'int'`·`'number'`·`'string_array'` 까지 비교한다.
  - Runtime 설정 화면(`dashboard/src/workspaces/settings/index.ts:365`)
  - Keeper 설정 탭(`dashboard/src/workspaces/keepers/keeper-config-tab.ts:436`)
- Keeper 설정 탭과 Keeper 디버그 화면(`keeper-debug-companion.ts:970`)은 문자열 필드를 모두 `<input type="text">` 로 고친다.

### 1.3 여러 줄 값이 실제로 있다

2026-11-28 에 운영 설정을 읽기 전용으로 셌다(값은 출력하지 않았다).

- `~/me/.masc/config/keepers/*.toml` 31개 가운데 `keeper.instructions` 가 여러 줄인 파일: 24개
- 줄 수가 많은 것: 61줄(9,074 B), 33줄, 26줄, 22줄
- `runtime.toml` 에서 여러 줄인 문자열: `fusion.presets.trio.panel_system_prompt`, `fusion.presets.trio.judge_system_prompt`

### 1.4 줄바꿈이 사라지는 경로

- HTML 표준은 `type="text"` 입력의 값 정리 규칙을 「값에서 줄바꿈을 지운다」로 정한다(<https://html.spec.whatwg.org/multipage/input.html#text-(type=text)-state-and-search-state-(type=search)>).
- jsdom 으로 확인했다. `input.value = "line1\nline2\r\nline3"` 를 넣으면 `"line1line2line3"` 이 되고, `<textarea>` 는 `"line1\nline2"` 를 그대로 둔다.
- Keeper 설정 탭은 입력 이벤트가 오면 `input.value` 를 그대로 초안에 넣는다(`keeper-config-tab.ts:465`). 한 글자를 고친 초안은 이미 줄바꿈이 없다.
- 서버 쓰기 경로는 줄바꿈을 지킨다. `Toml_line_editor.escape_string`(`lib/toml_line_editor/toml_line_editor.ml:17`)이 `\n` 을 `\\n` 으로 쓰고, 여러 줄 값의 범위도 읽는다(같은 파일 `:297`). 줄바꿈은 클라이언트에서만 사라진다.

## 2. 문제

- 여러 줄 글이 종류로 없으니 클라이언트는 그 값을 한 줄 입력으로 연다. 대시보드는 저장할 때 값을 바꾸고, TUI 는 줄바꿈을 넣을 수 없다.
- 종류가 문자열이라 서버 여덟 곳과 클라이언트 네 곳이 서로를 모른다. 새 종류를 더하면 이 열두 곳을 손으로 맞춰야 하고, 컴파일러는 빠진 곳을 알려 주지 않는다.
- 서버가 보내지 않는 별칭 여덟 개(TUI 넷, 대시보드 넷)가 남아 있다. 읽는 사람은 그 이름을 보내는 곳이 있다고 믿게 된다.

## 3. 결정

### D1. 서버: 종류는 닫힌 합타입 하나다

`lib/types/config_field_kind.ml(i)` 를 둔다.

```ocaml
type t =
  | Boolean
  | Integer of { min_inclusive : int option; max_inclusive : int option }
  | Float of {
      min_inclusive : float option;
      min_exclusive : float option;
      max_inclusive : float option;
    }
  | Line                      (** 한 줄 글. 줄바꿈은 값이 아니다. *)
  | Text                      (** 여러 줄 글. 줄바꿈도 값이다. *)
  | Enum of { first : string; rest : string list }
                              (** 값 목록은 하나 이상이다. *)
  | String_list
  | Structured
  | Secret

val wire_members : t -> (string * Yojson.Safe.t) list
(** ["type"] 과, 종류에 딸린 ["range"]·["enum_values"] 를 함께 낸다. *)
```

- 여덟 생산자는 모두 `t` 를 만든다. `field ~type_str ?enum_values` 는 `field ~kind` 가 된다.
- 값 목록 없는 `Enum` 은 만들 수 없다. 범위는 숫자 종류에만 붙는다.
- `keeper.instructions` 는 `Text` 다. `fusion.presets.*.{panel,judge}_system_prompt` 처럼 프롬프트를 담는 runtime 키도 `Text` 로 둘지는 §6 에서 운영자가 정한다.
- 전선 이름은 지금 이름을 그대로 쓰고 `"text"` 하나를 더한다. `Line` 의 전선 이름은 `"string"` 이다.
  - 장점: 바뀌는 이름이 없어 diff 가 작다.
  - 단점: 코드 이름(`Line`)과 전선 이름(`"string"`)이 다르다. 변환은 `wire_members` 한 곳에만 있다.
- `runtime.toml` 의 나머지 값(§1.1 셋째 행)은 지금처럼 TOML 값 모양으로 종류를 고른다. 다만 결과가 문자열이 아니라 `t` 다. 문자열 값에 줄바꿈이 있다고 `Text` 로 바꾸지 않는다. 종류는 키가 정하고 값이 정하지 않는다.

### D2. TUI: 서버가 쓰는 이름만 받고 `Text` 는 여러 줄로 연다

- `Wire_config.field_kind` 에 `Field_text` 를 더한다.
- `decode_field_kind` 는 `wire_members` 가 내는 아홉 이름만 받는다. 별칭 넷은 지운다.
- 설정 폼은 `Field_text` 를 `Form.Multiline_val` 로 연다. 저장은 지금 `Field_string` 처럼 `Set_scalar` 로 보내되 줄바꿈을 그대로 둔다.
- 설정 화면의 한 줄 즉석 편집은 `Field_text` 에서 폼을 연다.

### D3. 대시보드: 경계에서 한 번 해석하고 빠짐없이 나눈다

- `ConfigFieldSpec.type: string` 을 `kind: ConfigFieldKind` 로 바꾼다. `ConfigFieldKind` 는 판별 필드가 있는 union 이다. `Enum` 은 값 목록을, 숫자 종류는 범위를 같이 가진다.
- `decodeFields` 가 응답을 읽을 때 종류를 해석한다. 모르는 이름이 오면 지금처럼 필드를 건너뛰지 않고 응답 전체를 에러로 돌린다. TUI 와 같은 규칙이다.
- `patchOpForField`, Runtime 설정 화면, Keeper 설정 탭, Keeper 디버그 화면은 `kind` 로 `switch` 하고 `assertNever` 로 끝낸다. 별칭 넷은 지운다.
- `Text` 는 세 화면 모두 `<textarea>` 로 연다.

### D4. 호환 코드는 만들지 않는다

- 대시보드는 서버가 자기 번들로 내보낸다(`lib/server/server_account_console.ml:35`). 서버와 대시보드의 판이 어긋나지 않는다.
- TUI 는 따로 설치하는 실행 파일이다. 옛 TUI 는 새 서버의 설정 응답에서 `"text"` 를 모르므로 설정 화면 전체가 `unknown config field type "text"` 로 실패한다. 새 TUI 를 설치하면 풀린다. 옛 이름을 받는 reader 는 두지 않는다.
- 세 층(서버·TUI·대시보드)은 stack 하나로 묶어 한 번에 병합한다. 서버 층만 먼저 병합되면 main 의 TUI 설정 화면이 깨진다.

## 4. 다른 방법과 고르지 않은 이유

| 방법 | 장점 | 단점 | 판단 |
|---|---|---|---|
| A. 값에 줄바꿈이 있으면 클라이언트가 `<textarea>` 를 연다 | 서버를 안 고친다 | 비어 있거나 한 줄인 지시문에는 줄바꿈을 넣을 수 없다. 데이터를 보고 종류를 짐작한다 | 고르지 않음 |
| B. `"text"` 문자열 하나만 더하고 기존 비교 네 곳에 갈래를 더한다 | diff 가 가장 작다 | 문자열 비교 열두 곳이 그대로 남는다. 다음 종류도 같은 손질을 반복한다 | 고르지 않음(워크어라운드 기준의 「문자열 분류기 보강」) |
| C. `"string"` 옆에 `multiline: bool` 을 더한다 | 기존 이름을 안 건드린다 | `boolean` 필드에 `multiline: true` 같은 틀린 조합을 만들 수 있다 | 고르지 않음 |
| D. 닫힌 합타입(이 RFC) | 새 종류를 더하면 서버와 TUI 컴파일러, 대시보드 `assertNever` 가 빠진 곳을 알린다 | 여덟 생산자와 네 소비자를 한 번에 고친다 | 고름 |

## 5. 단계와 확인 방법

1. 서버 `Config_field_kind` 와 여덟 생산자 → 확인: 시험이 Keeper 대상 응답에서 `keeper.instructions` 의 `type` 이 `"text"` 임을 본다. 종류마다 `wire_members` 의 모양을 골든으로 고정한다. 값 목록 없는 enum 은 타입으로 막혀 시험이 필요 없다.
2. TUI 디코더와 폼 → 확인: `"bool"` 같은 옛 별칭과 모르는 이름을 거절한다. `"text"` 필드의 폼이 `Multiline_val` 이다. 줄바꿈이 든 값이 `Set_scalar` 로 줄바꿈 그대로 나간다.
3. 대시보드 디코더와 세 화면 → 확인: 모르는 종류를 받으면 응답이 에러다. Keeper 설정 탭이 `text` 필드를 `<textarea>` 로 그리고, 줄바꿈이 든 값을 고친 초안에 줄바꿈이 남는다. §1.4 의 jsdom 관찰을 회귀 시험으로 둔다.
4. 끝에서 끝 → 확인: 줄바꿈이 든 값을 설정 PATCH 로 dry-run 해서 diff 에 `\n` 이스케이프가 나오고, 다시 읽은 값이 보낸 값과 같다.

세 층은 같은 stack 의 PR 셋이다. 맨 위 PR 의 호스트 Test 가 세 묶음(서버 설정 시험, TUI `test_protocol_net`·`test_store`, 대시보드 vitest)을 모두 통과해야 Ready 로 올린다.

## 6. 운영자가 정할 것

1. `Text` 로 둘 키: `keeper.instructions` 만인가, `fusion.presets.*` 의 프롬프트 키도인가. 추천은 둘 다다. 두 키 모두 실제 값이 여러 줄이다(§1.3).
2. 전선 이름: `Line` 을 지금처럼 `"string"` 으로 보낼지, `"line"` 으로 바꿀지. 추천은 `"string"` 유지다. 바꾸면 클라이언트 이름도 같이 바뀌지만 얻는 동작이 없다.

## 7. 범위 밖

- 설정 PATCH 의 연산 이름도 별칭을 받는다(`"set_scalar" | "set_string"`, `server_dashboard_http_candle_config.ml:2486`). 같은 종류의 문제지만 이 RFC 는 응답 쪽만 다룬다.
- 지시문 편집기 자체(미리보기, 길이 표시, 병합 프롬프트 보기)는 Keeper Prompt 탭(#55441)과 TUI 프롬프트 블록 서브탭(#55458)이 맡는다.
