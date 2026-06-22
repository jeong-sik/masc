# RFC-0278 — Fusion: 같은 model을 다른 prompt로 (same-model panels via panel labels)

- Status: Draft
- Author: Vincent (yousleepwhen) + Claude
- Created: 2026-06-22
- Parent: RFC-0252 (fusion-panel-judge-deliberation) §7 — 본 RFC는 패널 정체성(panel identity)을 개정한다. RFC-0277(이종 패널 그룹)의 후속 슬라이스.
- Scope: `lib/fusion_core/` (policy/config/types), `lib/fusion/` (panel/oas). judge/sink/dashboard 무변경.
- Boundary: OAS는 0줄 변경. judge/sink 계약 무변경. provider 라우팅 무변경.

---

## §1 동기 (Motivation)

### 1.1 현재 모델의 제약: model 문자열 = 패널 정체성

RFC-0277(이종 그룹) 이후에도 fusion 데이터 모델은 **provider model 문자열을 패널의 유일 정체성**으로 쓴다. 세 지점이 이 가정을 공유한다:

1. 심판 프롬프트는 패널을 model로 식별한다 (`lib/fusion/fusion_judge.ml:21`):

```ocaml
Printf.sprintf "<panel model=\"%s\">%s</panel>" (escape_xml a.model)
  (escape_xml a.answer)
```

2. 패널 fan-out 결과는 에이전트 카드명(=빌드 시 준 model)으로 키잉되어 outcome에 stamp된다 (`lib/fusion/fusion_panel.ml:73`):

```ocaml
List.map (fun (name, res) -> outcome_of_result name res) run_results
```

3. `panel_answer.model : string`이 그 정체성을 담고, 심판 synthesis(`supporting_models`/`positions`/`from_model`)도 같은 문자열로 패널을 지칭한다 (`lib/fusion_core/fusion_types.mli:54`).

그 결과 RFC-0277은 같은 model이 두 번 나타나면 parse-time에 거부할 수밖에 없었다(`preset_duplicate_model`): 두 패널이 동일 정체성 `"claude"`를 가지면 심판이 둘을 구분하지 못하고(`<panel model="claude">`가 두 개), `supporting_models: ["claude"]`가 어느 패널인지 모호해진다.

### 1.2 막힌 시나리오: persona ensemble

이 제약은 의미 있는 심의 패턴 하나를 막는다 — **같은 model을 다른 system_prompt로 여러 번** 돌리는 것(예: "Claude를 회의론자로 + Claude를 낙관론자로"). single-model multi-persona는 모델 다양성 없이도 입장 다양성을 만든다. RFC-0277의 이종 그룹은 *다른 model*의 이질성만 표현했고, *같은 model 다른 prompt*는 명시적 비목표였다.

### 1.3 이 RFC가 하는 것

패널 정체성을 model에서 분리한다. 각 그룹에 `label`을 두고, 패널 정체성을 `panelist_id = if label="" then model else "label (model)"`로 derive한다. 이 정체성이 카드명·심판 식별자·`panel_answer.model` 값이 된다. 같은 model이라도 라벨이 다르면 정체성이 달라 충돌하지 않는다.

비목표(Non-goals): per-group judge, keeper 저작/Free Fusion, label을 별도 dashboard 컬럼으로 노출, label 없는 자동 disambiguation(`model#2` 류 — 명시적 라벨을 요구한다).

---

## §2 설계

### 2.1 `panel_group.label` (config)

`panel_group`에 `label : string` 추가 (`lib/fusion_core/fusion_policy.ml:8`). config는 `label` 키로 읽고 기본 `""`. legacy flat 문법과 기존 이종 그룹 config에는 `label`이 없으므로 정체성 = model 그대로 — **byte-identical**.

```toml
[[fusion.presets.dialectic.panels]]
panel = ["claude"]
label = "skeptic"
panel_system_prompt = "argue against the proposal"
[[fusion.presets.dialectic.panels]]
panel = ["claude"]
label = "optimist"
panel_system_prompt = "argue for the proposal"
```

### 2.2 정체성 SSOT (`lib/fusion_core/fusion_policy.ml:53`)

