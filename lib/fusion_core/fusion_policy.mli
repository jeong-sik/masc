(** Fusion — 결정론적 발동 게이트 (RFC-0249 §6).

    비용 4×를 예측·테스트 가능하게 통제하는 순수 함수. config 상한과 트리거
    적격성을 대조해 [Allow]/[Deny]를 낸다. 모델 판단(키퍼의 masc_fusion 호출)도
    이 게이트의 예산 상한에 종속된다 — 즉 모델 판단은 보조, 결정론 상한이 주.

    설계 SSOT: docs/rfc/RFC-0249-fusion-panel-judge-deliberation.md *)

(** 패널 preset — 명명된 N개 모델 + 심판 (RFC-0249 §9).
    [panel]/[judge]는 runtime.toml bindings와 동일한 opaque "provider.model" 문자열. *)
type preset =
  { name : string
  ; panel : string list  (** provider.model ids, {!min_panel}..{!max_panel} *)
  ; judge : string
  ; max_tool_calls_per_panel : int
  ; web_tools : bool
  }
[@@deriving show, eq]

(** 패널 크기 하한/상한 (OpenRouter Fusion: 1..8 모델). *)
val min_panel : int

val max_panel : int

(** 패널이 [min_panel]..[max_panel] 범위인가. config 로드 시 검증되지만 게이트도 방어. *)
val preset_size_ok : preset -> bool

(** 해석된 [fusion] config. {!Fusion_config}가 runtime.toml에서 생성한다. *)
type t =
  { enabled : bool
  ; default_preset : string
  ; max_concurrent_panels : int
  ; presets : preset list
  ; low_confidence_threshold : float
  ; high_stakes_task_kinds : string list
  ; per_hour_budget : int
  ; max_cost_usd_per_call : float
  }
[@@deriving show, eq]

(** preset 이름으로 조회. 없으면 [None] (게이트가 [Preset_unknown]으로 변환). *)
val find_preset : t -> string -> preset option

(** 결정론적 게이트 (순수, side-effect 없음).

    판정 순서 (RFC-0249 §6):
    + [enabled = false] → [Deny Disabled]
    + preset 없음/크기 위반 → [Deny (Preset_unknown _)]
    + [depth = Nested] → [Deny Depth_exceeded]
    + 트리거 부적격 → [Deny Not_warranted]
    + [hourly_count >= per_hour_budget] → [Deny Over_hourly_budget]
    + [estimated_cost_usd > max_cost_usd_per_call] → [Deny Over_cost_cap]
    + 그 외 → [Allow request]

    @param hourly_count 현재 1시간 윈도우에 이미 시작된 fusion 수 (orchestrator가 집계).
    @param estimated_cost_usd preset 모델 가격 × 예상 토큰 (호출자 추정). *)
val decide
  :  policy:t
  -> hourly_count:int
  -> estimated_cost_usd:float
  -> Fusion_types.fusion_request
  -> Fusion_types.gate_decision
