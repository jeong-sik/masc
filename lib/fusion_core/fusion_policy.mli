(** Fusion — 결정론적 발동 게이트 (RFC-0252 §6).

    config 상한과 구조적 적격성을 대조해 [Allow]/[Deny]를 내는 순수 함수.
    "이 턴이 심의할 가치가 있나"의 판단은 키퍼(이미 LLM)가 masc_fusion을 호출하는
    것으로 표현되고, 게이트는 enabled/preset/depth의 구조적 안전만 본다.

    설계 SSOT: docs/rfc/RFC-0252-fusion-panel-judge-deliberation.md *)

(** 한 패널 그룹 — 공통 설정으로 실행되는 모델 묶음. 한 preset이 이종
    그룹 여럿을 가질 수 있다 (RFC-0252-A). 닫힌 record. *)
type panel_group =
  { models : string list  (** provider.model ids *)
  ; label : string
      (** 패널 정체성 라벨 (RFC-0278). 같은 model을 다른 system_prompt로 여러 그룹에
          둘 때 패널을 구분한다. ""(기본)이면 정체성=model 그대로 → legacy byte-identical.
          정체성 derive는 {!panelist_id}. *)
  ; system_prompt : string
      (** 그룹 패널 모델 system prompt — config에서 필수(코드 default 없음). *)
  ; web_tools : bool  (** 그룹에 web_search/web_fetch 주입 여부. *)
  ; max_tool_calls : int  (** 그룹 모델당 최대 tool 호출 수 (0=무제한). *)
  ; timeout_s : float  (** 그룹 패널 호출 구조적 타임아웃 (초). *)
  }
[@@deriving show, eq]

(** 패널 preset — 이종 패널 그룹 리스트 + 단일 심판 (RFC-0252 §9, RFC-0252-A).
    [judge]는 runtime.toml bindings와 동일한 opaque "provider.model" 문자열.
    legacy flat 문법(panel=[...])은 {!Fusion_config}가 정확히 길이-1 그룹으로
    desugar한다 — 그 경우 오늘과 byte-identical 동작. *)
type preset =
  { name : string
  ; panels : panel_group list  (** 1개 이상 그룹; 모델 총합 {!min_panel}..{!max_panel} *)
  ; judge : string
  ; judge_system_prompt : string
      (** 심판 모델 system prompt — config에서 필수(코드 default 없음). *)
  ; judge_timeout_s : float  (** 심판 호출 구조적 타임아웃 (초). *)
  }
[@@deriving show, eq]

(** 패널 크기(모델 총합) 하한/상한 (OpenRouter Fusion: 1..8 모델). *)
val min_panel : int

val max_panel : int

(** 그룹 모델당 [max_tool_calls] 상한 (0..이 값). 0=무제한. named SSOT. *)
val max_tool_calls_ceiling : int

(** 패널/심판 타임아웃 기본값 (config 미지정 시). 운영 노브 — named SSOT. *)
val default_timeout_s : float

(** 모든 그룹의 모델을 평탄화 (그룹순 × 그룹내 모델순 보존). *)
val preset_models : preset -> string list

(** 패널 모델 총합이 [min_panel]..[max_panel] 범위이고 [panels]가 비어있지 않은가.
    {!Validated_preset.of_preset}의 검증 술어 (RFC-0280: 게이트는 더 이상 재검증하지
    않고 [Validated_preset.t]로 타입 증명한다). *)
val preset_size_ok : preset -> bool

(** 패널 정체성 (RFC-0278). [label]이 비면 [model] 그대로(legacy byte-identical),
    있으면 ["label (model)"]. agent 카드명·심판 패널 태그·[panel_answer.model]에
    쓰이는 유일 식별자. provider 라우팅은 원 model로 build 시점에 따로 한다. *)
val panelist_id : label:string -> model:string -> string

(** 모든 그룹의 {!panelist_id}를 평탄화 (그룹순 × 그룹내 모델순 = fan-out 순서). *)
val preset_panelist_ids : preset -> string list

(** 두 패널이 같은 {!panelist_id}를 가지면 그 id를 반환 (없으면 [None]). 중복 정체성은
    [Async_agent.all] 결과/synthesis에서 패널 구분 불가(모호성)를 부르므로 config 로드
    시 거부한다. 한 그룹 내 동일 model·라벨 없는 두 그룹의 동일 model·동일 라벨+model을
    한 invariant로 흡수하고, 서로 다른 라벨의 동일 model은 통과한다 (RFC-0278). *)
