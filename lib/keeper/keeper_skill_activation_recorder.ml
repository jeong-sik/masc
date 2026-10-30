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

type bound_context = { context : t; runtime : string }

let physical_turn_ref (context : t) = context.turn_ref
let current_runtime_id (context : t) = context.runtime_id ()

let task_references ~task_id (context : t) =
  List.filter_map (fun provenance ->
    match provenance.task_ids with
    | None -> None
    | Some task_ids ->
      if List.exists (Keeper_id.Task_id.equal task_id) (Ledger.task_id_set_to_list task_ids)
      then Some provenance.reference else None) context.task_provenance
;;

type result_child =
  { alias : string
  ; skill_reference : Skill_reference.t
  ; skill_tool_use_id : string
  ; activation_frame_sha256 : string
  }
let bound_trace_id bound = bound.context.trace_id
let bound_turn_ref bound = bound.context.turn_ref

type error =
  | Turn_scope_mismatch
  | Runtime_attempt_missing
  | Invalid_task_id of string
  | Activation_rejected of Ledger.decode_error
  | Store_failed of Ledger.store_error
  | Invalid_bound_context of string

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

let bind_async context =
  match context.runtime_id () with
  | None -> Error Runtime_attempt_missing
  | Some runtime when String.trim runtime = "" -> Error Runtime_attempt_missing
  | Some runtime -> Ok {context;runtime}
;;

