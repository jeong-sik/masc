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
  ; max_output_tokens : int option
      (** 그룹 모델당 출력 토큰 예산 override. [None]이면 Runtime_agent 기본값. *)
  ; timeout_s : float  (** 그룹 패널 호출 구조적 타임아웃 (초). *)
  }
[@@deriving show, eq]

(** JOJ(judge-of-judges, RFC-0283)의 1차 심판 한 명. {!panel_group}과 동형이되 모델이
    단수다(심판은 한 모델이 한 종합을 낸다). 필드는 [j] 접두 — panel_group의 동명 필드와
    타입 추론 충돌을 피한다. 정체성 derive는 {!panelist_id}([jlabel]/[jmodel]). *)
type judge_spec =
  { jmodel : string  (** provider.model id *)
  ; jlabel : string  (** 정체성 라벨. ""면 정체성=jmodel *)
  ; jsystem_prompt : string  (** 이 1차 심판의 lens — config에서 필수(코드 default 없음). *)
  ; jweb_tools : bool  (** web_search/web_fetch 주입 여부. *)
  ; jmax_output_tokens : int option
      (** 출력 토큰 예산 override. [None]이면 Runtime_agent 기본값. *)
  ; jtimeout_s : float  (** 호출 구조적 타임아웃 (초). *)
  ; jmax_timeout_s : float option
      (** 적응형 타임아웃 확장 상한. None이면 예산 내에서 factor만큼 확장. *)
  }
[@@deriving show, eq]

(** 패널 preset — 이종 패널 그룹 리스트 + 단일 심판 (RFC-0252 §9, RFC-0252-A).
    [judge]는 runtime.toml bindings와 동일한 opaque "provider.model" 문자열이며,
    simple/refine/conditional 위상의 심판이자 JOJ의 meta-judge(reducer)다 (RFC-0283).
    legacy flat 문법(panel=[...])은 {!Fusion_config}가 정확히 길이-1 그룹으로
    desugar한다 — 그 경우 오늘과 byte-identical 동작. *)
type preset =
  { name : string
  ; panels : panel_group list  (** 1개 이상 그룹; 전체 모델 집합은 비어 있지 않음 *)
  ; judge : string
  ; judge_system_prompt : string
      (** 심판 모델 system prompt — config에서 필수(코드 default 없음). *)
  ; judge_timeout_s : float  (** 심판 호출 구조적 타임아웃 (초). *)
  ; judge_max_output_tokens : int option
      (** 단일/refine/meta 심판 출력 토큰 예산 override. [None]이면 기본값. *)
  ; meta_timeout_s : float
      (** meta/stage-meta/final-meta 호출 구조적 타임아웃 (초). *)
  ; judges : judge_spec list
      (** JOJ 1차 심판들 (RFC-0283). 기본 []; simple/refine/conditional은 무시한다.
          JOJ 위상은 런타임에 >= 2 를 요구한다. *)
  ; adaptive_timeout_factor : float
      (** 1차 심판 타임아웃 적응형 확장 계수. 1.0=확장 안 함. *)
  ; fallback_judge_model : string option
      (** 전원 타임아웃/예산 실패 시 단일 fallback 심판 모델. *)
  }
[@@deriving show, eq]

(** Default staged JOJ group size. A staged judge-of-judges run groups first
    judges into fixed-size cohorts before a final meta reduction; default 3
    expresses the common 3x3x3 shape. *)
val default_staged_judge_group_size : int

(** Smallest useful staged JOJ group size. Size 1 degenerates into a serial
    pass-through and is rejected. *)
val min_staged_judge_group_size : int

(** Optional max-output-token overrides must be positive when present. *)
val valid_max_output_tokens : int option -> bool

(** 패널/심판 타임아웃 기본값 (config 미지정 시). 운영 노브 — named SSOT. *)
val default_timeout_s : float

(** 모든 그룹의 모델을 평탄화 (그룹순 × 그룹내 모델순 보존). *)
val preset_models : preset -> string list

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

(** JOJ 1차 심판들의 정체성 ({!panelist_id}, [jlabel]/[jmodel]). 입력순 = meta 프롬프트
    attribution 순서. judges=[]면 []. (RFC-0283) *)
val preset_judge_ids : preset -> string list

(** 두 1차 심판이 같은 정체성을 가지면 그 id ({!preset_duplicate_panelist}와 동형 — meta
    프롬프트 attribution 모호성 방지). 없으면 [None]. judges=[]면 [None]. (RFC-0283) *)
val preset_duplicate_judge : preset -> string option

(** 모든 1차 심판의 system prompt(lens)가 비어있지 않은가. judges=[]면 vacuously [true]
    (simple/refine/conditional은 judges를 안 쓴다). (RFC-0283) *)
val preset_judge_prompts_present : preset -> bool

