(** Fusion — 결정론적 발동 게이트 (RFC-0252 §6).

    비용 4×를 예측·테스트 가능하게 통제하는 순수 함수. config 상한과 트리거
    적격성을 대조해 [Allow]/[Deny]를 낸다. 모델 판단(키퍼의 masc_fusion 호출)도
    이 게이트의 예산 상한에 종속된다 — 즉 모델 판단은 보조, 결정론 상한이 주.

    설계 SSOT: docs/rfc/RFC-0252-fusion-panel-judge-deliberation.md *)

(** 패널 preset — 명명된 N개 모델 + 심판 (RFC-0252 §9).
    [panel]/[judge]는 runtime.toml bindings와 동일한 opaque "provider.model" 문자열. *)
type preset =
  { name : string
  ; panel : string list  (** provider.model ids, {!min_panel}..{!max_panel} *)
  ; judge : string
  ; panel_system_prompt : string
      (** 패널 모델 system prompt — config에서 필수(코드 default 없음). *)
  ; judge_system_prompt : string
      (** 심판 모델 system prompt — config에서 필수(코드 default 없음). *)
  ; panel_timeout_s : float  (** 패널 fan-out 구조적 타임아웃 (초). *)
  ; judge_timeout_s : float  (** 심판 호출 구조적 타임아웃 (초). *)
  ; web_tools : bool  (** 패널/심판에 web_search/web_fetch 주입 여부. *)
  ; max_tool_calls_per_panel : int  (** 패널 모델당 최대 tool 호출 수 (0=무제한). *)
  }
[@@deriving show, eq]

(** 패널 크기 하한/상한 (OpenRouter Fusion: 1..8 모델). *)
val min_panel : int

val max_panel : int

(** 패널/심판 타임아웃 기본값 (config 미지정 시). 운영 노브 — named SSOT. *)
val default_timeout_s : float

(** 패널이 [min_panel]..[max_panel] 범위인가. config 로드 시 검증되지만 게이트도 방어. *)
val preset_size_ok : preset -> bool

(** 패널·심판 system prompt가 둘 다 비어있지 않은가 (config 로드 시 fail-fast 검증). *)
val preset_prompts_present : preset -> bool

(** 심판 모델 id가 비어있지 않은가 (config 로드 시 fail-fast 검증). *)
val preset_judge_present : preset -> bool

(** 해석된 [fusion] config. {!Fusion_config}가 runtime.toml에서 생성한다. *)
type t =
  { enabled : bool
  ; default_preset : string
  ; max_concurrent_panels : int
  ; presets : preset list
  ; per_hour_budget : int
  }
[@@deriving show, eq]

(** preset 이름으로 조회. 없으면 [None] (게이트가 [Preset_unknown]으로 변환). *)
val find_preset : t -> string -> preset option

(** 결정론적 게이트 (순수, side-effect 없음).

    판정 순서 (RFC-0252 §6) — 구조/자원 안전만 본다:
    + [enabled = false] → [Deny Disabled]
    + preset 없음/크기 위반 → [Deny (Preset_unknown _)]
    + [depth = Nested] → [Deny Depth_exceeded]
    + 그 외 → [Allow request]

    "이 턴이 심의할 가치가 있나"는 게이트가 score/문자열로 판정하지 않는다.
    그 판단은 키퍼(이미 LLM)가 masc_fusion을 호출하는 것으로 표현되고, trigger는
    발동 이유 라벨일 뿐이다. 남용은 [per_hour_budget] cap이 막는다.

    시간당 예산([per_hour_budget])은 decide에서 검사하지 않는다 — 검사·소모를
    원자적으로 묶어야 TOCTOU가 없으므로 [Fusion_budget.try_incr_if_under]가
    게이트 통과 후 강제하고, 실패 시 호출자가 [Over_hourly_budget]로 Deny한다. *)
val decide
  :  policy:t
  -> Fusion_types.fusion_request
  -> Fusion_types.gate_decision
