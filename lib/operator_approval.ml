(** Operator_approval — OAS Approval pipeline for operator action confirmation.

    Centralizes the confirm_required logic (previously duplicated in 3 files)
    into a single OAS Approval pipeline with typed risk levels.

    @since OAS integration Phase F *)

let high_risk_actions =
  [
    "namespace_pause";
    Operator_action_constants.keeper_recover;
    Operator_action_constants.goal_completion_decision;
  ]

let allowed_actions =
  [ "broadcast"
  ; "namespace_pause"
  ; "namespace_resume"
  ; "social_sweep"
  ; "keeper_message"
  ; "keeper_probe"
  ; Operator_action_constants.keeper_recover
  ; "task_inject"
  ; Operator_action_constants.goal_completion_decision
  ]

let risk_of_action action_type : Agent_sdk.Approval.risk_level =
  if List.mem action_type high_risk_actions then High
  else if List.mem action_type allowed_actions then Low
  else Medium

type approval_mode =
  | Manual
  | Auto_low_risk

type risk_band =
  | Band_low
  | Band_medium
  | Band_high
  | Band_critical
  | Band_unclassified

type approval_mode_queue_reason =
  | Separation_of_duties_floor
  | Manual_mode
  | Not_auto_eligible

type approval_mode_decision =
  | Queue_for_operator of {
      mode : approval_mode;
      band : risk_band;
      reason : approval_mode_queue_reason;
    }
  | Auto_approved of {
      mode : approval_mode;
      band : risk_band;
    }

type approval_mode_change = {
  previous : approval_mode;
  current : approval_mode;
  actor : string;
  changed_at : string;
}

let approval_mode_to_string = function
  | Manual -> "manual"
  | Auto_low_risk -> "auto_low_risk"

let approval_mode_of_string raw =
  match String.trim raw |> String.lowercase_ascii with
  | "manual" -> Some Manual
  | "auto_low_risk" -> Some Auto_low_risk
  | "" | "auto" | "auto_low" | "auto-all" | "auto_all" -> None
  | _ -> None

