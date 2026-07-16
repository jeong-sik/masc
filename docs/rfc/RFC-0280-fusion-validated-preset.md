# RFC-0280 — Fusion: validated preset type (Parse, don't validate)

- Status: Draft
- Author: Vincent (yousleepwhen) + Claude
- Created: 2026-06-22
- Parent: RFC-0252 (fusion-panel-judge-deliberation). RFC-0277(이종 그룹)·RFC-0278(패널 정체성) 후속 슬라이스 3.
- Scope: `lib/fusion_core/` (policy/config), `lib/fusion/fusion_orchestrator.ml`, `bin/fusion_run.ml`.
- Boundary: 동작·config_error 출력 byte-identical. 타입 경계만 강화 (검증 위치 이동, 새 거부 규칙 없음).

---

## §1 동기 (Motivation)

fusion preset의 invariant(모델 집합 non-empty, 패널 정체성 유일, 프롬프트/심판 모델 비어있지 않음)는 **런타임 predicate를 호출처가 직접 부르는** 방식으로 강제된다. 이 "validate at use"는 두 결함을 만든다.

### 1.1 게이트가 검증을 재실행한다 (validate-at-use)

초기 구현은 config 로드와 발동 게이트가 같은 모델 집합 검증을 다시 실행했다:

```ocaml
| Some preset when panel_models_are_empty preset ->
  Fusion_types.Deny (Fusion_types.Preset_unknown req.preset)
```

`policy.presets : preset list`가 유효성 증명을 담지 못해 게이트가 불신·재검증한다. 이 재검사는 실제로는 항상 통과한다(of_toml이 이미 거부했으므로) — dead defensive code이며, 게이트가 *깜빡하면* 잘못된 preset이 통과할 수도 있다.

### 1.2 raw 생성이 검증을 우회한다

`bin/fusion_run.ml:153`은 `let g0 = List.hd preset.panels`에 이어 `{ g0 with models }` record-update로 raw 그룹을 만든다. `fusion_orchestrator.ml:23`은 `preset.panels`를 `Fusion_panel.run`에 넘기며 "run은 순수하게 그룹 설정만 신뢰한다"고 주석한다. 어떤 타입도 그 신뢰를 강제하지 않는다. 슬라이스 C(keeper 저작 그래프)에서 keeper/operator가 그래프를 구성하면 이 구멍이 invalid preset을 런타임까지 흘린다.

### 1.3 이 RFC가 하는 것

Alexis King의 "Parse, don't validate": 검증된 preset을 **존재 자체가 invariant 증명인 타입**(`Validated_preset.t = private preset`)으로 만든다. 검증을 smart constructor `of_preset` 한 곳에 모으고, 게이트·orchestrator는 검증된 타입만 받는다 → §1.1 재검증 제거, §1.2 우회 차단(검증 없이 `Validated_preset.t` 생성 불가).

비목표: 새 거부 규칙 추가, per-group `NonEmpty` 모델 타입(전체 집합 non-empty 검증으로 충분), `run`의 시그니처 변경(harness arm이 임의 그룹을 구성하므로 raw groups primitive 유지).

---

## §2 설계

### 2.1 `Validated_preset` (private type + smart constructor)

`lib/fusion_core/fusion_policy.ml`에 모듈 추가. `.mli`는 `type t = private preset`을 노출 — 외부는 필드를 읽되(`(vp :> preset)` 또는 `preset vp`) 검증 없이 생성 불가.

```ocaml
module Validated_preset : sig
  type t = private preset
  type invalid =
    | Empty_panel_models
    | Missing_prompt
    | Missing_judge_model
    | Duplicate_panelist of string
    | Bad_max_tool_calls of int
  val of_preset : preset -> (t, invalid) result
  val preset : t -> preset
  val pp : Format.formatter -> t -> unit
  val show : t -> string
  val equal : t -> t -> bool
end
```

`of_preset`는 non-empty models → prompt → judge → dup panelist 순서의 구조 검증을 수행한다. `pp`/`equal`/`show`는 underlying `preset`에 위임(private 타입 deriving 의존 회피 — `Fusion_policy.t`가 derive할 때 `Validated_preset.pp`/`equal`을 참조).

### 2.2 정책이 검증된 preset만 담는다

`type t = { ...; presets : Validated_preset.t list }`. `find_preset : t -> string -> Validated_preset.t option`. 게이트 `decide`는 모델 집합 재검사를 **제거** — 타입이 non-empty를 증명한다. depth/enabled 구조 판정만 남는다.

### 2.3 config가 smart constructor를 통과시킨다

`finish_preset`(`fusion_config.ml`)은 raw `preset`을 만든 뒤 `Validated_preset.of_preset`을 호출하고 `invalid → config_error`를 매핑한다(`Empty_panel_models→Empty_panel_models`, `Missing_prompt→Missing_prompt`, `Missing_judge_model→Missing_judge_model`, `Duplicate_panelist→Duplicate_panelist`).

### 2.4 소비처는 검증된 타입을 coerce해 읽는다

`fusion_orchestrator.ml`/`bin/fusion_run.ml`은 `Validated_preset.preset vp`로 raw preset을 얻어 기존대로 `.panels`/`preset_models`를 읽는다. `run`은 raw groups primitive로 유지.

---

## §3 byte-identity / 동작 보존

- config는 빈 모델 집합을 typed `Empty_panel_models`로 명시한다.
- 게이트는 validated preset을 받아 non-empty 검증을 재실행하지 않는다.
- 패널/심판 실행 동일: orchestrator·harness가 같은 `.panels`를 읽는다(coerce는 read-only).

---

## §4 검증 + ripple

- `test/fusion_core/test_fusion.ml`: 기존 config 테스트(각 config_error 케이스)가 그대로 통과 = 검증 동작 보존. `Validated_preset.of_preset` 단위 테스트(각 invalid 변형 + Ok 케이스) 추가.
- `panel_group`/`preset` record는 단일 생성 지점이라 타입 변경을 컴파일러가 강제(소비처 누락 시 컴파일 실패).
- 전체 빌드(CI)로 deriving·coercion 확인.

## §5 anti-pattern self-check

| 항목 | 판정 |
|---|---|
| Parse-don't-validate | 검증을 smart constructor로, 검증된 타입을 `private`로 — illegal states unrepresentable |
| 닫힌 합 유지 | `invalid`는 닫힌 sum, catch-all 없음. config_error 매핑 exhaustive |
| 두 개념 압축 회피 | raw `preset`(파싱 중간)과 `Validated_preset.t`(검증됨)를 타입으로 분리 |
| 새 워크어라운드 없음 | telemetry/string-classifier/cap/dedup 없음. dead 재검증 *제거*(추가 아님) |
| N-of-M 없음 | 검증 SSOT를 `of_preset` 한 곳으로 — 산포 검증 통합, 단일 atomic |
