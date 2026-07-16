# RFC-0277 — Fusion: 이종 패널 그룹(heterogeneous panel groups) + 발동 예산 제거

- Status: Draft
- Author: Vincent (yousleepwhen) + Claude
- Created: 2026-06-22
- Parent: RFC-0252 (fusion-panel-judge-deliberation) — 본 RFC는 §6(게이트/예산)·§9(preset)을 개정한다.
- Scope: `lib/fusion_core/` (preset/config/types), `lib/fusion/` (panel/orchestrator/tool), `bin/fusion_run.ml`, `config/runtime.toml` (`[fusion]`)
- Boundary: OAS는 0줄 변경. judge/sink 계약 무변경. 심판은 preset당 1개 유지.

---

## 1. 동기 (Motivation)

### 1.1 현재 모델의 두 제약

RFC-0252의 preset은 **하나의 동질 패널**만 표현한다 (`lib/fusion_core/fusion_policy.ml:4`):

```ocaml
type preset =
  { name : string
  ; panel : string list           (* 모델 id 들, 전부 같은 설정으로 실행 *)
  ; panel_system_prompt : string  (* 패널 전체 공유 *)
  ; web_tools : bool              (* 패널 전체 공유 *)
  ; max_tool_calls_per_panel : int
  ; panel_timeout_s : float
  ; ... }
```

`panel_system_prompt`/`web_tools`/`max_tool_calls_per_panel`/`panel_timeout_s`가 패널 전체에 **하나씩** 적용되므로, 한 preset 안에서 "tool 없는 빠른 그룹 + web tool 켠 신중한 그룹"처럼 **이질적(heterogeneous)** 구성을 표현할 수 없다. 근거: Self-MoA 비판은 *동질·중복* 패널이 다양성 이득을 깎는다는 것이므로, 이질 패널이 그 비판을 피하는 방향이다.

둘째, RFC-0252 §6의 발동 예산(`per_hour_budget`)은 시간당 fusion **activation** 횟수 cap이다 — gate 통과 후 `Fusion_budget.try_incr_if_under`로 소비했다 (`lib/fusion/fusion_orchestrator.ml:17`, `lib/fusion_core/fusion_policy.ml:44`). 이 cap은 운영상 의미가 없다(아래 §3): fusion은 키퍼가 명시적으로 호출하는 out-of-band 심의이고, activation 빈도는 cap이 아니라 키퍼 판단·턴 구조가 이미 bound한다.

### 1.2 이 RFC가 하는 것

