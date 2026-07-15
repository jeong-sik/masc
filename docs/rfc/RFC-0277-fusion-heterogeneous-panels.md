# RFC-0277 — Fusion: 이종 패널 그룹(heterogeneous panel groups)

- Status: Draft
- Author: Vincent (yousleepwhen) + Claude
- Created: 2026-06-22
- Parent: RFC-0252 (fusion-panel-judge-deliberation) — 본 RFC는 preset 구성을 개정한다.
- Scope: `lib/fusion_core/` (preset/config/types), `lib/fusion/` (panel/orchestrator/tool), `bin/fusion_run.ml`, `config/runtime.toml` (`[fusion]`)
- Boundary: OAS는 0줄 변경. judge/sink 계약 무변경. 심판은 preset당 1개 유지.

---

## 1. 동기 (Motivation)

### 1.1 현재 모델의 표현 제약

RFC-0252의 preset은 **하나의 동질 패널**만 표현한다 (`lib/fusion_core/fusion_policy.ml:4`):

```ocaml
type preset =
  { name : string
  ; panel : string list           (* 모델 id 들, 전부 같은 설정으로 실행 *)
  ; panel_system_prompt : string  (* 패널 전체 공유 *)
  ; web_tools : bool              (* 패널 전체 공유 *)
  ; panel_timeout_s : float
  ; ... }
```

`panel_system_prompt`/`web_tools`/`panel_timeout_s`가 패널 전체에 **하나씩** 적용되므로, 한 preset 안에서 "tool 없는 빠른 그룹 + web tool 켠 신중한 그룹"처럼 **이질적(heterogeneous)** 구성을 표현할 수 없다. 근거: Self-MoA 비판은 *동질·중복* 패널이 다양성 이득을 깎는다는 것이므로, 이질 패널이 그 비판을 피하는 방향이다.

### 1.2 이 RFC가 하는 것

1. **이종 패널 그룹**: `preset.panel : string list` → `preset.panels : panel_group list`. 각 그룹이 자기 `system_prompt`/`web_tools`/`timeout_s`를 갖는다. 모든 그룹의 에이전트를 **하나의 `Async_agent.all`**에 union으로 던진다 (동시성/격리 경계 무변경). judge/sink는 평면 `panel_outcome list`만 본다.
2. **단일 그룹 문법**: flat `panel=[...]` 문법은 정확히 길이-1 그룹으로 해석한다. 그룹형과 flat 문법을 함께 쓰면 `Conflicting_panel_grammar`로 거부한다.

비목표(Non-goals): per-group judge, keeper 저작/Free Fusion, Subgraph/nested, router, group provenance를 judge/sink에 노출 — 전부 본 RFC 밖.

---

## 2. 타입 + config 변경

### 2.1 `panel_group` (closed record)

`lib/fusion_core/fusion_policy.ml`에 추가:

```ocaml
type panel_group =
  { models : string list
  ; system_prompt : string
  ; web_tools : bool
  ; timeout_s : float
  }
[@@deriving show, eq]

type preset =
  { name : string; panels : panel_group list
  ; judge : string; judge_system_prompt : string; judge_timeout_s : float }
[@@deriving show, eq]
```

`Validated_preset.of_preset`은 **평탄화 모델 집합이 비어 있지 않음**을 검증한다 (`preset_models = List.concat_map (fun g -> g.models) panels`). 모델 수 상한은 없고 `panels=[]`는 명시적 실패다.

### 2.2 config 문법 + desugar

새 문법은 array-of-tables다:

```toml
[fusion.presets.mixed]
judge = "..."
judge_system_prompt = "..."
[[fusion.presets.mixed.panels]]
panel = ["fast1", "fast2"]
web_tools = false
[[fusion.presets.mixed.panels]]
panel = ["careful1"]
web_tools = true
panel_timeout_s = 180.0
```

flat `panel=[...]`는 같은 `parse_group` 함수를 preset 테이블 자체에 적용해 길이-1 그룹으로 해석한다. 두 문법이 같은 키 이름을 쓰기 때문이다.

