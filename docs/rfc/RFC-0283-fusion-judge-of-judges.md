# RFC-0283 — Fusion: judge-of-judges 위상 (flat/staged reducer)

- Status: Draft
- Author: Vincent (yousleepwhen) + Claude
- Created: 2026-06-23
- Parent: RFC-0252 (fusion-panel-judge-deliberation) — §9(preset)를 개정. 위상 선택은 "Fusion as a Tool" 슬라이스 계열(refine/conditional)의 연장.
- Scope: `lib/fusion_core/` (preset/config/types/policy), `lib/fusion/` (judge/orchestrator), `lib/keeper/keeper_tool_descriptor.ml` (스키마), `config/runtime.toml` (`[fusion.presets.*]`)
- Boundary: OAS 0줄 변경. sink 계약 무변경. 기존 단일 `judge` 필드 **유지**(파괴 변경 없음). `simple`/`refine`/`conditional` 위상 동작 불변.

---

## 1. 동기 (Motivation)

`masc_fusion` 도구는 위상(topology)을 이름으로 고를 수 있다(슬라이스 1·2):

- `simple`: panel → judge → sink
- `refine`: panel → judge → judge'(1차 종합 재검토) → sink
- `conditional`: 1차 판정이 `Insufficient`일 때만 refine

세 위상 모두 **reduce 단계에 심판이 하나**다. 패널(fan-out)은 RFC-0277/0278로 데이터 주도(이종 그룹·persona)가 됐지만 reduce는 단일 순차 심판으로 남아 있다.

`judge-of-judges`(JOJ)는 reduce 쪽의 **병렬 fan-out + 합성**이다: 같은 패널 답을 **서로 다른 N개 1차 심판**(각자 다른 모델 또는 다른 lens/system_prompt)이 독립적으로 종합하고, **meta 심판**이 그 N개 종합을 하나로 reconcile한다.

```
panel → [judge_1, judge_2, ..., judge_N] → meta-judge → sink
```

### 1.1 왜 N개 심판이 *서로 달라야* 하는가

같은 모델·같은 prompt로 심판을 N번 돌리면 (결정론이면) 동일 출력 → meta 무의미. 신뢰할 수 있는 다양성은 **모델 차이** 또는 **lens 차이**(system_prompt)에서 온다. `build_agent`는 temperature/sampling을 노출하지 않으므로 "같은 심판 N 샘플"은 API상 불가하고 신뢰 불가다. 따라서 JOJ는 **config에 1차 심판 목록**을 요구한다 — RFC-0277이 패널을 `panel: string list` → `panels: panel_group list`로 만든 것과 대칭.

근거: persona ensemble(RFC-0278)이 패널에서 다양성을 증명했듯, 심판에도 같은 원리를 적용한다("회의론자 심판 + 낙관론자 심판 + 문자주의 심판 → meta가 reconcile").

## 2. 설계 (Design)

### 2.1 preset 스키마 — 비파괴 추가

기존 단일 `judge`/`judge_system_prompt`/`judge_timeout_s`를 **그대로 둔다**. 이것이 `simple`/`refine`/`conditional`의 심판이자 **JOJ의 meta-judge(reducer)**다. 1차 심판 목록 `judges`를 **선택적으로 추가**한다(기본 `[]`).

```ocaml
type judge_spec =
  { model : string             (* provider.model id *)
  ; label : string             (* 정체성 라벨 (panel_group.label과 동형). ""면 정체성=model *)
  ; system_prompt : string     (* 이 1차 심판의 lens. 필수(코드 default 없음) *)
  ; web_tools : bool
  ; max_tool_calls : int
  ; timeout_s : float
  }

type preset =
  { name : string
  ; panels : panel_group list
  ; judge : string                  (* (유지) simple/refine/conditional 심판 = JOJ meta-judge *)
  ; judge_system_prompt : string    (* (유지) *)
  ; judge_timeout_s : float         (* (유지) *)
  ; judges : judge_spec list        (* (신규) JOJ 1차 심판들. default []. *)
  }
```