1. **이종 패널 그룹**: `preset.panel : string list` → `preset.panels : panel_group list`. 각 그룹이 자기 `system_prompt`/`web_tools`/`max_tool_calls`/`timeout_s`를 갖는다. 모든 그룹의 에이전트를 **하나의 `Async_agent.all`**에 union으로 던진다 (동시성/격리 경계 무변경). judge/sink는 평면 `panel_outcome list`만 보므로 **무변경**.
2. **legacy 무변경**: 기존 flat `panel=[...]` 문법을 **정확히 길이-1 그룹으로 desugar** (`lib/fusion_core/fusion_config.ml:55`). 운영자 TOML 0줄 변경, 단일 그룹이면 오늘과 **byte-identical** 동작.
3. **발동 예산 제거**: `per_hour_budget`/`Fusion_budget`/`Over_hourly_budget`/gate 소비를 전부 제거. cost-control cap을 두지 않는다 (§3).

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
  ; max_tool_calls : int   (* 0 = 무제한 *)
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
max_tool_calls_per_panel = 4
max_output_tokens_per_panel = 4096
panel_timeout_s = 180.0
```

legacy flat `panel=[...]`는 같은 `parse_group` 함수를 preset 테이블 자체에 적용해 길이-1 그룹으로 desugar한다(코드 재사용). 두 문법이 같은 키 이름을 쓰기 때문이다.

**Otoml 동작 (실소스 확인, `otoml_base.ml:178,332-337`)**: `get_array get_value`는 `TomlArray | TomlTableArray` 둘 다 element 리스트로 반환하므로 `[[...]]`와 inline array 모두 처리된다. `find_opt`/`find_or`는 **Key_error만 None/default로 삼키고 Type_error는 전파**한다 — 따라서 `panels=5` 같은 malformed scalar는 `get_array`의 Type_error가 `of_toml`의 핸들러까지 올라가 `Toml_type_error`로 fail-fast된다. (parse_preset이 `find_opt`를 쓰는 이유는 `panels`/`panel` 존재 여부(Some/None) 판별이지 Type_error 회피가 아니다.)

### 2.3 strict 거부 (Unknown→Permissive 회피)

`config_error`에 닫힌 합 variant 3종 추가: `Empty_panels`(그룹 0개), `Conflicting_panel_grammar`(`[[panels]]`+flat `panel` 동시), `Duplicate_panel_model`(평탄화 모델 리스트 중복). **중복 모델 거부**는 `Async_agent.all`이 카드명(=model)으로 결과를 키잉하므로 중복이 답변 충돌(silent 손실)을 부르기 때문이다 — cross-group뿐 아니라 한 그룹 내 중복(`["a","a"]`)도 같은 이유로 거부한다.

`panel=[]`(모델 0개)는 길이-1 빈 그룹으로 desugar되어 `Empty_panel_models`로 잡힌다. "그룹 0개"(`Empty_panels`)와 "모델 0개"(`Empty_panel_models`)는 다른 조건이므로 다른 variant로 구분한다.

---

## 3. 발동 예산 제거 (Why)

RFC-0252 §6은 비용을 예측 가능하게 통제하려고 `per_hour_budget`(activation cap)을 두었다. 본 RFC는 이를 제거한다.

- **이종 그룹은 budget 의미를 바꾸지 않는다**: activation은 여전히 activation이다(한 fusion 호출). 그룹화는 "한 activation 안에서 무엇이 도느냐"만 바꾼다. 따라서 budget 재작업은 본 변경의 요구사항이 아니라 scope creep이었다.
- **cap은 적절한 backpressure가 아니다**: per-hour activation cap은 CLAUDE.md가 경계하는 cap/cooldown류 메커니즘이다. fusion은 키퍼가 명시적으로 호출하는 out-of-band 심의이고, 호출 빈도는 키퍼 판단·턴 구조가 이미 bound한다. 인위적 시간당 cap은 운영상 의미 없는 통제다.

제거 범위: `Fusion_budget` 모듈(삭제), `Fusion_policy.t.per_hour_budget`, `deny_reason.Over_hourly_budget`, `config_error.Invalid_per_hour_budget`, orchestrator의 gate 소비, `[fusion.gate].per_hour_budget` config 키. 트레이드오프: 시간당 발동 상한이 사라진다 — fusion 비용은 이제 키퍼 호출 빈도에만 종속된다.

---

## 4. byte-identity 복구 (실행축)

`preset.web_tools`/`max_tool_calls_per_panel`/`panel_timeout_s`는 오늘 패널뿐 아니라 **심판 호출과 외곽 run_safe 타임아웃**에도 쓰인다 (`lib/fusion/fusion_orchestrator.ml:29-48`). 이 값들을 per-group으로 옮기면 심판/외곽-timeout이 대표값을 잃는다. 단일 그룹에서 오늘과 byte-identical을 보장하기 위해 순수 derive 함수를 둔다:

- `panel_outer_timeout_of groups` = 그룹 timeout 중 max (단일이면 그 그룹 timeout = `panel_timeout_s`).
- `judge_web_tools_of ~req_web_tools groups` = `req || (어느 그룹이든 web_tools)` (단일이면 `req || group.web_tools` = 오늘).
- `judge_tool_budget_of groups` = 0(무제한)이 흡수자, 그 외 그룹 max (단일이면 그 그룹 값 = 오늘).
- `max_output_tokens_per_panel`은 group-local이다. 심판 출력 예산은 `judge_max_output_tokens`와 `[[...judges]].max_output_tokens`가 소유하므로, 그룹별 패널 예산이 심판 호출에 암묵 전파되지 않는다.

검증: `test/fusion_core/test_fusion.ml`의 `config/panels_golden`(flat == 단일 그룹 `equal_preset`)과 `judge_args/single_group_identity`(derive 함수 == 오늘 매핑)가 이 불변식을 핀한다.

---

## 5. 검증 + ripple

- 32 alcotest 통과: golden 동등성, 헤테로 멀티그룹, strict 에러(empty/conflicting/duplicate), judge-arg derive, 기존 게이트·judge-parse.
- ripple: preset record는 단일 생성 지점(`fusion_config.ml`)이라 필드 변경을 컴파일러가 강제한다. `bin/fusion_run.ml`(벤치마크 하네스)은 첫 그룹 plumbing을 대표로 써 동질 arm을 비교한다.
- 전체 빌드(`dune build bin/fusion_run.exe`)로 heavy Masc lib 포함 컴파일 확인.

## 6. anti-pattern self-check

| 항목 | 판정 |
|---|---|
| 닫힌 합 유지 | `panel_group` closed record, `config_error`에 variant 추가(catch-all 신설 없음) |
| strict config | empty/conflicting/duplicate/malformed 전부 명시적 Error |
| cap 제거 | per_hour cap을 **추가가 아니라 제거** — cap/cooldown 안티패턴의 역방향 |
| N-of-M 없음 | 단일 생성 지점 + 한 커밋 atomic 변경 |