let parse_approval_mode_json json =
  match json with
  | `String raw -> (
    match approval_mode_of_string raw with
    | Some mode -> Ok mode
    | None ->
      Error "mode must be one of: manual, auto_low_risk")
  | _ -> Error "mode must be a string"

let risk_band_to_string = function
  | Band_low -> "low"
  | Band_medium -> "medium"
  | Band_high -> "high"
  | Band_critical -> "critical"
  | Band_unclassified -> "unclassified"

let risk_band_of_agent_sdk = function
  | Agent_sdk.Approval.Low -> Band_low
  | Agent_sdk.Approval.Medium -> Band_medium
  | Agent_sdk.Approval.High -> Band_high
  | Agent_sdk.Approval.Critical -> Band_critical

let auto_eligible_bands = [ Band_low ]

let auto_eligible_band = function
  | Band_low -> true
  | Band_medium -> false
  | Band_high -> false
  | Band_critical -> false
  | Band_unclassified -> false

let auto_eligible_bands_json () =
  `List (List.map (fun band -> `String (risk_band_to_string band)) auto_eligible_bands)

let approval_mode_queue_reason_to_string = function
  | Separation_of_duties_floor -> "separation_of_duties_floor"
  | Manual_mode -> "manual_mode"
  | Not_auto_eligible -> "not_auto_eligible"

let decide_approval_mode ~mode ~band =
  match band with
  | Band_critical ->
    Queue_for_operator { mode; band; reason = Separation_of_duties_floor }
  | Band_high ->
    Queue_for_operator { mode; band; reason = Separation_of_duties_floor }
  | Band_unclassified ->
    Queue_for_operator { mode; band; reason = Separation_of_duties_floor }
  | Band_medium -> (
    match mode with
    | Manual -> Queue_for_operator { mode; band; reason = Manual_mode }
    | Auto_low_risk ->
      Queue_for_operator { mode; band; reason = Not_auto_eligible })
  | Band_low -> (
    match mode with
    | Manual -> Queue_for_operator { mode; band; reason = Manual_mode }
    | Auto_low_risk ->
      if auto_eligible_band band
      then Auto_approved { mode; band }
      else Queue_for_operator { mode; band; reason = Not_auto_eligible })

let operator_dir_from_base_path ~base_path =
  Filename.concat (Common.masc_dir_from_base_path ~base_path) "operator"

let approval_mode_path ~base_path =
  Filename.concat (operator_dir_from_base_path ~base_path) "approval_mode.json"

let approval_mode_json mode =
  `Assoc [ "mode", `String (approval_mode_to_string mode) ]

let approval_mode_state_json ~actor ~changed_at mode =
  `Assoc
    [ "mode", `String (approval_mode_to_string mode)
    ; "updated_by", `String actor
    ; "updated_at", `String changed_at
    ]

let approval_mode_of_state_json json =
  match json with
  | `Assoc fields -> (
    match List.assoc_opt "mode" fields with
    | Some mode_json -> parse_approval_mode_json mode_json
    | None -> Error "approval mode state is missing mode")
  | `String _ -> parse_approval_mode_json json
  | _ -> Error "approval mode state must be an object"

let read_approval_mode ~base_path =
  let path = approval_mode_path ~base_path in
  if not (Sys.file_exists path)
  then Ok Manual
  else
    try Yojson.Safe.from_file path |> approval_mode_of_state_json with
    | Sys_error msg -> Error (Printf.sprintf "approval mode read failed: %s" msg)
    | Yojson.Json_error msg ->
      Error (Printf.sprintf "approval mode JSON decode failed: %s" msg)

let read_approval_mode_or_manual ~base_path =
  match read_approval_mode ~base_path with
  | Ok mode -> mode
  | Error msg ->
    Log.Governance.warn
      "approval_mode: failed closed to manual for base_path=%s: %s"
      base_path
      msg;
    Manual

let approval_mode_status_json ~base_path =
  match read_approval_mode ~base_path with
  | Ok mode ->
    `Assoc
      [ "mode", `String (approval_mode_to_string mode)
      ; "auto_eligible_bands", auto_eligible_bands_json ()
      ; "fail_closed", `Bool false
      ]
  | Error msg ->
    `Assoc
      [ "mode", `String (approval_mode_to_string Manual)
      ; "auto_eligible_bands", auto_eligible_bands_json ()
      ; "fail_closed", `Bool true
      ; "read_error", `String msg
      ]

let set_approval_mode config ~actor mode =
  let base_path = (config : Workspace.config).base_path in
  match read_approval_mode ~base_path with
  | Error msg -> Error msg
  | Ok previous ->
    let changed_at = Masc_domain.now_iso () in
    let dir = operator_dir_from_base_path ~base_path in
    Fs_compat.mkdir_p dir;
    let path = approval_mode_path ~base_path in
    let json = approval_mode_state_json ~actor ~changed_at mode in
    (match Workspace_utils.write_json_result config path json with
     | Error msg -> Error (Printf.sprintf "approval mode write failed: %s" msg)
     | Ok () ->
       Audit_log.log_action config
         ~agent_id:actor
         ~action:(Audit_log.GovernanceDecision
                    (Audit_log.Governance_other "approval_mode_set"))
         ~details:
           (`Assoc
              [ "from_mode", `String (approval_mode_to_string previous)
              ; "to_mode", `String (approval_mode_to_string mode)
              ; "changed_at", `String changed_at
              ; "actor", `String actor
              ])
         ~outcome:Audit_log.Success
         ();
       Ok { previous; current = mode; actor; changed_at })

let approval_mode_change_json change =
  `Assoc
    [ "ok", `Bool true
    ; "previous_mode", `String (approval_mode_to_string change.previous)
    ; "mode", `String (approval_mode_to_string change.current)
    ; "actor", `String change.actor
    ; "changed_at", `String change.changed_at
    ; "auto_eligible_bands", auto_eligible_bands_json ()
    ]

let is_allowed action_type =
  List.mem action_type allowed_actions

let confirm_required action_type =
  List.mem action_type high_risk_actions

let high_risk_gate : Agent_sdk.Approval.approval_stage =
  { Agent_sdk.Approval.name = "high_risk_gate";
    evaluate = (fun ctx ->
      match ctx.risk_level with
      | Agent_sdk.Approval.Critical
      | Agent_sdk.Approval.High ->
        Decided (Agent_sdk.Hooks.Reject "requires operator confirmation")
      | Agent_sdk.Approval.Medium
      | Agent_sdk.Approval.Low ->
        Pass);
    timeout_s = None;
  }

let pipeline : Agent_sdk.Approval.t =
  Agent_sdk.Approval.create [
    Agent_sdk.Approval.risk_classifier (fun tool_name _input ->
      risk_of_action tool_name);
    high_risk_gate;
    Agent_sdk.Approval.auto_approve_known_tools
      (List.filter (fun a -> not (List.mem a high_risk_actions)) allowed_actions);
  ]

let evaluate_action ~action_type ~agent_name ~turn =
  Agent_sdk.Approval.evaluate pipeline
    ~tool_name:action_type
    ~input:(`Assoc [])
    ~agent_name
    ~turn
