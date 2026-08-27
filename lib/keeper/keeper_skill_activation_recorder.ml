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
  ; runtime_id : unit -> string option
  ; snapshot_revision : Skill_catalog_snapshot.snapshot_revision
  ; task_provenance : recorded_task_provenance list
  }

and recorded_task_provenance =
  { reference : Skill_reference.t
  ; task_ids : Ledger.task_id_set option
  }

type error =
  | Turn_scope_mismatch
  | Runtime_attempt_missing
  | Invalid_task_id of string
  | Activation_rejected of Ledger.decode_error
  | Store_failed of Ledger.store_error

let make ~trace_id ~turn_ref ~runtime_id ~snapshot_revision ~task_selection =
  let task_provenance =
    List.fold_left
      (fun result (selected : Keeper_task_skill_turn.selected) ->
         let* reversed = result in
         let* task_ids =
           match selected.task_ids with
           | [] -> Ok None
           | task_ids ->
             let* typed =
               List.fold_left
                 (fun result task_id ->
                    let* reversed = result in
                    Keeper_id.Task_id.of_string task_id
                    |> Result.map (fun typed -> typed :: reversed)
                    |> Result.map_error (fun _ -> Invalid_task_id task_id))
                 (Ok [])
                 task_ids
               |> Result.map List.rev
             in
             Ledger.task_id_set_of_list typed
             |> Result.map Option.some
             |> Result.map_error (fun error -> Activation_rejected error)
         in
         Ok ({ reference = selected.reference; task_ids } :: reversed))
      (Ok [])
      task_selection.Keeper_task_skill_turn.selected
    |> Result.map List.rev
  in
  if
    not
      (String.equal
         (Keeper_id.Trace_id.to_string trace_id)
         (Ids.Turn_ref.trace_id turn_ref))
  then Error Turn_scope_mismatch
  else
    Result.map
      (fun task_provenance ->
         { trace_id; turn_ref; runtime_id; snapshot_revision; task_provenance })
      task_provenance
;;

let instruction_origin context reference =
  match
    List.find_opt
      (fun provenance -> Skill_reference.equal reference provenance.reference)
      context.task_provenance
  with
  | Some { task_ids = Some task_ids; _ } -> Ledger.Task_instruction { task_ids }
  | Some { task_ids = None; _ } | None -> Ledger.Session_instruction
;;

let composition_origin context reference =
  match
    List.find_opt
      (fun provenance -> Skill_reference.equal reference provenance.reference)
      context.task_provenance
  with
  | Some { task_ids = Some task_ids; _ } -> Ledger.Task_composition { task_ids }
  | Some { task_ids = None; _ } | None -> Ledger.Session_composition
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

let record ~config context ~tool_invocation ~invocation reference =
  let* runtime_id =
    match context.runtime_id () with
    | Some runtime_id -> Ok runtime_id
    | None -> Error Runtime_attempt_missing
  in
  let* activation =
    Ledger.make_activation
      ~identity:reference.Skill_reference.identity
      ~content_revision:reference.content_revision
      ~snapshot_revision:context.snapshot_revision
      ~turn_ref:context.turn_ref
      ~runtime_id
      ~skill_tool_use_id:
        (Agent_core.Tool_contract.Invocation.tool_use_id tool_invocation)
      ~agent_core_turn:(Agent_core.Tool_contract.Invocation.turn tool_invocation)
      ~invocation
      ~activated_at:(Masc_domain.now_iso ())
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
  record
    ~config
    context
    ~tool_invocation:invocation
    ~invocation:(Ledger.Instruction_invocation { origin; served_content })
    reference
;;

let record_composition ~config context ~invocation ~tool_name reference =
  let origin = composition_origin context reference in
  record
    ~config
    context
    ~tool_invocation:invocation
    ~invocation:(Ledger.Composition_invocation { origin; tool_name })
    reference
;;

let observe_delivery ~config context ~tool_results ~boundary ~runtime_id =
  Ledger.observe_delivery
    ~config
    ~trace_id:context.trace_id
    ~turn_ref:context.turn_ref
    ~tool_results
    ~boundary
    ~runtime_id
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
  let* runtime_id =
    match context.runtime_id () with
    | Some runtime_id -> Ok runtime_id
    | None -> Error Runtime_attempt_missing
  in
  Ledger.observe_action
    ~config
    ~trace_id:context.trace_id
    ~turn_ref:context.turn_ref
    ~active_skill_tool_use_ids
    ~action_tool_use_id:(Agent_core.Tool_contract.Invocation.tool_use_id invocation)
    ~tool_name
    ~runtime_id
    ~agent_core_turn:(Agent_core.Tool_contract.Invocation.turn invocation)
    ~observed_at:(Masc_domain.now_iso ())
  |> Result.map snd
  |> Result.map_error (fun error -> Store_failed error)
;;

let error_code = function
  | Turn_scope_mismatch -> "turn_scope_mismatch"
  | Runtime_attempt_missing -> "runtime_attempt_missing"
  | Invalid_task_id _ -> "invalid_task_id"
  | Activation_rejected _ -> "activation_rejected"
  | Store_failed _ -> "store_failed"
;;

let error_to_string = function
  | Turn_scope_mismatch ->
    "Skill activation turn reference does not belong to the Keeper trace"
  | Runtime_attempt_missing ->
    "Skill activation arrived before a concrete runtime attempt was selected"
  | Invalid_task_id task_id ->
    Printf.sprintf "Skill activation Task id is invalid: %s" task_id
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
    | Runtime_attempt_missing
    | Invalid_task_id _
      -> None
  in
  `Assoc
    ([ "code", `String (error_code error)
     ; "detail", `String (error_to_string error)
     ]
     @ Option.to_list (Option.map (fun code -> "cause_code", `String code) cause))
;;
