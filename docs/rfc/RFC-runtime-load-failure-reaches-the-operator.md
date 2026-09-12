---
title: "설정을 못 읽은 이유가 화면까지 닿는다"
status: Draft
created: 2026-09-12
author: claude-main
---

# RFC: 설정을 못 읽은 이유가 화면까지 닿는다

- 관련: PR #35336 (설정이 깨졌을 때 무엇이 깨졌는지 화면에 말한다)
- 범위: `Runtime.load_list` 의 실패 표현과 그 소비자. 검증 규칙 자체는 그대로 둔다.

## 무슨 일이 있었나 (사람이 읽는 서두)

2026-09-12, 로컬 모델 하나를 board 후보에서 빼는 편집에서 `runtime.toml` 의
`[models.local-ornith-15-9b-q4]` 선언이 사라졌다. 짝이 되는
`[ollama.local-ornith-15-9b-q4]` 바인딩은 "나중에 되살리기 쉽게" 남겨 뒀다.

그 상태에서 벌어진 일은 셋이다.

1. 서버가 뜨지 못했다. 키퍼 전부 `not running`, 상태 조회 500.
2. `masc doctor` 는 `model_connection: invalid` 를 말했지만 이유는
   "runtime.toml is unreadable or has invalid runtime references" 까지였다.
3. 설치 위저드는 그 `invalid` 를 보고 워크스페이스 선택부터 다시 물었다.

원인을 찾는 데 걸린 시간의 대부분은 2번 때문이다. 같은 정보를
`masc runtime-probe` 는 처음부터 정확히 말하고 있었다.

```
runtime-probe failed: .../runtime.toml: 1 binding(s) reference a provider or
model that is not declared, so the runtime they define does not exist:
  ollama.local-ornith-15-9b-q4 names model "local-ornith-15-9b-q4",
  which has no [models.local-ornith-15-9b-q4] row
```

한 줄이면 끝날 진단이 화면에 닿지 않았다. 3번은 PR #35336 이 검사 이름과 사유를
화면에 올려 완화했지만, 그 사유가 여전히 위 문장까지다. 이 RFC 는 2번을 다룬다.

## 지금 구조

`Runtime.load_list` 는 `(..., string) result` 를 돌려준다. 실패가 문자열 하나로
납작해진다.

실패 경로는 일곱 개다. 여섯은 `materialize_config`
(`lib/runtime/runtime.ml:1315-1399`) 안에 순서대로 있다.

| # | 갈래 | 메시지를 만드는 곳 |
|---|---|---|
| 1 | 선언 없는 provider/model 참조 | `validate_no_dangling_bindings` |
| 2 | `[runtime].default` 없음 | `materialize_config` 안 |
| 3 | `[runtime].default` 가 가리키는 런타임 없음 | `materialize_config` 안 |
| 4 | 배정·미디어 failover·verifier 슬롯의 참조 미해결 | `validate_runtime_references` ×3 |
| 5 | lane 후보 해결 실패 | `lanes_of_decls` |
| 6 | max-context 검증 실패 | `validate_runtime_max_context` |
| 7 | TOML 자체를 못 읽음 | `Runtime_toml.parse_file` |

소비자 쪽에서 이 문자열을 실제로 받는 자리는 40곳이다
(`rg -A 3 "Runtime\.load_list" lib/ bin/ test/` 기준).

그중 `lib/operator/onboarding_status.ml:44` 는 문자열을 통째로 버린다.

```ocaml
| Error _ ->
  (* Resolver diagnostics can contain operator input. Keep the error useful
     without copying credential-bearing TOML into either UI. *)
  ...
  "The workspace runtime.toml is unreadable or has invalid runtime references."
```

## 그 주석은 일곱 갈래 중 하나에만 맞다

버린 근거는 "리졸버 진단에 운영자 입력이 섞일 수 있다" 이다. 실제로 확인하면
그 위험은 7번에만 있다.

- 1~6번 메시지는 masc 가 직접 쓴 고정 문장 + 식별자 + 설정 파일 경로다.
  `dangling_reference_reason` 이 만드는 문장이 그 예로, `local-ornith-15-9b-q4`
  같은 **id** 만 인용한다. 값은 들어가지 않는다.
- 7번만 다르다. `lib/runtime/runtime_toml.ml:2439` 가
  `Otoml.Parse_error (_, msg)` 의 메시지를 그대로 담는다. 외부 파서가 만든
  문장이라 입력의 일부를 인용할 수 있다.

지금은 일곱을 한 문자열로 합쳐 놓았으므로, 소비자가 고를 수 있는 선택지는
"전부 보여주기" 아니면 "전부 감추기" 둘뿐이다. 그래서 가장 안전한 쪽을
골랐고, 그 대가로 여섯 갈래의 안전한 진단까지 같이 사라졌다.

## 같은 `invalid` 가 네 곳에서 나온다

`lib/operator/onboarding_status.ml` 에서 `Invalid` 를 만드는 자리는 넷이다.

| 줄 | 검사 | 무슨 상태인가 | 마법사가 고치는가 |
|---|---|---|---|
| `:49` | `model_connection` | `load_list` 가 실패했다 | 갈래에 따라 다르다 |
| `:59` | `model_connection` | imp 에 배정된 런타임을 못 찾는다 | **고친다** |
| `:80` | `keeper_persistence` | imp 메타데이터를 못 읽는다 | 아니다 |
| `:93` | `keeper_declaration` | imp 선언에 수리가 필요하다 | 아니다 |

`:49` 와 `:59` 는 검사 이름까지 같다. 밖에서 보면 넷 다 `"invalid"` 한 글자다.