- `simple`/`refine`/`conditional`: `judges`를 **무시**하고 기존 단일 `judge` 사용 → 동작 불변(byte-identical).
- `judge_of_judges`: `judges`의 N개로 1차 fan-out, 기존 `judge`를 meta로.
- `staged_judge_of_judges`: 같은 `judges` 목록을 `[fusion].staged_judge_group_size`
  단위의 exact group으로 나누고, group별 stage meta 결과를 final meta가 다시 reconcile한다.

판정 정체성은 `panelist_id`와 동형인 `judge_id ~label ~model`로 derive한다(meta 프롬프트에서 어느 1차 심판의 종합인지 attribute).

### 2.2 검증 (Validated_preset 확장 — Parse, don't validate)

`Validated_preset.of_preset`에 `judges` 검증을 추가한다(닫힌 합 `invalid`에 변형 추가):

- `Judge_panel_prompt_missing`: 어느 `judges` 항목의 `system_prompt`가 빔.
- `Duplicate_judge of string`: 두 1차 심판이 같은 `judge_id`(정체성 모호 → meta 프롬프트 attribution 충돌). `preset_duplicate_panelist`와 동형.
- `judges`의 `max_tool_calls`도 기존 `max_tool_calls_ceiling` 범위 검사(panel과 동일 술어 재사용).

**`judges`가 비어 있어도 preset은 유효하다**(simple/refine/conditional이 정상이므로). JOJ 적용 가능 여부는 *위상 선택 시점*(런타임)에 검사한다(§2.3).

### 2.3 orchestrator — JOJ 분기

위상 dispatch에 `Judge_of_judges` 추가(닫힌 합 exhaustive, catch-all 없음):

```
| Judge_of_judges ->
  (match preset.judges with
   | [] | [_] -> (* JOJ는 ≥2 1차 심판 필요 — config 미구성 *)
     Error "judge_of_judges requires >= 2 judges configured in the preset"
   | judges ->
     (* 1차 심판 N개 병렬 fan-out (panel과 동일 Eio.Fiber.List.map ~max_fibers) *)
     let firsts = parallel_run judges ~panel ~question in   (* (judge_synthesis * usage) result list *)
     (match successes firsts with
      | [] -> (* 전원 실패 → meta할 게 없음 *) first_error firsts
      | oks -> (* meta-judge가 N개 종합을 reconcile *)
        run_meta ~priors:(syntheses oks) ~panel ~question
          (* meta usage + 모든 1차 usage 합산 *)))
```

- **재귀 없음**: `judge_of_judges`는 1차 N개 + meta 1개의 고정 2-level이다.
  `staged_judge_of_judges`는 같은 fusion run 안의 고정 reducer tree(stage meta + final meta)이며
  nested `masc_fusion`을 호출하지 않는다. Fusion_depth 게이트의 Nested 재진입 차단은 그대로 유지한다.
- **격리**: 1차 심판 하나가 실패해도 나머지로 meta 진행(panel `Async_agent.all` 격리와 동형). 전원 실패면 첫 에러 전파.
- **usage**: 성공한 1차 usage 전부 + meta usage를 `add_usage` fold로 합산해 sink에 전달.
- **graceful degrade**: meta 실패 시 1차 종합 중 하나(예: 첫 성공)로 fallback + warn(refine 위상과 동일 원리). [열린 질문 §5.1]

### 2.3.1 staged JOJ 분기

`staged_judge_of_judges`는 graph DSL이나 recursive fusion이 아니라 named topology arm이다.

- `[fusion].staged_judge_group_size` 기본값은 3, 허용 최소값은 2.
- judge 수는 group size로 나누어떨어져야 하며, 최소 두 개의 full group을 만들어야 한다.
  예: 9 judges + group size 3 → `3 + 3 + 3` stage meta → final meta. 8 judges + group
  size 3은 ragged라 실행 전 에러로 fail-closed.
