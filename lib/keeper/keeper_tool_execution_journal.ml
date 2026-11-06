(* One append authority for an immutable prepared source, its async owners and
   node occurrences. Kept below the existing durable async consumer tree so the
   full typed results retain their artifact roots independently of transcripts. *)

include Keeper_tool_execution_journal_types
include Keeper_tool_execution_journal_json
include Keeper_tool_execution_journal_model
include Keeper_tool_execution_journal_state_decode
include Keeper_tool_execution_journal_store
include Keeper_tool_execution_journal_resolution
include Keeper_tool_execution_journal_binding
include Keeper_tool_execution_journal_continuation
include Keeper_tool_execution_journal_completion
include Keeper_tool_execution_journal_discovery
module Plan = Keeper_tool_plan
module Async = Keeper_msg_async
module Dependency = Keeper_composition_dependency
module Nodes = Map.Make (String)

open Result.Syntax

let check_worker (worker : worker) (state : state) =
  if state.resolution = None && same_owner state.owner (Some worker.binding) then Ok ()
  else Error Ownership_changed

let worker_child_admission (worker : worker) ~node_ids =
  update_existing worker.journal (fun state -> None,
    let* () = check_worker worker state in
    Ok (nodes_child_admission state.nodes ~node_ids))

let validate_source_plan (journal : t) ~plan =
  let* recorded = frozen_plan ~base_path:journal.base_path journal.immutable_source in
  let* actual = Keeper_tool_plan_request.to_yojson plan
    |> Result.map_error (fun _ -> Plan_identity_conflict) in
  if not (canonical_equal recorded actual) then Error Plan_identity_conflict
  else Ok ()

let validate_plan (worker : worker) ~plan =
  let* () = validate_source_plan worker.journal ~plan in
  update_existing worker.journal (fun state -> None, check_worker worker state)

let validate_refusal_completion (worker : worker) ~plan =
  let journal = worker.journal in
  let* () = validate_artifacts ~base_path:journal.base_path journal.immutable_source in
  let* () = validate_nested_producer journal in
  let* () = validate_plan worker ~plan in
  let* children,nodes = update_existing journal (fun state -> None,
    let* () = check_worker worker state in Ok (state.children,state.nodes)) in
  let* () = validate_child_links journal children nodes in
  update_existing journal (fun state -> None, check_worker worker state)

let checked_node (worker : worker) state ~node_id ~tool_name ~input =
  let* () = check_worker worker state in
  let* () = Result.map_error (fun detail -> Invalid_result detail) (decode (fun () -> valid_json input; require (exact_name tool_name) "invalid tool name")) in
  let record = Nodes.find_opt (Plan.Node_id.to_string node_id) state.nodes in
  match record with
  | Some record when not (same_node_identity (occurrence_of_record record) ~node_id ~tool_name ~input) -> Error (Node_identity_conflict node_id)
  | _ -> Ok record

let check_attempt (attempt : attempt) state =
  let* () = check_worker attempt.worker state in
  match Nodes.find_opt (Plan.Node_id.to_string attempt.occurrence.node_id) state.nodes with
  | Some (Attempting current) when same_occurrence current attempt.occurrence -> Ok ()
  | None | Some (Attempting _ | Settled _) -> Error (Attempt_conflict attempt.occurrence.node_id)

let submission_operand (attempt : attempt) plan =
  match Plan.contract plan attempt.occurrence.node_id with
  | Some {target=Plan.Child_submission child;_} when not attempt.occurrence.readonly
      && String.equal attempt.occurrence.tool_name child.submission.tool_name -> Ok child
  | Some {target=(Plan.Child_arguments _ | Plan.Child_submission _ | Child_result _ | Descriptor_target _);_} | None ->
    Error (Node_identity_conflict attempt.occurrence.node_id)