`:59` 를 마법사가 고친다는 것은 실측으로 확인했다. 격리 워크스페이스에
`[runtime.assignments]` 의 `"imp"` 를 없는 런타임으로 바꿔 두면 `doctor` 가
`invalid` 를 말하는데, 저장 경로가 스테이지에서 돌리는
`runtime-default-set <id> --setup-lanes --setup-imp` 가 그 줄을 제자리에서
바꾼다(`lib/runtime/runtime.ml:2109-2133`). 검사는 `needs_verification` 으로
돌아온다.

이 구분이 없어서 치른 값이 있다. PR #35336 의 첫 시도는 `invalid` 이면 마법사를
멈추게 했다. 고칠 수 있는 `:59` 까지 막았고, 깨진 워크스페이스를 두고 다른
디렉터리를 고르는 유일한 출구도 같이 닫았다. 적대적 리뷰가 실측으로 반증해
되돌렸다.

즉 문자열 하나로 납작해진 대가는 두 방향이다. 사유가 화면에 닿지 않는 것이
하나, 소비자가 수리 가능성을 판단할 수 없는 것이 둘이다.

### 세분이 아니라 정확한 이름이 답이다

`invalid` 를 여러 값으로 쪼개는 대신, 지금 있는 값을 제 뜻대로 쓰면 된다.
`condition` 에는 이미 `Needs_setup` 이 있고 그 뜻은 "설정하면 된다" 이다.
마법사가 고치는 상태는 `Invalid` 가 아니라 `Needs_setup` 이다. `Invalid` 는
"사람이 파일을 고쳐야 한다" 로 남긴다.

그 판정을 하려면 `onboarding_status` 가 실패의 갈래를 알아야 하고, 그것이
아래 `load_failure` 다. 새 플래그를 더하지 않는다.

## 제안

실패에 모양을 준다. 일곱 갈래가 닫혀 있으므로 catch-all 없이 쓸 수 있다.

```ocaml
type load_failure =
  | Toml_unparsable of Runtime_toml.parse_error list
  | Undeclared_bindings of (string * drop_reason) list
  | Default_runtime_absent
  | Default_runtime_unresolved of string
  | Reference_unresolved of reference_site * string
  | Lane_unresolved of string * string
  | Max_context_invalid of string * int
```

그리고 청중이 둘이므로 렌더도 둘이다.

- `to_diagnostic_text : load_failure -> string` — 지금 문자열을 그대로 재현한다.
  CLI 와 로그가 쓴다. 40곳의 이행은 이 함수 한 번의 호출로 끝난다.
- `to_operator_text : load_failure -> string` — 화면용. 1~6번은 지금
  `runtime-probe` 가 말하는 만큼 말한다. 7번은 위치(`path`)와 오류 개수까지만
  말하고 파서 원문은 담지 않는다. 자세히 보려면 `runtime-probe` 로 간다고
  안내한다.

`onboarding_status` 는 `to_operator_text` 를 쓴다. 그러면 오늘 사고에서
`doctor` 는 이렇게 말했을 것이다.

```
[invalid] model_connection: ollama.local-ornith-15-9b-q4 names model
"local-ornith-15-9b-q4", which has no [models.local-ornith-15-9b-q4] row.
```

## 하지 않는 것

- **fail-fast 를 무르지 않는다.** 깨진 바인딩 하나 때문에 전체가 멈추는 건
  지금 동작이고, 그대로 둔다. 그 바인딩만 빼고 계속 가면 운영자가 선언했다고
  믿는 런타임이 조용히 없어진다. 이 RFC 는 실패를 없애는 게 아니라 실패의
  이유를 전달한다.
- **자동 복구를 넣지 않는다.** 짝 없는 바인딩을 masc 가 지우지 않는다. 무엇을
  지울지는 운영자가 정한다.
- **검증 규칙을 바꾸지 않는다.** 일곱 갈래의 판정 기준은 그대로다. 바뀌는 것은
  결과를 담는 그릇뿐이다.

## 이행

1. `load_failure` 와 두 렌더 함수를 `runtime.mli` 에 낸다.
2. `materialize_config` 와 `load_list_internal` 이 문자열 대신 variant 를 만든다.
   각 검증 함수의 반환 타입도 같이 바뀐다.
3. 소비자 40곳을 `to_diagnostic_text` 로 옮긴다. 기계적 치환이고 동작은 같다.
4. `onboarding_status` 만 typed 로 갈라 `to_operator_text` 를 쓰고, 마법사가
   고치는 갈래를 `Invalid` 가 아니라 `Needs_setup` 으로 판정한다.

3번이 이 작업의 대부분이다. 한 PR 에 담으면 리뷰가 어려우므로 1~2번과 3~4번을
stacked PR 로 나눈다. 그 사이 단계에서도 main 은 항상 빌드된다.

## 검증

- `doctor --json` 이 선언 없는 바인딩의 **id** 를 메시지에 담는다.
- `Toml_unparsable` 의 `to_operator_text` 결과에 파서 원문이 들어가지 않는다.
  파서 메시지에 표식 문자열을 넣은 입력으로 확인한다.
- 일곱 갈래 각각에 대해 `to_diagnostic_text` 가 지금 문자열과 같은지 고정한다.
  이행 3번이 동작을 바꾸지 않았다는 증거가 된다.
- imp 배정만 깨진 워크스페이스에서 `doctor` 가 `Invalid` 가 아니라 `Needs_setup`
  을 말한다. 마법사가 그 상태를 고친다는 실측과 판정이 일치한다.
- `masc runtime-probe` 의 출력은 바뀌지 않는다.
