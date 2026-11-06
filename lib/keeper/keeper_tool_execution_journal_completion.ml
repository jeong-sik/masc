module Plan = Keeper_tool_plan
module Async = Keeper_msg_async
module Dependency = Keeper_composition_dependency
open Result.Syntax
open Keeper_tool_execution_journal_types
open Keeper_tool_execution_journal_json
open Keeper_tool_execution_journal_model
open Keeper_tool_execution_journal_store
open Keeper_tool_execution_journal_binding
open Keeper_tool_execution_journal_continuation

type read_composition_result =
  base_path:string -> keeper_name:string -> Dependency.composition -> (Dependency.readiness,string) result

type result_notification =
  { base_path : string
  ; keeper_name : string
  ; dependency : Dependency.t
  }

type completion_disposition =
  | Canonical_completion
  | Recovery_pending
  | Unadmitted_attempt

type completion_observation =
  { observed_disposition : completion_disposition
  ; observed_source : (t * state) option }

let observe_completion ~base_path (entry : Async.entry) = filesystem (fun () ->
  let fields = Option.value ~default:[] entry.request_context in
  let values name = List.filter_map (fun (key,value) ->
    if String.equal key name then Some value else None) fields in
  match values "draft_reference", values "run_artifact" with
  | [],[] ->
    if values "composition_tool" = [`String Keeper_tool_composition_catalog.run_tool_name]
    then Error (Invalid_source "prepared completion lacks its journal artifact envelope")
    else Ok {observed_disposition=Canonical_completion;observed_source=None}
  | [_],[_] ->
    let* composition_run_id = match values "composition_run_id" with
      | [`String identity] -> Plan.Composition_run_id.of_string identity
          |> Result.map_error (fun _ -> Invalid_source "completion has an invalid run identity")
      | [] | _::_ -> Error (Invalid_source "completion lacks its exact run identity") in
    let* journal = load ~base_path ~keeper_name:entry.keeper_name ~composition_run_id in
    let* () = if String.equal (Fs_compat.realpath entry.base_path) journal.base_path
      then Ok () else Error Source_conflict in
    let* () = entry_matches_source journal.immutable_source entry
      |> Result.map_error (fun detail -> Invalid_source detail) in
    let rec observe () =
      let* before = strict_read ~root:journal.root journal.path in
      let* () = check_source journal before in
      let belongs (binding : binding) = String.equal binding.request_id entry.request_id in
      let member = Option.exists belongs before.owner
        || List.exists (fun (binding,_) -> belongs binding) before.prior_owners in
      let* disposition = if not member then Ok Unadmitted_attempt else
        match entry.status with
        | Queued | Running | Cancelling _ | Cancelled _ | Persistence_failed _
        | Waiting_for_dependencies _ | Done _ -> Ok Canonical_completion
        | Lost _ ->
          match before.owner with
          | Some owner when not (belongs owner) -> Ok Recovery_pending
          | Some _ -> waiting_continuation journal |> Result.map (function
              | Some _ -> Recovery_pending | None -> Canonical_completion)
          | None -> Error Ownership_changed in
      let* after = strict_read ~root:journal.root journal.path in
      let* () = check_source journal after in
      if same_owner before.owner after.owner
      then Ok {observed_disposition=disposition;observed_source=Some (journal,before)}
      else observe () in
    observe ()
  | ([],_::_) | (_::_,[]) | (_::_,_::_) ->
    Error (Invalid_source "completion has a partial or duplicate journal artifact envelope"))

let completion_observation_disposition observation = observation.observed_disposition

let completion_disposition ~base_path entry =
  observe_completion ~base_path entry |> Result.map completion_observation_disposition

let completion_result_notification observation = filesystem (fun () ->
  match observation.observed_disposition,observation.observed_source with
  | (Recovery_pending | Unadmitted_attempt),_ | Canonical_completion,None -> Ok None
  | Canonical_completion,Some (journal,state) ->
    match journal.immutable_source.producer with
    | Prepared -> Ok None
    | Named _ ->
      let* binding = original_named_binding journal state in
      Ok (Some {base_path=journal.base_path;keeper_name=journal.immutable_source.keeper_name;
        dependency=Dependency.Composition_result binding}))

let completion_pending ~base_path entry =
  completion_disposition ~base_path entry |> Result.map (function
    | Canonical_completion -> false
    | Recovery_pending | Unadmitted_attempt -> true)

