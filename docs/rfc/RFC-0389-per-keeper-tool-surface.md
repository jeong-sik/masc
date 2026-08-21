---
rfc: "0389"
title: "Keeper 별 도구 표면 — 98개를 전원에게 매 턴 보내는 것을 그만둔다"
status: Draft
created: 2026-08-22
updated: 2026-08-22
author: claude
supersedes: []
superseded_by: null
related: ["0080", "0084", "0182"]
implementation_prs: []
---

# RFC-0389: Keeper 별 도구 표면

## 0. Summary

모든 Keeper 가 매 턴 **똑같은 도구 98개, 72,485 바이트**를 받는다. 누구도 전부 쓰지 않는데
아무도 덜 받지 않는다. 이 RFC 는 이미 선언돼 있으나 쓰이지 않는 `keeper_tool_group` 을
가시성 축으로 승격하는 설계와, 그러기 위해 결정해야 할 항목을 정리한다.

이 RFC 는 masc#29337 (GLM-5-Turbo 가 tool_use 이름에 인자를 섞어 보내는 건) 을 고친다고
주장하지 않는다. 아래 §2 에 그 이유를 적는다.

## 1. 관측 (2026-08-22)

### 1.1 크기

`test_keeper_tool_schema_bytes` 가 이미 재고 있는 값이다.

| 항목 | 바이트 | 비고 |
|---|---|---|
| 도구 스키마 전체 | 72,485 | model-visible 98개, 2026-08-07 측정 |
| 조립된 시스템 프롬프트 | 9,167 | `test_keeper_system_prompt_bytes` |

도구 배열이 시스템 프롬프트의 **7.9배**다. 라이브 로그의 `Available tools:` 목록은 101개였다
(측정 이후 3개가 늘었다).

### 1.2 구성

무엇을 줄일 수 있는지 보려고 스키마 소스의 문자열 리터럴을 셌다.

| 항목 | 바이트 | 비중 |
|---|---|---|
| 도구 설명 (`description`) | 11,909 (67개, 평균 177) | 16% |
| 파라미터별 설명 (input_schema 안) | 2,693 (35개) | 4% |
| 나머지 = input_schema 구조 | ~58,000 | 80% |

**설명을 줄이는 것으로는 최대 20% 다.** 비용은 스키마 구조 자체에 있고, 그건 도구 하나를
빼야 같이 빠진다. 도구당 평균 740 바이트다.

### 1.3 지금 구조

```ocaml
(* keeper_tool_descriptor.ml:2568 *)
let model_visible_schemas () = ...
```

인자가 없다. Keeper 를 구분할 자리가 없으므로 전원이 같은 목록을 받는다.

```ocaml
(* keeper_tool_descriptor.ml:26 *)
type keeper_tool_group =
  | Execute_group | Search_files_group | Filesystem_group | Board_group
  | Voice_group | Workspace_group | Surface_group | Memory_group
  | Meta_group | Core_group
```

그룹은 이미 모든 서술자에 붙어 있다 (`keeper_tool_group_of_runtime_handler`). 지금은 진단
JSON 에만 실리고 가시성에는 관여하지 않는다.

### 1.4 회수할 중복은 없다

`keeper_model_names` 는 서술자당 이름을 **최대 하나** 낸다. `Transport_alias` 와
`Operator_only` 는 빈 목록이다. 즉 98개는 서로 다른 98개 서술자이고, 별칭 중복 제거로 얻을
바이트는 없다. 줄이려면 도구를 빼는 수밖에 없다.

## 2. 이 RFC 가 주장하지 않는 것

masc#29337 은 GLM-5-Turbo 가 `tool_use` 이름 자리에 인자를 섞어 보내고 한 턴에서 88번
회복하지 못한 건이다. 표면 크기가 그 방아쇠라는 가설을 세우고 라이브로 쟀다.

| 가설 | 시행 | 재현 |
|---|---|---|
| 도구 개수 (1 / 10 / 25 / 50 / 101개, 최대 90KB) | 25 | 0 |
| 컨텍스트 길이 (35k / 67k / 114k prompt tokens) | 9 | 0 |
| 오염된 호출이 이미 히스토리에 있음 (1회 / 4회, 카탈로그 유/무) | 20 | 0 |

**54회 중 0회.** 표면 크기와 그 사고를 잇는 근거는 없다. 이 RFC 의 근거는 비용이지 그 사고가
아니다. #29337 은 열어 둔다.

## 3. 제안

`model_visible_schemas` 를 Keeper 인자를 받는 함수로 바꾸고, 가시성을 그룹 선언에서 도출한다.

```ocaml
val model_visible_schemas : groups:keeper_tool_group list -> Masc_domain.tool_schema list
```

`Core_group` 은 항상 포함한다. 나머지는 Keeper 설정이 선언한다.

## 4. 결정해야 할 항목

이 RFC 는 아래를 결정하지 않은 채 낸다. 결정 없이 구현하면 조용한 기본값이 생긴다.

1. **선언 위치.** `.masc/config/keepers/<name>.toml` 인가, 코드의 역할 정의인가.
2. **선언이 없을 때.** 전체를 주는 것은 지금과 같고 하드컷이 아니다. 빈 집합은 Keeper 를
   무력화한다. 어느 쪽도 안전한 기본값이 아니므로 **선언을 필수로 하고 미선언은 부팅 거부**
   가 후보다.
3. **보이지 않는 도구를 부르면.** 지금은 `Tool not found` 가 나간다 (#29338 에서 목록을
   뺐다). 그룹 밖 호출은 "없는 도구" 와 다른 사실이므로 문구가 달라야 하는지.
4. **발견 경로.** `keeper_tools_list` 가 이미 있다. 이것이 자기 그룹만 보여줄지, 전체를
   보여주되 호출 가능 여부를 표시할지.
5. **`Meta_group` 취급.** `masc_tool_help` 같은 자기기술 도구를 항상 열지.

## 5. 검증

구현 PR 이 만족해야 할 것:

- `test_keeper_tool_schema_bytes` 를 그룹별 측정으로 확장한다. 지금의 전체 ratchet 은
  유지하고, 그룹 조합별 바이트를 같이 고정한다.
- 미선언 Keeper 가 부팅에 실패한다는 테스트 (2번 결정이 그렇게 났을 때).
- 그룹 밖 도구를 부른 턴이 typed 실패로 끝나고 그 문구가 `Tool not found` 와 구별된다는 테스트.
- `keeper_tool_group_of_runtime_handler` 가 모든 서술자에 대해 exhaustive 임을 컴파일 타임에
  강제한다 (지금도 그렇지만, 가시성 축이 되면 누락의 대가가 달라진다).

## 6. 하지 않을 것

- 설명 문구 줄이기. §1.2 대로 최대 20% 이고, 문구는 모델이 도구를 고르는 근거다. 크기를
  이유로 깎으면 선택 품질과 맞바꾸게 된다.
- 도구를 동적으로 붙였다 떼기. 턴 중간에 표면이 바뀌면 캐시와 재현이 같이 깨진다. 표면은
  턴 시작에 고정한다.
