module Plan = Keeper_tool_plan
module Async = Keeper_msg_async
module Dependency = Keeper_composition_dependency
module Nodes = Map.Make (String)
open Result.Syntax
open Keeper_tool_execution_journal_types
open Keeper_tool_execution_journal_json
open Keeper_tool_execution_journal_model
open Keeper_tool_execution_journal_state_decode
open Keeper_tool_execution_journal_store
open Keeper_tool_execution_journal_resolution

let canonical_entry journal request_id =
  let* entry = match Async.load_canonical_request ~base_path:journal.base_path
      ~caller:journal.immutable_source.keeper_name request_id with
    | Found entry -> Ok entry
    | Absent -> Error (Invalid_result "named journal owner request is absent")
    | Unreadable detail -> Error (Invalid_result detail)
    | Rejected rejection -> Error (Invalid_result (Yojson.Safe.to_string (Async.access_rejection_to_json rejection))) in
  let* () = entry_matches_source journal.immutable_source entry
    |> Result.map_error (fun detail -> Invalid_source detail) in
  Ok entry

let original_named_binding journal state =
  let* () = match journal.immutable_source.producer with
    | Named _ -> Ok () | Prepared -> Error (Invalid_source "prepared run has no named result binding") in
  let* owner = match List.rev state.prior_owners,state.owner with
    | (owner,_)::_,_ | [],Some owner -> Ok owner
    | [],None -> Error (Invalid_source "named run has no admitted original owner") in
  let* entry = canonical_entry journal owner.request_id in
  let* binding = match entry.request_context with
    | None -> Error (Invalid_source "named original source is missing")
    | Some fields -> Dependency.composition_of_request_context ~request_id:owner.request_id fields
        |> Result.map_error (fun detail -> Invalid_source detail) in
  let* () = Keeper_composition_named_run.validate ~base_path:journal.base_path
      ~keeper_name:journal.immutable_source.keeper_name binding
    |> Result.map_error (fun detail -> Invalid_source detail) in
  Ok binding

let named_admission journal = filesystem (fun () ->
  let* state = strict_read ~root:journal.root journal.path in
  let* () = check_source journal state in
  match state.source.producer with
  | Prepared -> Error (Invalid_source "prepared run has no named admission")
  | Named _ ->
    match state.owner,state.prior_owners with
    | None,[] -> Ok None
    | (Some _ | None),_ -> original_named_binding journal state |> Result.map Option.some)

let named_binding journal =
  let* admission = named_admission journal in
  match admission with
  | Some binding -> Ok binding
  | None -> Error (Invalid_source "named run has no admitted original owner")

let resolved_named_result journal state (binding : Dependency.composition) =
  match state.resolution with
  | None -> Ok None
  | Some resolution ->
    let* original = original_named_binding journal state in
    let* () = if canonical_equal (Dependency.composition_to_json original) (Dependency.composition_to_json binding)
      then Ok () else Error (Invalid_source "resolved result differs from the original named binding") in
    with_resolution_terminal journal resolution.owner.request_id (fun entry ->
      Ok (Some (entry,resolution)))

let validate_nested_producer journal =
  match journal.immutable_source.producer with
  | Prepared | Named {origin=Standalone;_} -> Ok ()
  | Named {origin=Nested origin;activation;skill_reference;tool_name=_} ->
    let* bound = match activation with Some bound -> Ok bound
      | None -> Error (Invalid_source "nested producer has no sealed original recorder") in
    let* parent_tool_name,logical_parent,alias = match origin.activation.invocation with
      | Keeper_skill_activation_ledger.Nested_composition_invocation {tool_name;scope;_} ->
        Ok (tool_name,scope.parent_tool_use_id,scope.alias)
      | Instruction_invocation _ | Composition_invocation _ -> Error (Invalid_source "nested producer lost its original invocation") in
    let child : Keeper_skill_activation_recorder.result_child =
      {alias;skill_reference;skill_tool_use_id=origin.activation.skill_tool_use_id;
       activation_frame_sha256=Keeper_skill_activation_ledger.activation_frame_sha256 origin.activation} in
    Keeper_skill_activation_recorder.find_bound_result_children
      ~config:(Workspace.default_config journal.base_path) bound ~composition_run_id:origin.parent_run_id
      ~logical_parent_tool_use_id:logical_parent ~source_turn:journal.immutable_source.source_turn
      ~tool_name:parent_tool_name [child]
    |> Result.map (fun _ -> ())
    |> Result.map_error (fun error -> Invalid_source (Keeper_skill_activation_recorder.error_to_string error))

type child_observation = Acceptance_recovery | Result_observation