let bound_context_to_yojson {context;runtime} = `Assoc
  ["trace_id",`String (Keeper_id.Trace_id.to_string context.trace_id);
   "turn_ref",Ids.Turn_ref.to_yojson context.turn_ref;
   "runtime_id",`String runtime;
   "snapshot_revision",`String (Skill_catalog_snapshot.snapshot_revision_to_string context.snapshot_revision);
   "task_provenance",`List (List.map (fun provenance -> `Assoc
     ["reference",Skill_reference.to_yojson provenance.reference;
      "task_ids",(match provenance.task_ids with None -> `Null | Some ids ->
        `List (List.map (fun id -> `String (Keeper_id.Task_id.to_string id)) (Ledger.task_id_set_to_list ids)))]) context.task_provenance)]
;;

let bound_context_of_yojson json =
  let invalid detail = Error (Invalid_bound_context detail) in
  let fields names = function
    | `Assoc fields when List.sort String.compare (List.map fst fields) = List.sort String.compare names -> Ok fields
    | _ -> invalid "unexpected, duplicate or missing bound context fields" in
  let string name fields = match List.assoc name fields with
    | `String value -> Ok value | _ -> invalid ("expected string " ^ name) in
  let* fields = fields ["trace_id";"turn_ref";"runtime_id";"snapshot_revision";"task_provenance"] json in
  let* raw_trace = string "trace_id" fields in
  let* trace_id = Keeper_id.Trace_id.of_string raw_trace |> Result.map_error (fun _ -> Invalid_bound_context "invalid trace") in
  let* turn_ref = Ids.Turn_ref.of_yojson (List.assoc "turn_ref" fields)
    |> Result.map_error (fun detail -> Invalid_bound_context detail) in
  let* () = if Ids.Turn_ref.trace_id turn_ref = raw_trace then Ok () else Error Turn_scope_mismatch in
  let* runtime = string "runtime_id" fields in
  let* () = if String.trim runtime <> "" then Ok () else invalid "empty runtime identity" in
  let* raw_snapshot = string "snapshot_revision" fields in
  let* snapshot_revision = Skill_catalog_snapshot.snapshot_revision_of_string raw_snapshot
    |> Result.map_error (fun _ -> Invalid_bound_context "invalid snapshot revision") in
  let* rows = match List.assoc "task_provenance" fields with `List rows -> Ok rows
    | _ -> invalid "expected Task provenance list" in
  let* task_provenance = List.fold_left (fun result row ->
    let* previous = result in
    let* row = match row with
      | `Assoc row when List.sort String.compare (List.map fst row) = ["reference";"task_ids"] -> Ok row
      | _ -> invalid "invalid Task provenance fields" in
    let* reference = Skill_reference.of_yojson (List.assoc "reference" row)
      |> Result.map_error (fun _ -> Invalid_bound_context "invalid exact Task reference") in
    let* () = if List.exists (fun old -> Skill_reference.equal old.reference reference) previous
      then invalid "duplicate Task reference" else Ok () in
    let* task_ids = match List.assoc "task_ids" row with
      | `Null -> Ok None
      | `List ids ->
        let* ids = List.fold_left (fun result -> function
          | `String id -> let* previous = result in
            let* id = Keeper_id.Task_id.of_string id |> Result.map_error (fun _ -> Invalid_task_id id) in Ok (id::previous)
          | _ -> invalid "expected Task identity") (Ok []) ids in
        Ledger.task_id_set_of_list (List.rev ids) |> Result.map Option.some
          |> Result.map_error (fun error -> Activation_rejected error)
      | _ -> invalid "expected Task identities or null" in
    Ok ({reference;task_ids}::previous)) (Ok []) rows |> Result.map List.rev in
  Ok {context={trace_id;turn_ref;runtime_id=(fun () -> Some runtime);snapshot_revision;task_provenance};runtime}
;;

let bound_task_references bound = bound.context.task_provenance
  |> List.filter_map (fun provenance -> match provenance.task_ids with
      | Some _ -> Some provenance.reference | None -> None)
;;

let bound_child_activation bound ~tool_use_id ~agent_core_turn ~tool_name ~scope ~reference ~activated_at =
  Ledger.make_activation ~identity:reference.Skill_reference.identity ~content_revision:reference.content_revision
    ~snapshot_revision:bound.context.snapshot_revision ~turn_ref:bound.context.turn_ref ~runtime_id:bound.runtime
    ~skill_tool_use_id:tool_use_id
    ~agent_core_turn
    ~invocation:(Ledger.Nested_composition_invocation
      {origin=composition_origin bound.context reference;tool_name;scope}) ~activated_at
  |> Result.map_error (fun error -> Activation_rejected error)
;;

let bound_nested_activation bound ~invocation ~tool_name ~scope ~reference ~activated_at =
  bound_child_activation bound ~tool_use_id:(Agent_core.Tool_contract.Invocation.tool_use_id invocation)
    ~agent_core_turn:(Agent_core.Tool_contract.Invocation.turn invocation) ~tool_name ~scope ~reference ~activated_at
;;

let find_bound_result_children ~config bound ~composition_run_id ~logical_parent_tool_use_id ~source_turn ~tool_name children =
  let* ledger = Ledger.load_existing ~config ~trace_id:bound.context.trace_id
    |> Result.map_error (fun error -> Store_failed error) in
  let* ledger = match ledger with Some ledger -> Ok ledger
    | None -> Error (Invalid_bound_context "original child activation ledger is missing") in
  List.fold_left (fun result (child : result_child) ->
    let* values = result in
    let* scope = Ledger.nested_composition_scope ~parent_tool_use_id:logical_parent_tool_use_id
      ~composition_run_id:(Keeper_tool_plan.Composition_run_id.to_string composition_run_id) ~alias:child.alias
      |> Result.map_error (fun error -> Activation_rejected error) in
    let* existing = match List.find_opt (fun activation ->
        String.equal activation.Ledger.skill_tool_use_id child.skill_tool_use_id) (Ledger.activations ledger) with
      | Some existing -> Ok existing
      | None -> Error (Invalid_bound_context "admitted original child activation is missing") in
    let* expected = bound_child_activation bound ~tool_use_id:child.skill_tool_use_id ~agent_core_turn:source_turn
      ~tool_name ~scope ~reference:child.skill_reference ~activated_at:existing.activated_at in
    if String.equal child.activation_frame_sha256 (Ledger.activation_frame_sha256 existing)
      && Skill_reference.equal_identity expected.identity existing.identity
      && expected.content_revision = existing.content_revision && expected.snapshot_revision = existing.snapshot_revision
      && Ids.Turn_ref.equal expected.turn_ref existing.turn_ref && expected.runtime_id = existing.runtime_id
      && expected.agent_core_turn = existing.agent_core_turn && expected.invocation = existing.invocation
    then Ok (existing::values) else Error (Invalid_bound_context "original child differs from sealed result authority"))
    (Ok []) children |> Result.map List.rev
;;

let find_bound_nested ~config bound ~invocation ~tool_name ~scope ~reference =
  let* ledger = Ledger.load_existing ~config ~trace_id:bound.context.trace_id
    |> Result.map_error (fun error -> Store_failed error) in
  let existing = Option.bind ledger (fun ledger -> Ledger.activations ledger |> List.find_opt (fun activation ->
    activation.Ledger.skill_tool_use_id = Agent_core.Tool_contract.Invocation.tool_use_id invocation)) in
  match existing with
  | None -> Ok None
  | Some existing ->
    let* expected = bound_nested_activation bound ~invocation ~tool_name ~scope ~reference ~activated_at:existing.activated_at in
    if Skill_reference.equal_identity expected.identity existing.identity
      && expected.content_revision = existing.content_revision
      && expected.snapshot_revision = existing.snapshot_revision
      && Ids.Turn_ref.equal expected.turn_ref existing.turn_ref
      && expected.runtime_id = existing.runtime_id && expected.agent_core_turn = existing.agent_core_turn
      && expected.invocation = existing.invocation
    then Ok (Some existing) else Error (Invalid_bound_context "original child activation differs from sealed run authority")
;;

let record_bound_nested ~config bound ~invocation ~tool_name ~scope ~reference =
  let activated_at = Masc_domain.now_iso () in
  let* activation = bound_nested_activation bound ~invocation ~tool_name ~scope ~reference ~activated_at in
  Ledger.record_original_invocation ~config ~trace_id:bound.context.trace_id activation
  |> Result.map snd |> Result.map_error (fun error -> Store_failed error)
;;

let evidence ~relative_path contents =
  let bytes = String.length contents in
  let sha256 = Agent_core_sha256.(digest_string contents |> to_hex) in
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
    ~invocation:(Ledger.Composition_invocation { origin; tool_name;
      execution_id = Keeper_tool_call_log.invocation_execution_id ~invocation })
    reference
;;

let find_bound_composition ~config bound ~tool_use_id ~source_turn ~tool_name reference =
  let* ledger = Ledger.load_existing ~config ~trace_id:bound.context.trace_id
    |> Result.map_error (fun error -> Store_failed error) in
  let existing = Option.bind ledger (fun ledger -> Ledger.activations ledger |> List.find_opt
      (fun (activation : Ledger.activation) -> String.equal activation.skill_tool_use_id tool_use_id)) in
  match existing with
  | None -> Ok None
  | Some existing ->
    let* execution_id = match existing.Ledger.invocation with
      | Ledger.Composition_invocation { execution_id; _ } -> Ok execution_id
      | Ledger.Instruction_invocation _ | Ledger.Nested_composition_invocation _ ->
        Error (Invalid_bound_context "original activation is not a standalone composition") in
    let* expected = Ledger.make_activation
        ~identity:reference.Skill_reference.identity ~content_revision:reference.content_revision
        ~snapshot_revision:bound.context.snapshot_revision ~turn_ref:bound.context.turn_ref ~runtime_id:bound.runtime
        ~skill_tool_use_id:tool_use_id ~agent_core_turn:source_turn
        ~invocation:(Ledger.Composition_invocation {origin=composition_origin bound.context reference;tool_name;execution_id})
        ~activated_at:existing.activated_at |> Result.map_error (fun error -> Activation_rejected error) in
    if String.equal (Ledger.activation_frame_sha256 expected) (Ledger.activation_frame_sha256 existing)
    then Ok (Some existing) else Error (Invalid_bound_context "original composition differs from its sealed recorder")
;;

let record_bound_composition ~config bound ~invocation ~tool_name reference =
  let context = {bound.context with runtime_id=(fun () -> Some bound.runtime)} in
  record_composition ~config context ~invocation ~tool_name reference
;;

let record_nested_composition ~config context ~invocation ~tool_name ~scope reference =
  let origin = composition_origin context reference in
  record ~config context ~tool_invocation:invocation
    ~invocation:(Ledger.Nested_composition_invocation { origin; tool_name; scope }) reference
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
    ~action_identity:
      (Ledger.Call_id (Agent_core.Tool_contract.Invocation.tool_use_id invocation))
    ~tool_name
    ~runtime_id
    ~agent_core_turn:(Agent_core.Tool_contract.Invocation.turn invocation)
    ~observed_at:(Masc_domain.now_iso ())
  |> Result.map snd
  |> Result.map_error (fun error -> Store_failed error)
;;

let observe_native_action ~config context ~active_skill_tool_use_ids
      ~runtime_id ~agent_core_turn ~identity ~tool_name =
  Ledger.observe_action
    ~config ~trace_id:context.trace_id ~turn_ref:context.turn_ref
    ~active_skill_tool_use_ids ~action_identity:identity ~tool_name ~runtime_id
    ~agent_core_turn ~observed_at:(Masc_domain.now_iso ())
  |> Result.map snd
  |> Result.map_error (fun error -> Store_failed error)
;;

let error_code = function
  | Turn_scope_mismatch -> "turn_scope_mismatch"
  | Runtime_attempt_missing -> "runtime_attempt_missing"
  | Invalid_task_id _ -> "invalid_task_id"
  | Activation_rejected _ -> "activation_rejected"
  | Store_failed _ -> "store_failed"
  | Invalid_bound_context _ -> "invalid_bound_context"
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
  | Invalid_bound_context detail -> "Original Skill activation binding rejected: " ^ detail
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
    | Invalid_bound_context _
      -> None
  in
  `Assoc
    ([ "code", `String (error_code error)
     ; "detail", `String (error_to_string error)
     ]
     @ Option.to_list (Option.map (fun code -> "cause_code", `String code) cause))
;;
