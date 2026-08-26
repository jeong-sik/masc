open Result.Syntax

module Ledger = Keeper_skill_activation_ledger

type instruction_content =
  | Body of string
  | Resource of
      { relative_path : Skill_resource_path.t
      ; contents : string
      }

type t =
  { trace_id : Keeper_id.Trace_id.t
  ; turn_ref : Ids.Turn_ref.t
  ; runtime_id : string
  ; snapshot_revision : Skill_catalog_snapshot.snapshot_revision
  ; task_scope : recorded_task_scope
  }

and recorded_task_scope =
  | No_task
  | Task of
      { task_id : Keeper_id.Task_id.t
      ; references : Skill_reference.t list
      }

type error =
  | Turn_scope_mismatch
  | Invalid_task_id of string
  | Composition_reference_missing of { tool_name : string }
  | Activation_rejected of Ledger.decode_error
  | Store_failed of Ledger.store_error

let make ~trace_id ~turn_ref ~runtime_id ~snapshot_revision ~task_scope =
  let scope =
    match task_scope with
    | Keeper_task_skill_turn.No_task -> Ok No_task
    | Keeper_task_skill_turn.Task { task_id; references } ->
      Keeper_id.Task_id.of_string task_id
      |> Result.map (fun task_id -> Task { task_id; references })
      |> Result.map_error (fun _ -> Invalid_task_id task_id)
  in
  if
    not
      (String.equal
         (Keeper_id.Trace_id.to_string trace_id)
         (Ids.Turn_ref.trace_id turn_ref))
  then Error Turn_scope_mismatch
  else
    Result.map
      (fun task_scope ->
         { trace_id; turn_ref; runtime_id; snapshot_revision; task_scope })
      scope
;;

let instruction_origin context reference =
  match context.task_scope with
  | No_task -> Ledger.Session_instruction
  | Task { task_id; references } ->
    if List.exists (Skill_reference.equal reference) references
    then Ledger.Task_instruction { task_id }
    else Ledger.Session_instruction
;;

let composition_origin context ~tool_name reference =
  match context.task_scope with
  | No_task -> Ledger.Session_composition { tool_name }
  | Task { task_id; references } ->
    if List.exists (Skill_reference.equal reference) references
    then Ledger.Task_composition { task_id; tool_name }
    else Ledger.Session_composition { tool_name }
;;

let evidence ~relative_path contents =
  let bytes = String.length contents in
  let sha256 = Digestif.SHA256.(digest_string contents |> to_hex) in
  match relative_path with
  | None -> Ledger.Skill_body { bytes; sha256 }
  | Some relative_path ->
    Ledger.Skill_resource
      { relative_path = Skill_resource_path.to_string relative_path; bytes; sha256 }
;;

let record ~config context ~invocation ~served_content ~origin reference =
  let* activation =
    Ledger.make_activation
      ~identity:reference.Skill_reference.identity
      ~content_revision:reference.content_revision
      ~snapshot_revision:context.snapshot_revision
      ~turn_ref:context.turn_ref
      ~runtime_id:context.runtime_id
      ~skill_tool_use_id:
        (Agent_core.Tool_contract.Invocation.tool_use_id invocation)
      ~agent_core_turn:(Agent_core.Tool_contract.Invocation.turn invocation)
      ~served_content
      ~activated_at:(Masc_domain.now_iso ())
      ~origin
    |> Result.map_error (fun error -> Activation_rejected error)
  in
  Ledger.record ~config ~trace_id:context.trace_id activation
  |> Result.map snd
  |> Result.map_error (fun error -> Store_failed error)
;;

let record_instruction ~config context ~invocation ~content reference =
  let origin = instruction_origin context reference in
  let served_content =
    match content with
    | Body body -> evidence ~relative_path:None body
    | Resource { relative_path; contents } ->
      evidence ~relative_path:(Some relative_path) contents
  in
  record ~config context ~invocation ~served_content ~origin reference
;;

let record_composition ~config context ~invocation ~tool_name reference =
  let origin = composition_origin context ~tool_name reference in
  let served_content = evidence ~relative_path:None "" in
  record ~config context ~invocation ~served_content ~origin reference
;;

let observe_delivery ~config context ~tool_result_ids ~agent_core_turn =
  Ledger.observe_delivery
    ~config
    ~trace_id:context.trace_id
    ~turn_ref:context.turn_ref
    ~tool_result_ids
    ~agent_core_turn
    ~delivered_at:(Masc_domain.now_iso ())
  |> Result.map snd
  |> Result.map_error (fun error -> Store_failed error)
;;

let observe_action
      ~config
      context
      ~active_skill_tool_use_ids
      ~invocation
      ~tool_name
  =
  Ledger.observe_action
    ~config
    ~trace_id:context.trace_id
    ~turn_ref:context.turn_ref
    ~active_skill_tool_use_ids
    ~action_tool_use_id:(Agent_core.Tool_contract.Invocation.tool_use_id invocation)
    ~tool_name
    ~agent_core_turn:(Agent_core.Tool_contract.Invocation.turn invocation)
    ~observed_at:(Masc_domain.now_iso ())
  |> Result.map snd
  |> Result.map_error (fun error -> Store_failed error)
;;

let error_code = function
  | Turn_scope_mismatch -> "turn_scope_mismatch"
  | Invalid_task_id _ -> "invalid_task_id"
  | Composition_reference_missing _ -> "composition_reference_missing"
  | Activation_rejected _ -> "activation_rejected"
  | Store_failed _ -> "store_failed"
;;

let error_to_string = function
  | Turn_scope_mismatch ->
    "Skill activation turn reference does not belong to the Keeper trace"
  | Invalid_task_id task_id ->
    Printf.sprintf "Skill activation Task id is invalid: %s" task_id
  | Composition_reference_missing { tool_name } ->
    Printf.sprintf "Skill composition %s has no exact catalog reference" tool_name
  | Activation_rejected _ -> "Skill activation was rejected by the typed ledger"
  | Store_failed error ->
    "Skill activation ledger write failed: " ^ Ledger.store_error_to_string error
;;

let error_to_yojson error =
  let cause =
    match error with
    | Activation_rejected cause ->
      Some (Ledger.decode_error_code cause)
    | Store_failed cause -> Some (Ledger.store_error_code cause)
    | Turn_scope_mismatch
    | Invalid_task_id _
    | Composition_reference_missing _ ->
      None
  in
  `Assoc
    ([ "code", `String (error_code error)
     ; "detail", `String (error_to_string error)
     ]
     @ Option.to_list (Option.map (fun code -> "cause_code", `String code) cause))
;;