let original_nested_context (journal : t) =
  let* run = read_manifest ~base_path:journal.base_path journal.immutable_source.run_reference in
  let* json = match run with
    | `Assoc fields -> (match List.assoc_opt "nested_activation" fields with
        | Some value -> Ok value | None -> Error (Invalid_source "original nested recorder is absent"))
    | _ -> Error (Invalid_source "original nested run is not an object") in
  Keeper_skill_activation_recorder.bound_context_of_yojson json
  |> Result.map_error (fun error -> Invalid_source (Keeper_skill_activation_recorder.error_to_string error))

let child_origin (attempt : attempt) ~plan ~activation =
  let journal = attempt.worker.journal in
  let* () = validate_plan attempt.worker ~plan in
  let* child = submission_operand attempt plan in
  let* () = update_existing journal (fun state -> None,check_attempt attempt state) in
  let* bound_plan = Plan.bind_child_plan ~input:attempt.occurrence.input child.child
    |> Result.map_error (fun error -> Invalid_source (Plan.child_binding_error_to_string error)) in
  let* bound = original_nested_context journal in
  let source = journal.immutable_source in
  let alias = Plan.child_alias child.child in
  let expected_id = Plan.Composition_run_id.child_tool_use_id source.composition_run_id
      ~parent_tool_use_id:source.parent_tool_use_id ~alias in
  let* () = if String.equal activation.Keeper_skill_activation_ledger.skill_tool_use_id expected_id
    then Ok () else Error (Invalid_source "child activation is not the original logical invocation") in
  let parent_tool = match source.producer with
    | Prepared -> Keeper_tool_composition_catalog.run_tool_name
    | Named {tool_name;_} -> tool_name in
  let expected : Keeper_skill_activation_recorder.result_child =
    {alias=Plan.Node_id.to_string alias;skill_reference=Plan.child_reference child.child;
     skill_tool_use_id=expected_id;
     activation_frame_sha256=Keeper_skill_activation_ledger.activation_frame_sha256 activation} in
  let* original = Keeper_skill_activation_recorder.find_bound_result_children
      ~config:(Workspace.default_config journal.base_path) bound ~composition_run_id:source.composition_run_id
      ~logical_parent_tool_use_id:(Plan.Composition_run_id.result_receipt_id source.composition_run_id)
      ~source_turn:source.source_turn ~tool_name:parent_tool [expected]
    |> Result.map_error (fun error -> Invalid_source (Keeper_skill_activation_recorder.error_to_string error)) in
  let* activation = match original with [activation] -> Ok activation
    | [] | _::_::_ -> Error (Invalid_source "original child activation is not unique") in
  Ok (Nested {parent_run_id=source.composition_run_id;parent_node_id=attempt.occurrence.node_id;
    parent_execution_id=attempt.occurrence.execution_id;
    parent_occurrence_tool_use_id=attempt.occurrence.tool_use_id;
    result_node_id=child.result.id;args=attempt.occurrence.input;activation},bound_plan)

let record_child_submission (attempt : attempt) ~plan ~child_source =
  let journal = attempt.worker.journal in
  let* child = submission_operand attempt plan in
  let* origin,context = match child_source.producer with
    | Named {origin=Nested origin;activation=Some context;_} -> Ok (origin,context)
    | Named {origin=Standalone;_} | Named {origin=Nested _;activation=None;_} | Prepared ->
      Error (Invalid_source "child source has no original Nested admission") in
  let* expected,bound_plan = child_origin attempt ~plan ~activation:origin.activation in
  let* bound = original_nested_context journal in
  let parent = journal.immutable_source in
  let* () = if canonical_equal (named_origin_to_yojson expected) (named_origin_to_yojson (Nested origin))
      && canonical_equal (Keeper_skill_activation_recorder.bound_context_to_yojson bound)
        (Keeper_skill_activation_recorder.bound_context_to_yojson context)
      && String.equal child_source.keeper_name parent.keeper_name
      && child_source.source_turn = parent.source_turn && child_source.source_task_id = parent.source_task_id
      && (match child_source.producer with
          | Named {tool_name;skill_reference;_} ->
            String.equal tool_name (Plan.child_tool_name child.child)
            && Skill_reference.equal skill_reference (Plan.child_reference child.child)
          | Prepared -> false)
    then Ok () else Error Source_conflict in
  let* child_journal = load ~base_path:journal.base_path ~keeper_name:child_source.keeper_name
      ~composition_run_id:child_source.composition_run_id in
  let* () = if same_source child_source child_journal.immutable_source then Ok () else Error Source_conflict in
  let* () = validate_source_plan child_journal ~plan:bound_plan in
  update_existing journal (fun state ->
    match check_attempt attempt state with
    | Error error -> None,Error error
    | Ok () ->
      let key = Plan.Node_id.to_string attempt.occurrence.node_id in
      match Nodes.find_opt key state.children with
      | Some link when same_source link.child_source child_source
          && Plan.Node_id.equal link.result_node_id child.result.id
          && Ids.Execution_id.equal link.occurrence.execution_id attempt.occurrence.execution_id
          && String.equal link.occurrence.tool_use_id attempt.occurrence.tool_use_id ->
        None,Ok {attempt;link}
      | Some _ -> None,Error Source_conflict
      | None ->
        let link = {occurrence=attempt.occurrence;result_node_id=child.result.id;child_source;accepted=None} in
        let event = event "child_intent" state.source_sha
          ["occurrence",occurrence_json link.occurrence;
           "result_node_id",`String (Plan.Node_id.to_string link.result_node_id);"child_source",source_json child_source] in
        Some (row event),Ok {attempt;link})

