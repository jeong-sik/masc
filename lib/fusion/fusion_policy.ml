(* Fusion — 결정론적 발동 게이트 (구현).
   계약/문서: fusion_policy.mli, docs/rfc/RFC-0249 §6 *)

type preset =
  { name : string
  ; panel : string list
  ; judge : string
  ; max_tool_calls_per_panel : int
  ; web_tools : bool
  }
[@@deriving show, eq]

let min_panel = 1
let max_panel = 8

let preset_size_ok (p : preset) =
  let n = List.length p.panel in
  n >= min_panel && n <= max_panel

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

let find_preset (policy : t) name =
  List.find_opt (fun (p : preset) -> String.equal p.name name) policy.presets

(* 트리거 적격성 — config 상한이 SSOT. Low_confidence는 producer가 임베드한
   threshold가 아니라 policy.low_confidence_threshold로 재판정한다. *)
let trigger_eligible ~(policy : t) (trigger : Fusion_types.fusion_trigger) =
  match trigger with
  | Fusion_types.Explicit_tool_call
  | Fusion_types.Operator_requested
  | Fusion_types.Harness_eval
  | Fusion_types.Contested_board _ -> true
  | Fusion_types.Low_confidence { score; _ } ->
    Float.compare score policy.low_confidence_threshold < 0
  | Fusion_types.High_stakes task_kind ->
    List.mem task_kind policy.high_stakes_task_kinds

let decide ~(policy : t) ~hourly_count ~estimated_cost_usd
    (req : Fusion_types.fusion_request) : Fusion_types.gate_decision =
  if not policy.enabled then Fusion_types.Deny Fusion_types.Disabled
  else
    match find_preset policy req.preset with
    | None -> Fusion_types.Deny (Fusion_types.Preset_unknown req.preset)
    | Some preset when not (preset_size_ok preset) ->
      Fusion_types.Deny (Fusion_types.Preset_unknown req.preset)
    | Some _preset ->
      begin
        match req.depth with
        | Fusion_types.Fusion_depth.Nested ->
          Fusion_types.Deny Fusion_types.Depth_exceeded
        | Fusion_types.Fusion_depth.Top ->
          if not (trigger_eligible ~policy req.trigger) then
            Fusion_types.Deny Fusion_types.Not_warranted
          else if hourly_count >= policy.per_hour_budget then
            Fusion_types.Deny Fusion_types.Over_hourly_budget
          else if Float.compare estimated_cost_usd policy.max_cost_usd_per_call > 0
          then Fusion_types.Deny Fusion_types.Over_cost_cap
          else Fusion_types.Allow req
      end