(** Staged JOJ preset grouping validation. This is runtime topology validation
    rather than preset validation because the same preset may be valid for flat
    JOJ while invalid for staged JOJ. *)
type staged_judge_group_error =
  | Staged_group_size_below_min of int
  | Staged_too_few_judges of
      { group_size : int
      ; judges : int
      }
  | Staged_ragged_judges of
      { group_size : int
      ; judges : int
      }
[@@deriving show, eq]

(** Render a staged grouping error at operator/tool boundaries. *)
val staged_judge_group_error_message : staged_judge_group_error -> string

(** Split JOJ first judges into exact staged groups. Requirements:
    [group_size >= min_staged_judge_group_size], at least two full groups, and
    no ragged final group. For example, 9 judges with group size 3 returns
    three groups of three; 8 judges with group size 3 is rejected. *)
val staged_judge_groups
  :  group_size:int
  -> judge_spec list
  -> (judge_spec list list, staged_judge_group_error) result

(** 외곽 run_safe 타임아웃 = 그룹 timeout 중 max. 패널은 입력 집합 전체를 구조적으로
    fan-out하므로 별도 concurrency 설정이나 가짜 wave 계산을 두지 않는다. *)
val panel_outer_timeout_of : panel_group list -> float

(** 심판 web_tools를 그룹들에서 derive: [req_web_tools] 또는 어느 그룹이든 web_tools.
    단일 그룹이면 [req_web_tools || group.web_tools] (오늘과 byte-identical). *)
val judge_web_tools_of : req_web_tools:bool -> panel_group list -> bool

(** [adaptive_timeout_enabled preset] — preset의 [adaptive_timeout_factor]가 확장
    임계값(1.0)을 넘는가. callers(orchestrator)가 float equality 비교 없이 typed bool로
    adaptive 재시도 분기를 판정한다. *)
val adaptive_timeout_enabled : preset -> bool

(** 적응형 타임아웃: 1차 심판/재시도 호출에 사용할 effective timeout을 계산한다.
    [factor <= adaptive_extension_threshold](= 1.0)이면 [base_s]를 반환하고,
    [already_timed_out]이고 [factor > adaptive_extension_threshold]이면 [base_s *.
    factor]를 [max_s]로만 상한해 확장한다. *)
val adjust_judge_timeout
  :  base_s:float
  -> max_s:float option
  -> factor:float
  -> already_timed_out:bool
  -> float

(** RFC-0280: 검증을 통과한 preset (Parse, don't validate). [t = private preset]이라
    필드는 자유롭게 읽되([preset] 또는 coercion [(vp :> preset)]) 검증 없이 생성할 수
    없다 → invalid preset이 게이트·orchestrator로 흐를 수 없다. 검증 SSOT는
    [of_preset] 한 곳이며, 호출처는 재검증하지 않는다. *)
module Validated_preset : sig
  type t = private preset

  (** 검증 실패 사유 — 닫힌 합. config 계층이 자기 [config_error]로 매핑한다. *)
  type invalid =
    | Empty_panel_models  (** 패널 그룹 전체에 실행할 모델이 없음 *)
    | Missing_prompt  (** 패널 또는 심판 system prompt 비어있음 *)
    | Missing_judge_model  (** 심판 model id 비어있음 *)
    | Duplicate_panelist of string  (** 두 패널이 같은 정체성({!panelist_id}) *)
    | Bad_max_output_tokens of int
        (** 그룹/심판 max_output_tokens override가 양수가 아님 *)
    | Judge_panel_prompt_missing  (** JOJ 1차 심판 system prompt 비어있음 (RFC-0283) *)
    | Duplicate_judge of string  (** 두 JOJ 1차 심판이 같은 정체성 (RFC-0283) *)
    | Bad_meta_timeout of float
        (** [meta_timeout_s]가 양수 유한수가 아님. *)
    | Bad_adaptive_factor of float
        (** [adaptive_timeout_factor]가 1.0 미만. *)

  (** 검증 순서: non-empty models → prompt → judge → 정체성 중복 → max_output_tokens →
      1차 심판 prompt/정체성/max_output_tokens → timeout 예산/계수.
      통과 시 [Ok vp], 첫 위반에서 [Error invalid].
      config 로드의 검증 순서와 동일. *)
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
  ; staged_judge_group_size : int
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

    모델 집합 non-empty는 [Validated_preset.t]로 타입 증명되므로 게이트가 재검증하지 않는다
    (RFC-0280). "이 턴이 심의할 가치가 있나"는 게이트가 score/문자열로 판정하지
    않는다 — 그 판단은 키퍼(이미 LLM)가 masc_fusion을 호출하는 것으로 표현되고,
    trigger는 발동 이유 라벨일 뿐이다. *)
val decide
  :  policy:t
  -> Fusion_types.fusion_request
  -> Fusion_types.gate_decision