```ocaml
let panelist_id ~label ~model =
  if String.equal label "" then model else Printf.sprintf "%s (%s)" label model
```

format은 이 한 함수에서만 정의한다(Magic Number/format 산포 회피). label은 model을 **압축하지 않고 포함**하므로 정보 손실이 없다 — provider 라우팅은 원 model로 build 시점에 따로 수행한다(`lib/fusion/fusion_oas.ml:101` `card_name`과 `runtime_id:model` 분리).

### 2.3 정체성 유일성 검증 (`lib/fusion_core/fusion_policy.ml:70`)

RFC-0277의 `preset_duplicate_model`(model 유일성)을 `preset_duplicate_panelist`(panelist_id 유일성)로 교체한다. 이 한 invariant가 세 경우를 흡수한다:

- (a) 한 그룹 내 동일 model (라벨 동일 → 같은 정체성),
- (b) 라벨 없는 두 그룹의 동일 model (둘 다 정체성 = model),
- (c) 동일 라벨 + 동일 model.

서로 다른 라벨의 동일 model은 정체성이 달라 통과한다(§1.2 시나리오). config_error는 `Duplicate_panel_model` → `Duplicate_panelist`로 rename(의미가 model이 아니라 정체성으로 바뀜).

### 2.4 정체성 plumbing (`lib/fusion/fusion_panel.ml:47`, `fusion_oas.ml:101`)

`build_agent`에 `?name` 추가 — 카드명(`Async_agent.all` 반환 키)을 정체성으로 두되 provider 해석은 model로 한다. `fusion_panel.run`은 그룹별로 `panelist_id ~label ~model`을 계산해 `~name:panelist`로 빌드하고, outcome의 `model`/`failed_model`에 정체성을 담는다. 심판/sink는 `.model`/synthesis 문자열을 그대로 소비하므로 **무변경**.

---

## §3 byte-identity (실행축)

label이 없는 모든 config(legacy flat + RFC-0277 이종 그룹, unique model)는:

- `panelist_id ~label:"" ~model = model` → 카드명·정체성·심판 태그·`panel_answer.model`이 모두 오늘과 동일.
- `preset_duplicate_panelist`가 label 없는 동일 model을 RFC-0277의 `preset_duplicate_model`과 정확히 같게 거부.

검증: `test/fusion_core/test_fusion.ml`의 `config/panels_golden`(flat == 단일 그룹 + `preset_panelist_ids = ["a";"b";"c"]` = models)과 `config/panelist_id`(SSOT 단위)가 이 불변식을 핀한다.

---

## §4 검증 + ripple

- 36 alcotest 통과: 정체성 SSOT 단위, same-model-different-prompt 통과(distinct ids), 라벨 없는 동일 model 거부(`Duplicate_panelist`), 비단사 정체성 충돌의 fail-closed 거부(`panelist_id_collision_fail_closed`), legacy 정체성=model 골든, 기존 게이트·judge-parse.
- ripple: `panel_group` record는 단일 생성 지점(`fusion_config.ml`)이라 필드 추가를 컴파일러가 강제한다. `bin/fusion_run.ml`은 `{ g0 with models }` record-update라 label을 자동 승계(무변경) — self-consistency baseline은 label="" → 정체성=model로 오늘과 동일.
- 전체 빌드(`dune build bin/fusion_run.exe`)로 heavy Masc lib 포함 컴파일 확인.

## §5 anti-pattern self-check

| 항목 | 판정 |
|---|---|
| 닫힌 합 유지 | `config_error`에 변형 rename(신설 catch-all 없음), `panel_group` closed record |
| 두 개념 압축 회피 | 정체성과 routable model을 분리 — 카드명=정체성, provider 해석=model. label은 model을 포함(손실 없음) |
| Unknown→Permissive 회피 | 정체성 충돌은 silent 허용 대신 `Duplicate_panelist`로 명시 거부. 라벨 없는 동일 model을 자동 disambiguate하지 않는다 |
| N-of-M 없음 | 정체성 유일성을 **한 invariant**(`preset_duplicate_panelist`)로 흡수, 단일 커밋 atomic |
| cap/cooldown/telemetry-as-fix 없음 | 해당 없음 |
