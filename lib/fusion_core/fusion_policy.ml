(* Fusion — 결정론적 발동 게이트 (구현).
   계약/문서: fusion_policy.mli, docs/rfc/RFC-0252 §6 *)

type preset =
  { name : string
  ; panel : string list
  ; judge : string
  ; panel_system_prompt : string
  ; judge_system_prompt : string
  ; panel_timeout_s : float
  ; judge_timeout_s : float
  ; web_tools : bool
  ; max_tool_calls_per_panel : int
  }
[@@deriving show, eq]

let min_panel = 1
let max_panel = 8

(* 패널/심판 호출 구조적 타임아웃 기본값 (preset이 명시 안 할 때). 운영 노브 —
   행동 휴리스틱이 아니므로 named SSOT 상수로 둔다 (Magic Number 회피). *)
let default_timeout_s = 120.0

let preset_size_ok (p : preset) =
  let n = List.length p.panel in
  n >= min_panel && n <= max_panel

(* 패널·심판 system prompt가 둘 다 비어있지 않은가. 프롬프트는 행동을 정의하므로
   코드 default로 채우지 않고 config에서 받는다 (없으면 fail-fast). *)
let preset_prompts_present (p : preset) =
  String.length (String.trim p.panel_system_prompt) > 0
  && String.length (String.trim p.judge_system_prompt) > 0

(* 심판 모델 id가 비어있지 않은가. judge는 종합을 수행하는 필수 모델이므로 빈
   문자열(config 누락 시 default)은 런타임에 빈 runtime_id로 agent 빌드를 깨뜨린다.
   load 단계에서 fail-fast (Unknown→Permissive 회피). *)
let preset_judge_present (p : preset) = String.length (String.trim p.judge) > 0

type t =
  { enabled : bool
  ; default_preset : string
  ; max_concurrent_panels : int
  ; presets : preset list
  ; per_hour_budget : int
  }
[@@deriving show, eq]

let find_preset (policy : t) name =
  List.find_opt (fun (p : preset) -> String.equal p.name name) policy.presets

(* 시간당 예산은 여기서 검사하지 않는다 — 검사·소모를 한 연산으로 묶어야 TOCTOU가
   없으므로 [Fusion_budget.try_incr_if_under]가 게이트 통과 후 원자적으로 강제한다
   (실패 시 호출자가 [Over_hourly_budget]로 Deny). decide는 enabled/preset/depth의
   구조적 판정만 담당한다 — "이 턴이 심의할 가치가 있나"는 게이트가 score 비교나
   문자열 매칭으로 판정하지 않고, 키퍼(이미 LLM)가 판단해 masc_fusion을 호출하는
   것으로 표현한다(RFC-0252 §6). 따라서 [req.trigger]는 발동 이유 라벨일 뿐
   적격성 판정에 쓰이지 않으며, 남용은 [per_hour_budget] cap이 막는다. *)
let decide ~(policy : t)
    (req : Fusion_types.fusion_request) : Fusion_types.gate_decision =
  if not policy.enabled then Fusion_types.Deny Fusion_types.Disabled
  else
    match find_preset policy req.preset with
    | None -> Fusion_types.Deny (Fusion_types.Preset_unknown req.preset)
    | Some preset when not (preset_size_ok preset) ->
      Fusion_types.Deny (Fusion_types.Preset_unknown req.preset)
    | Some _preset ->
      (match req.depth with
       | Fusion_types.Fusion_depth.Nested ->
         Fusion_types.Deny Fusion_types.Depth_exceeded
       | Fusion_types.Fusion_depth.Top -> Fusion_types.Allow req)