let accept_child_submission (submission : child_submission) ~request_id =
  let attempt = submission.attempt in
  let journal = attempt.worker.journal in
  let* binding = accepted_child_binding ~observation:Acceptance_recovery ~base_path:journal.base_path submission.link in
  let* () = if String.equal request_id binding.request_id then Ok () else Error Source_conflict in
  let* _ = Async.load_canonical_durable_queued ~base_path:journal.base_path
      ~caller:journal.immutable_source.keeper_name request_id
    |> Result.map_error (fun error -> Queued_request_rejected (Async.canonical_queued_error_to_string error)) in
  update_existing journal (fun state ->
    match check_attempt attempt state with
    | Error error -> None,Error error
    | Ok () ->
      let key = Plan.Node_id.to_string attempt.occurrence.node_id in
      match Nodes.find_opt key state.children with
      | Some current when same_source current.child_source submission.link.child_source ->
        (match current.accepted with
         | Some prior when canonical_equal (Dependency.composition_to_json prior) (Dependency.composition_to_json binding) -> None,Ok ()
         | Some _ -> None,Error Source_conflict
         | None when child_occurrence_matches current attempt.occurrence ->
           Some (row (event "child_accepted" state.source_sha
             ["node_id",`String key;"binding",Dependency.composition_to_json binding])),Ok ()
         | None -> None,Error (Attempt_conflict attempt.occurrence.node_id))
      | Some _ | None -> None,Error Source_conflict)

let accepted_child_submission (submission : child_submission) =
  let attempt = submission.attempt in
  let journal = attempt.worker.journal in
  let read () = update_existing journal (fun state -> None,
    let* () = check_attempt attempt state in
    match Nodes.find_opt (Plan.Node_id.to_string attempt.occurrence.node_id) state.children with
    | Some link when same_source link.child_source submission.link.child_source ->
      (match link.accepted with
       | Some binding -> Ok binding
       | None -> Error (Invalid_result "parent has no committed original child acceptance"))
    | Some _ | None -> Error Source_conflict) in
  let* expected = read () in
  let* actual = accepted_child_binding ~observation:Acceptance_recovery
      ~base_path:journal.base_path submission.link in
  let* current = read () in
  if canonical_equal (Dependency.composition_to_json expected) (Dependency.composition_to_json actual)
      && canonical_equal (Dependency.composition_to_json expected) (Dependency.composition_to_json current)
  then Ok actual else Error Ownership_changed

let child_result_binding (attempt : attempt) ~plan =
  let journal = attempt.worker.journal in
  let* () = validate_plan attempt.worker ~plan in
  let* child = match Plan.contract plan attempt.occurrence.node_id with
    | Some {target=Plan.Child_result child;_} when attempt.occurrence.readonly
        && attempt.occurrence.input = `Assoc [] -> Ok child
    | Some {target=(Plan.Child_arguments _ | Plan.Child_submission _ | Child_result _ | Descriptor_target _);_} | None ->
      Error (Node_identity_conflict attempt.occurrence.node_id) in
  let* link = update_existing journal (fun state -> None,
    let* () = check_attempt attempt state in
    match Nodes.find_opt (Plan.Node_id.to_string child.submission.id) state.children with
    | Some link when Plan.Node_id.equal link.result_node_id child.result.id && Option.is_some link.accepted -> Ok link
    | Some _ | None -> Error (Invalid_result "native result has no accepted original child")) in
  let* binding = accepted_child_binding ~observation:Result_observation ~base_path:journal.base_path link in
  let* () = update_existing journal (fun state -> None,
    let* () = check_attempt attempt state in
    match Nodes.find_opt (Plan.Node_id.to_string child.submission.id) state.children with
    | Some current when child_link_json current = child_link_json link -> Ok ()
    | Some _ | None -> Error Ownership_changed) in
  Ok binding

let lookup (worker : worker) ~node_id ~tool_name ~input =
  update_existing worker.journal (fun state -> None,
    let* record = checked_node worker state ~node_id ~tool_name ~input in replay_for state.children worker.binding node_id record)

let launch_recheck (worker : worker) ~node_id ~tool_name ~input ~execution_id ~tool_use_id =
  update_existing worker.journal (fun state -> None,
    let* () = check_worker worker state in
    match Nodes.find_opt (Plan.Node_id.to_string node_id) state.nodes with
    | None -> Error (Node_identity_conflict node_id)
    | Some record ->
      let occurrence = occurrence_of_record record in
      if not (same_node_identity occurrence ~node_id ~tool_name ~input
          && Ids.Execution_id.equal occurrence.execution_id execution_id
          && String.equal occurrence.tool_use_id tool_use_id
          && owned_job_launch occurrence)
      then Error (Node_identity_conflict node_id) else
      let* record = checked_node worker state ~node_id ~tool_name ~input in
      let* replay = replay_for state.children worker.binding node_id record in
      match replay with
      | Recheck_launch original -> Ok (Some original)
      | Dispatch | Reuse_completed _ -> Ok None
      | Recheck_result _ | Recheck_child_submission _ -> Error (Node_identity_conflict node_id))

let begin_attempt (worker : worker) ~node_id ~tool_name ~input ~execution_id ~tool_use_id ~readonly ?launch_invocation () =
  update_existing worker.journal (fun state ->
    let decision =
      let* record = checked_node worker state ~node_id ~tool_name ~input in
      let* replay = replay_for state.children worker.binding node_id record in
      match replay with
      | Reuse_completed _ -> Error (Attempt_conflict node_id)
      | Dispatch | Recheck_result _ | Recheck_launch _ | Recheck_child_submission _ ->
        let* () = match replay with
          | Recheck_result stored when not readonly
              || not (Ids.Execution_id.equal execution_id stored.execution_id)
              || tool_use_id <> stored.tool_use_id -> Error (Attempt_conflict node_id)
          | Recheck_launch stored when readonly
              || not (Ids.Execution_id.equal execution_id stored.execution_id)
              || tool_use_id <> stored.tool_use_id
              || launch_invocation <> Some stored.invocation -> Error (Attempt_conflict node_id)
          | Recheck_child_submission stored when readonly
              || not (Ids.Execution_id.equal execution_id stored.execution_id)
              || tool_use_id <> stored.tool_use_id -> Error (Attempt_conflict node_id)
          | Dispatch | Reuse_completed _ | Recheck_result _
          | Recheck_launch _ | Recheck_child_submission _ -> Ok () in
        if not (exact_name tool_use_id && exact_name (Ids.Execution_id.to_string execution_id)) then Error (Invalid_result "invalid execution occurrence") else
        let sequence = match record with None -> 1 | Some record -> (occurrence_of_record record).sequence + 1 in
        let launch_mode = match replay with Recheck_launch _ -> Existing_only
          | Dispatch | Reuse_completed _ | Recheck_result _ | Recheck_child_submission _ -> Initial_launch in
        Ok {node_id; tool_name; input; input_sha = json_sha input; owner = worker.binding; sequence;
          execution_id; tool_use_id; readonly; launch_invocation; launch_mode} in
    match decision with
    | Error error -> None, Error error
    | Ok occurrence -> Some (row (attempt_event worker.journal.source_sha occurrence)), Ok {worker; occurrence})

let settle_attempt ?failure_effect_disposition ?deferred_kind attempt ~result ~result_bytes ~truncated_to =
  let completed = {execution_id = attempt.occurrence.execution_id; tool_use_id = attempt.occurrence.tool_use_id; result; result_bytes; truncated_to} in
  let phase = match failure_effect_disposition, result with
    | Some phase, _ -> Some phase
    | None, Tool_result.Failed failure -> Some failure.effect_disposition
    | None, (Tool_result.Completed _ | Deferred _) -> None in
  let dependency_wait = match deferred_kind with
    | Some (Keeper_tool_execution.Owned_job_result_wait job_id) -> Some (Dependency.Owned_job job_id)
    | Some (Keeper_tool_execution.Composition_result_wait binding) -> Some (Dependency.Composition_result binding)
    | None | Some (Generic_deferred | External_effect_deferred _) -> None in
  let* encoded = Result.map_error (fun detail -> Invalid_result detail) (decode (fun () ->
    require (result_bytes >= 0 && Option.fold ~none:true ~some:(fun value -> value >= 0) truncated_to) "negative result size";
    require (String.equal (Tool_result.tool_name result) attempt.occurrence.tool_name) "result tool mismatch";
    let encoded = completed_json completed in valid_json encoded;
    let decoded = completed_of_json (Yojson.Safe.from_string (Yojson.Safe.to_string encoded)) in
    require (decoded.result = result) "strict durable result codec did not preserve complete payload";
    encoded)) in
  update_existing attempt.worker.journal (fun state ->
    let valid =
      let* () = check_worker attempt.worker state in
      decode (fun () -> Option.iter (fun job_id -> require
        (valid_dependency_wait state.children attempt.occurrence result phase job_id)
        "dependency wait does not match the exact read-only result leaf") dependency_wait)
      |> Result.map_error (fun detail -> Invalid_result detail) in
    match valid with
    | Error error -> None, Error error
    | Ok () ->
      let record = Nodes.find_opt (Plan.Node_id.to_string attempt.occurrence.node_id) state.nodes in
      match record with
      | Some (Attempting current) when same_occurrence current attempt.occurrence ->
        let json = event "settled" state.source_sha ["occurrence", occurrence_json current; "completed", encoded;
          "failure_effect_disposition", option_json effect_json phase; "dependency_wait", dependency_wait_json dependency_wait] in
        Some (row json), Ok ()
      | Some (Settled (current, prior, prior_phase, prior_wait)) when same_occurrence current attempt.occurrence
          && completed_json prior = encoded && prior_phase = phase && prior_wait = dependency_wait -> None, Ok ()
      | Some (Attempting _ | Settled _) | None -> None, Error (Attempt_conflict attempt.occurrence.node_id))