let accepted_child_binding ~observation ~base_path (link : child_link) =
  let source = link.child_source in
  let* child = load ~base_path ~keeper_name:source.keeper_name ~composition_run_id:source.composition_run_id in
  let* () = if same_source source child.immutable_source then Ok () else Error Source_conflict in
  let* () = validate_nested_producer child in
  let* binding = named_binding child in
  let* () = if child_binding_matches link binding then Ok () else Error Source_conflict in
  let* original = canonical_entry child binding.request_id in
  let* () = match observation,original.status with
    | Acceptance_recovery,Async.Persistence_failed {attempted_status=Async.Acceptance_callback;_} ->
      Error (Invalid_result "original child acceptance callback failed")
    | Acceptance_recovery,Persistence_failed {attempted_status=State_transition _;_}
    | Result_observation,Persistence_failed _
    | (Acceptance_recovery | Result_observation),(Queued | Running | Cancelling _ | Waiting_for_dependencies _ | Done _ | Lost _ | Cancelled _) -> Ok () in
  Ok binding

let validate_child_links journal children nodes =
  Nodes.fold (fun key link prior ->
    let* () = prior in
    match link.accepted with
    | None -> Ok ()
    | Some expected ->
      let observation = match Nodes.find_opt key nodes with
        | Some (Settled (_,completed,_,_)) -> (match completed.result with
            | Tool_result.Completed _ -> Result_observation
            | Failed _ | Deferred _ -> Acceptance_recovery)
        | None | Some (Attempting _) -> Acceptance_recovery in
      let* actual = accepted_child_binding ~observation ~base_path:journal.base_path link in
      if canonical_equal (Dependency.composition_to_json expected) (Dependency.composition_to_json actual)
      then Ok () else Error Source_conflict) children (Ok ())

let nested_parent_accepted journal =
  match journal.immutable_source.producer with
  | Prepared | Named {origin=Standalone;_} -> Ok false
  | Named {origin=Nested origin;_} ->
    let* parent = load ~base_path:journal.base_path ~keeper_name:journal.immutable_source.keeper_name
        ~composition_run_id:origin.parent_run_id in
    let* state = strict_read ~root:parent.root parent.path in
    let* () = check_source parent state in
    match Nodes.find_opt (Plan.Node_id.to_string origin.parent_node_id) state.children with
    | Some link when same_source link.child_source journal.immutable_source ->
      (match link.accepted with
       | None -> Error (Invalid_result "original parent has not committed child acceptance")
       | Some expected ->
         let* actual = named_binding journal in
         if canonical_equal (Dependency.composition_to_json expected) (Dependency.composition_to_json actual)
         then Ok true else Error Source_conflict)
    | Some _ | None -> Error (Invalid_source "nested child has no original parent submission intent")

let bind_expected_owner journal ~request_id ~(expected : binding option) ~expected_terminal ~expected_nodes ~expected_children =
  let* () = match expected with
    | None -> Ok ()
    | Some prior when String.equal prior.request_id request_id -> Ok ()
    | Some prior ->
      (match Async.load_canonical_durable_terminal ~base_path:journal.base_path ~caller:journal.immutable_source.keeper_name prior.request_id with
       | Error error -> Error (Prior_owner_not_terminal {request_id = prior.request_id; reason = Async.canonical_terminal_error_to_string error})
       | Ok proof ->
         let entry = Async.durable_terminal_entry proof in
         if Option.fold ~none:false ~some:(fun expected -> not (Async.same_entry_record expected entry)) expected_terminal
         then Error Ownership_changed
         else Result.map_error (fun reason -> Prior_owner_not_terminal {request_id = prior.request_id; reason})
           (entry_matches_source journal.immutable_source entry)) in
  (* on_accepted holds the new request before its worker starts. Terminal
     publication is immutable. Only run ownership needs a CAS under this lock. *)
  let* () = canonical_queued journal request_id in
  update_existing journal (fun state ->
    if state.resolution <> None || not (same_owner state.owner expected)
        || Option.fold ~none:false ~some:(fun nodes -> nodes <> state.nodes) expected_nodes
        || Option.fold ~none:false ~some:(fun children -> not (same_children children state.children)) expected_children
    then None, Error Ownership_changed
    else match prepare_continuation_marker journal ~request_id with
      | Error error -> None, Error error
      | Ok () -> match state.owner with
      | Some binding when binding.request_id = request_id -> None, Ok {journal; binding}
      | prior ->
        let binding = {request_id; generation = (match prior with None -> 1 | Some prior -> prior.generation + 1)} in
        Some (row (event "binding" journal.source_sha ["expected_owner", option_json binding_json prior; "owner", binding_json binding])), Ok {journal; binding})

let bind_request journal ~request_id =
  let* () = validate_artifacts ~base_path:journal.base_path journal.immutable_source in
  let* () = validate_nested_producer journal in
  let* () = canonical_queued journal request_id in
  let* expected = update_existing journal (fun state -> None, Ok state.owner) in
  match journal.immutable_source.producer,expected with
  | Named _,Some owner when not (String.equal owner.request_id request_id) ->
    Error (Invalid_source "named successor requires its sealed original continuation")
  | (Prepared | Named _),(None | Some _) ->
    bind_expected_owner journal ~request_id ~expected ~expected_terminal:None ~expected_nodes:None ~expected_children:None