- 1차 judge wave와 stage meta wave는 입력된 judge 전체를 실행한다. Final meta는 1회 호출이다.
- 각 stage meta 실패는 해당 stage의 첫 성공 1차 종합으로 degrade하고, final meta 실패는 첫 성공
  stage 종합으로 degrade한다. 모든 stage가 실패하면 canonical judge는 Error다.

### 2.4 meta-judge 진입점

`Fusion_judge`에 추가:

```ocaml
val compose_meta_prompt
  : question:string -> panel:panel_outcome list -> priors:(string * judge_synthesis) list -> string
(* (judge_id, synthesis) 쌍 목록. 각 prior를 render_prior_synthesis로 lossless 렌더하고
   <judge id="..."> 블록으로 감싼다. meta에게 N개 종합을 reconcile해 하나의 개선 종합을
   같은 JSON 스키마로 내라 지시. escape + expected_json_doc 재사용. *)

val run_meta : (* run/run_refine과 동형, ~priors 추가 *) ...
```

`run_composed`(슬라이스 1에서 추출한 공유 본체)에 위임 → 빌드/실행/usage/파싱 경로 동일.

## 3. 경계 (Boundaries)

| 건드림 | 안 건드림 |
|--------|-----------|
| preset에 `judges` 추가, Validated_preset 검증 | 기존 `judge`/`judge_system_prompt`/`judge_timeout_s` |
| `[fusion].staged_judge_group_size` config + staged grouping validation | panel preset grammar |
| fusion_topology에 `Judge_of_judges`, `Staged_judge_of_judges` | simple/refine/conditional 동작 |
| Fusion_judge: compose_meta_prompt/run_meta | sink 계약, OAS |
| orchestrator JOJ 분기 + 1차 병렬 fan-out | panel fan-out |

## 4. 테스트

순수 경계(fusion_core 빠른 alcotest):
- `judge_of_judges` round-trip + wire-string 목록.
- `staged_judge_of_judges` round-trip + wire-string 목록.
- staged grouping: 9 judges/group 3 → 3x3, too few/ragged/group_size<2 → fail-closed.
- `judge_spec` 검증: prompt 누락 → `Judge_panel_prompt_missing`, 정체성 중복 → `Duplicate_judge`, byte-identity(judges=[]면 기존 preset과 동치).
- `compose_meta_prompt`: N개 prior가 전부 lossless 렌더되고 judge_id로 attribute됨.

통합(하네스 영역, 단위 불가): 실제 N+1 심판 LLM 실행. RFC-0252 §11.

## 5. 열린 질문 (Open Questions)

### 5.1 meta 실패 시 graceful degrade 대상
refine 위상은 1차 종합으로 fallback한다. JOJ는 N개 1차 종합 중 무엇으로? 후보: (a) 첫 성공, (b) consensus가 가장 많은 것, (c) 실패로 처리(Sink는 judge=Error). v1 권장: **(a) 첫 성공 + warn**(단순·예측 가능, refine과 대칭). (b)는 "best" 선택 휴리스틱을 새로 도입 → 보류.

### 5.2 JOJ + preset judges 미구성
§2.3대로 런타임 에러. 대안: simple로 fallback(Unknown→permissive 성격이라 거부). 에러가 fail-closed로 옳다.

## 6. 대안 (Alternatives)

- **같은 judge N 샘플(temperature)**: build_agent가 sampling 미노출 + 신뢰 불가 → 거부(§1.1).
- **별도 `meta_judge` 필드**: 더 명시적이나 legacy `judge` desugar 필요(더 큰 변경). 기존 `judge`를 meta로 재사용하는 편이 비파괴 — 채택.
- **그래프 datatype/kernel로 JOJ 표현**: 적대 bake-off(2026-06-23)가 거부(tool-schema가 그래프 어휘 미표현, 1-인스턴스 추출=ChainEngine 재현). named 위상으로 충분; kernel은 refine/conditional/JOJ 수렴 후 추출.