val preset_duplicate_panelist : preset -> string option

(** 모든 그룹의 패널 system prompt + 심판 system prompt가 비어있지 않은가
    (config 로드 시 fail-fast 검증). *)
val preset_prompts_present : preset -> bool

(** 심판 모델 id가 비어있지 않은가 (config 로드 시 fail-fast 검증). *)
val preset_judge_present : preset -> bool

(** 외곽 run_safe 타임아웃 = 그룹 timeout 중 max. 단일 그룹이면 그 그룹 timeout. *)
val panel_outer_timeout_of : panel_group list -> float

(** 심판 web_tools를 그룹들에서 derive: [req_web_tools] 또는 어느 그룹이든 web_tools.
    단일 그룹이면 [req_web_tools || group.web_tools] (오늘과 byte-identical). *)
val judge_web_tools_of : req_web_tools:bool -> panel_group list -> bool

(** 심판 tool budget을 그룹들에서 derive: 0(무제한)이 흡수자, 그 외엔 그룹 max.
    단일 그룹이면 그 그룹 [max_tool_calls] (오늘과 byte-identical). *)
val judge_tool_budget_of : panel_group list -> int

(** RFC-0280: 검증을 통과한 preset (Parse, don't validate). [t = private preset]이라
    필드는 자유롭게 읽되([preset] 또는 coercion [(vp :> preset)]) 검증 없이 생성할 수
    없다 → invalid preset이 게이트·orchestrator로 흐를 수 없다. 검증 SSOT는
    [of_preset] 한 곳이며, 호출처는 재검증하지 않는다. *)
module Validated_preset : sig
  type t = private preset

  (** 검증 실패 사유 — 닫힌 합. config 계층이 자기 [config_error]로 매핑한다. *)
  type invalid =
    | Bad_size of int  (** 모델 총합(panels=[] 포함)이 [min_panel]..[max_panel] 밖 *)
    | Missing_prompt  (** 패널 또는 심판 system prompt 비어있음 *)
    | Missing_judge_model  (** 심판 model id 비어있음 *)
    | Duplicate_panelist of string  (** 두 패널이 같은 정체성({!panelist_id}) *)
    | Bad_max_tool_calls of int  (** 그룹 max_tool_calls가 0..[max_tool_calls_ceiling] 밖 *)

  (** 검증 순서: size → prompt → judge → 정체성 중복 → max_tool_calls. 통과 시
      [Ok vp], 첫 위반에서 [Error invalid]. config 로드의 검증 순서와 동일. *)
  val of_preset : preset -> (t, invalid) result

  (** 검증된 preset을 raw [preset]으로 (read-only coercion). *)
  val preset : t -> preset

  val pp : Format.formatter -> t -> unit
  val show : t -> string
  val equal : t -> t -> bool
end

(** 해석된 [fusion] config. {!Fusion_config}가 runtime.toml에서 생성한다.
    [presets]는 검증된 preset만 담는다 (RFC-0280). *)
type t =
  { enabled : bool
  ; default_preset : string
  ; max_concurrent_panels : int
  ; presets : Validated_preset.t list
  }
[@@deriving show, eq]

(** preset 이름으로 조회. 없으면 [None] (게이트가 [Preset_unknown]으로 변환).
    검증된 preset을 돌려주므로 호출처는 invariant를 재검증할 필요가 없다 (RFC-0280). *)
val find_preset : t -> string -> Validated_preset.t option

(** 결정론적 게이트 (순수, side-effect 없음).

    판정 순서 (RFC-0252 §6) — 구조/자원 안전만 본다:
    + [enabled = false] → [Deny Disabled]
    + preset 없음 → [Deny (Preset_unknown _)]
    + [depth = Nested] → [Deny Depth_exceeded]
    + 그 외 → [Allow request]

    size는 [Validated_preset.t]로 타입 증명되므로 게이트가 재검증하지 않는다
    (RFC-0280). "이 턴이 심의할 가치가 있나"는 게이트가 score/문자열로 판정하지
    않는다 — 그 판단은 키퍼(이미 LLM)가 masc_fusion을 호출하는 것으로 표현되고,
    trigger는 발동 이유 라벨일 뿐이다. *)
val decide
  :  policy:t
  -> Fusion_types.fusion_request
  -> Fusion_types.gate_decision