let continuation_readiness ~read_composition_result (continuation : continuation) = filesystem (fun () ->
  let journal = continuation.journal in
  let* state = strict_read ~root:journal.root journal.path in
  let* () = check_source journal state in
  if state.resolution <> None || not (same_owner state.owner (Some continuation.expected_owner))
      || state.nodes <> continuation.suspended_nodes
      || not (same_children state.children continuation.suspended_children) then Error Ownership_changed
  else
  let* () = validate_nested_producer journal in
  let* () = validate_child_links journal state.children state.nodes in
  let* _ = nested_parent_accepted journal in
  let* () = validate_predecessor_terminals continuation in
  let* proof = Async.load_canonical_durable_terminal ~base_path:journal.base_path
      ~caller:journal.immutable_source.keeper_name continuation.expected_owner.request_id
    |> Result.map_error (fun error -> Prior_owner_not_terminal
        {request_id=continuation.expected_owner.request_id;reason=Async.canonical_terminal_error_to_string error}) in
  if not (Async.same_entry_record continuation.terminal_entry (Async.durable_terminal_entry proof))
  then Error Ownership_changed
  else List.fold_left (fun prior dependency ->
    let* readiness = prior in
    let* ready = match dependency with
      | Dependency.Owned_job job_id ->
        let* record = Keeper_owned_job_store.load ~base_path:journal.base_path
            ~keeper_name:journal.immutable_source.keeper_name job_id
          |> Result.map_error (fun error -> Invalid_result (Keeper_owned_job_store.error_to_string error)) in
        Ok (Keeper_owned_job_store.result_ready record)
      | Dependency.Composition_result binding ->
        let* result = read_composition_result ~base_path:journal.base_path
            ~keeper_name:journal.immutable_source.keeper_name binding
          |> Result.map_error (fun detail -> Invalid_result detail) in
        Ok (result = Dependency.Ready) in
    match readiness, ready with
    | Results_ready, true -> Ok Results_ready
    | (Waiting_for_results | Results_ready), false
    | Waiting_for_results, true -> Ok Waiting_for_results)
      (Ok Results_ready) continuation.dependencies)

let named_result_owner_state (journal : t) binding = filesystem (fun () ->
  let* state = strict_read ~root:journal.root journal.path in
  let* () = check_source journal state in
  let* original = original_named_binding journal state in
  let* () = if canonical_equal (Dependency.composition_to_json original) (Dependency.composition_to_json binding)
    then Ok () else Error (Invalid_source "result binding is not the original named owner") in
  let rec validate_prior = function
  | [] -> Ok ()
  | ((owner : binding),nodes)::older ->
    let* proof = Async.load_canonical_durable_terminal ~base_path:journal.base_path
        ~caller:journal.immutable_source.keeper_name owner.request_id
      |> Result.map_error (fun error -> Prior_owner_not_terminal
          {request_id=owner.request_id;reason=Async.canonical_terminal_error_to_string error}) in
    let entry = Async.durable_terminal_entry proof in
    let* () = entry_matches_source journal.immutable_source entry
      |> Result.map_error (fun detail -> Invalid_source detail) in
    let* () = match entry.status with
    | Waiting_for_dependencies {dependencies;_} ->
      (match exact_waiting_dependencies state.children ~expected_owner:owner nodes dependencies with
       | Ok _ -> Ok ()
       | Error error ->
         (* A successor that stops before dispatch can carry an unchanged
            predecessor's wait; its binding and canonical status stay explicit. *)
         match older with
         | (_,prior_nodes)::_ when nodes = prior_nodes ->
           let* inherited = prior_result_wait journal state.children older in
           (match inherited with
            | Some (original,_) when original = normalize_dependencies dependencies ->
              recoverable_lost_nodes state.children nodes original
            | Some _ | None -> Error error)
         | _ -> Error error)
    | Lost _ -> Ok ()
    | Queued | Running | Cancelling _ | Cancelled _ | Persistence_failed _ | Done _ ->
      Error (Invalid_result "named successor has no resumable canonical predecessor") in
    validate_prior older in
  let* () = validate_prior state.prior_owners in
  let* owner = match state.owner with Some owner -> Ok owner | None -> Error Ownership_changed in
  let* entry = canonical_entry journal owner.request_id in
  let* () = match entry.status with
    | Queued | Running | Cancelling _ -> Ok ()
    | Waiting_for_dependencies _ | Done _ | Lost _ | Cancelled _ | Persistence_failed _ ->
      let* proof = Async.load_canonical_durable_terminal ~base_path:journal.base_path
          ~caller:journal.immutable_source.keeper_name owner.request_id
        |> Result.map_error (fun error -> Prior_owner_not_terminal
            {request_id=owner.request_id;reason=Async.canonical_terminal_error_to_string error}) in
      if Async.same_entry_record entry (Async.durable_terminal_entry proof)
      then Ok () else Error Ownership_changed in
  let* current = strict_read ~root:journal.root journal.path in
  let* () = check_source journal current in
  if same_owner current.owner state.owner && current.prior_owners = state.prior_owners && current.nodes = state.nodes
  then Ok (entry,current) else Error Ownership_changed)

let named_result_owner journal binding = named_result_owner_state journal binding |> Result.map fst

let observe_named_result ~base_path ~keeper_name (binding : Dependency.composition) = filesystem (fun () ->
  let* journal,state = load_authority_state ~base_path ~keeper_name ~composition_run_id:binding.composition_run_id in
  let* resolved = resolved_named_result journal state binding in
  match resolved with
  | Some (entry,resolution) -> Ok (journal,entry,Some resolution)
  | None ->
    let* () = validate_artifacts ~base_path:journal.base_path journal.immutable_source in
    let* entry,state = named_result_owner_state journal binding in
    (* Reuse the owner reader's final source snapshot: a concurrent resolution
       must not be hidden by its physical waiting status. *)
    let* resolved = resolved_named_result journal state binding in
    match resolved with
    | Some (entry,resolution) -> Ok (journal,entry,Some resolution)
    | None -> Ok (journal,entry,None))