**Otoml 동작 (실소스 확인, `otoml_base.ml:178,332-337`)**: `get_array get_value`는 `TomlArray | TomlTableArray` 둘 다 element 리스트로 반환하므로 `[[...]]`와 inline array 모두 처리된다. `find_opt`/`find_or`는 **Key_error만 None/default로 삼키고 Type_error는 전파**한다 — 따라서 `panels=5` 같은 malformed scalar는 `get_array`의 Type_error가 `of_toml`의 핸들러까지 올라가 `Toml_type_error`로 fail-fast된다. (parse_preset이 `find_opt`를 쓰는 이유는 `panels`/`panel` 존재 여부(Some/None) 판별이지 Type_error 회피가 아니다.)

### 2.3 strict 거부 (Unknown→Permissive 회피)

`config_error`에 닫힌 합 variant 3종 추가: `Empty_panels`(그룹 0개), `Conflicting_panel_grammar`(`[[panels]]`+flat `panel` 동시), `Duplicate_panel_model`(평탄화 모델 리스트 중복). **중복 모델 거부**는 `Async_agent.all`이 카드명(=model)으로 결과를 키잉하므로 중복이 답변 충돌(silent 손실)을 부르기 때문이다 — cross-group뿐 아니라 한 그룹 내 중복(`["a","a"]`)도 같은 이유로 거부한다.

`panel=[]`(모델 0개)는 길이-1 빈 그룹으로 desugar되어 `Empty_panel_models`로 잡힌다. "그룹 0개"(`Empty_panels`)와 "모델 0개"(`Empty_panel_models`)는 다른 조건이므로 다른 variant로 구분한다.

---

## 3. 실행과 관측

그룹 수·모델 수·토큰·호출 횟수는 실행 허용 조건이 아니다. 전체 입력 집합을 실행하고 각 패널 실패를 격리하며, usage는 sink/metrics에 관측으로만 남긴다.

---

## 4. byte-identity 복구 (실행축)

`preset.web_tools`/`panel_timeout_s`를 per-group으로 옮기면 심판/외곽-timeout이 대표값을 잃는다. 단일 그룹과 그룹형 구성을 같은 실행 경계로 투영하기 위해 순수 derive 함수를 둔다:

- `panel_outer_timeout_of groups` = 그룹 timeout 중 max (단일이면 그 그룹 timeout = `panel_timeout_s`).
- `judge_web_tools_of ~req_web_tools groups` = `req || (어느 그룹이든 web_tools)` (단일이면 `req || group.web_tools` = 오늘).

검증: `test/fusion_core/test_fusion.ml`의 `config/panels_golden`(flat == 단일 그룹 `equal_preset`)과 `judge_args/single_group_identity`(derive 함수 == 오늘 매핑)가 이 불변식을 핀한다.

---

## 5. 검증 + ripple

- focused tests: 단일/그룹형 동등성, 헤테로 멀티그룹, strict 에러(empty/conflicting/duplicate/unexpected field), judge-arg derive, 게이트·judge-parse.
- ripple: preset record는 단일 생성 지점(`fusion_config.ml`)이라 필드 변경을 컴파일러가 강제한다. `bin/fusion_run.ml`(벤치마크 하네스)은 첫 그룹 plumbing을 대표로 써 동질 arm을 비교한다.
- 전체 빌드(`dune build bin/fusion_run.exe`)로 heavy Masc lib 포함 컴파일 확인.

## 6. anti-pattern self-check

| 항목 | 판정 |
|---|---|
| 닫힌 합 유지 | `panel_group` closed record, `config_error`에 variant 추가(catch-all 신설 없음) |
| strict config | empty/conflicting/duplicate/malformed 전부 명시적 Error |
| cap 제거 | per_hour cap을 **추가가 아니라 제거** — cap/cooldown 안티패턴의 역방향 |
| N-of-M 없음 | 단일 생성 지점 + 한 커밋 atomic 변경 |
