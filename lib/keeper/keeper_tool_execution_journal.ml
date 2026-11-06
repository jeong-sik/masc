(* One append authority for an immutable prepared source, its async owners and
   node occurrences. Kept below the existing durable async consumer tree so the
   full typed results retain their artifact roots independently of transcripts. *)

include Keeper_tool_execution_journal_types
include Keeper_tool_execution_journal_json
include Keeper_tool_execution_journal_model
include Keeper_tool_execution_journal_state_decode
include Keeper_tool_execution_journal_store
include Keeper_tool_execution_journal_resolution
module Plan = Keeper_tool_plan
module Async = Keeper_msg_async
module Dependency = Keeper_composition_dependency
module Nodes = Map.Make (String)

open Result.Syntax

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

let validate_predecessor_terminals (continuation : continuation) =
  let journal = continuation.journal in
  List.fold_left (fun prior (expected : Async.entry) ->
    let* () = prior in
    let* proof = Async.load_canonical_durable_terminal ~base_path:journal.base_path
        ~caller:journal.immutable_source.keeper_name expected.request_id
      |> Result.map_error (fun error -> Prior_owner_not_terminal
          {request_id=expected.request_id;reason=Async.canonical_terminal_error_to_string error}) in
    if Async.same_entry_record expected (Async.durable_terminal_entry proof) then Ok ()
    else Error Ownership_changed) (Ok ()) continuation.predecessor_terminals

let bind_continuation (continuation : continuation) ~request_id =
  let journal = continuation.journal in
  let* () = validate_artifacts ~base_path:journal.base_path journal.immutable_source in
  let* () = validate_nested_producer journal in
  let* () = validate_child_links journal continuation.suspended_children continuation.suspended_nodes in
  let* _ = nested_parent_accepted journal in
  let* () = validate_predecessor_terminals continuation in
  let* () = canonical_queued journal request_id in
  bind_expected_owner journal ~request_id ~expected:(Some continuation.expected_owner)
    ~expected_terminal:(Some continuation.terminal_entry)
    ~expected_nodes:(Some continuation.suspended_nodes)
    ~expected_children:(Some continuation.suspended_children)

let continuation_base_path (continuation : continuation) = continuation.journal.base_path
let continuation_source (continuation : continuation) = source continuation.journal
let continuation_request_id (continuation : continuation) = continuation.expected_owner.request_id
let continuation_dependencies (continuation : continuation) = continuation.dependencies

type child_admission_history = Untouched_child | Admitted_child | Admission_unconfirmed

let nodes_child_admission nodes ~node_ids =
  List.fold_left (fun history id ->
    let current = match Nodes.find_opt (Plan.Node_id.to_string id) nodes with
      | None -> Untouched_child
      | Some (Attempting _) -> Admission_unconfirmed
      | Some (Settled (_,completed,effect_disposition,wait)) ->
        (match completed.result,effect_disposition,wait with
         | Tool_result.Completed _,_,_ | Tool_result.Deferred _,_,Some _
         | Tool_result.Failed _,Some Tool_result.Proven_post_effect,_ -> Admitted_child
         | Tool_result.Failed _,(None | Some Tool_result.Proven_pre_effect
             | Some Tool_result.Effect_outcome_unknown),_
         | Tool_result.Deferred _,_,None -> Admission_unconfirmed) in
    match history,current with
    | Admitted_child,_ | _,Admitted_child -> Admitted_child
    | Admission_unconfirmed,_ | _,Admission_unconfirmed -> Admission_unconfirmed
    | Untouched_child,Untouched_child -> Untouched_child) Untouched_child node_ids

let continuation_child_admission continuation ~node_ids =
  nodes_child_admission continuation.suspended_nodes ~node_ids

let child_admission journal ~node_ids =
  update_existing journal (fun state -> None, Ok (nodes_child_admission state.nodes ~node_ids))

let normalize_dependencies = Dependency.normalize

let exact_waiting_dependencies children ~expected_owner nodes dependencies =
  let* recorded = Nodes.fold (fun _ record prior ->
    let* ids = prior in
    match record with
    | Attempting _ ->
      Error (Invalid_result "waiting owner has an unsettled or non-result-wait journal node")
    | Settled (occurrence, completed, phase, job) ->
      let refuse () =
        Error (Invalid_result "waiting owner has an unsettled or non-result-wait journal node")
      in
      (match completed.result with
       | Tool_result.Completed _ ->
         (match job with None -> Ok ids | Some _ -> refuse ())
       | Tool_result.Failed _ -> refuse ()
       | Tool_result.Deferred _ ->
         (match job with
          | Some job_id when same_binding occurrence.owner expected_owner
              && valid_dependency_wait children occurrence completed.result phase job_id -> Ok (job_id :: ids)
          | None | Some _ -> refuse ()))) nodes (Ok []) in
  let recorded = normalize_dependencies recorded in
  if recorded = [] || recorded <> normalize_dependencies dependencies
  then Error (Invalid_result "canonical waiting dependencies differ from the current journal occurrences")
  else Ok recorded

let prior_result_wait journal children prior_owners =
  let rec read terminals = function
    | [] -> Ok None
    | ((prior : binding), nodes) :: rest ->
      let* proof = Async.load_canonical_durable_terminal ~base_path:journal.base_path
          ~caller:journal.immutable_source.keeper_name prior.request_id
        |> Result.map_error (fun error -> Prior_owner_not_terminal
            {request_id=prior.request_id;reason=Async.canonical_terminal_error_to_string error}) in
      let entry = Async.durable_terminal_entry proof in
      let* () = entry_matches_source journal.immutable_source entry
        |> Result.map_error (fun reason -> Prior_owner_not_terminal
            {request_id=prior.request_id;reason}) in
      match entry.status with
      | Async.Waiting_for_dependencies {dependencies;_} ->
        (match exact_waiting_dependencies children ~expected_owner:prior nodes dependencies with
         | Ok dependencies -> Ok (Some (dependencies,List.rev (entry :: terminals)))
         | Error error ->
           (* A no-dispatch successor may stop with the exact predecessor wait.
              Binding snapshots prove that it changed no node ownership or
              result; the canonical terminal proves the same waiting jobs. *)
           match rest with
           | (_,predecessor_nodes)::_ when nodes = predecessor_nodes ->
             let* original = read (entry :: terminals) rest in
             (match original with
              | Some (original_jobs,_) when original_jobs = normalize_dependencies dependencies -> Ok original
              | Some _ | None -> Error error)
           | _ -> Error error)
      | Lost _ -> read (entry :: terminals) rest
      | Cancelled _ | Persistence_failed _ | Done _ -> Ok None
      | Queued | Running | Cancelling _ ->
        Error (Prior_owner_not_terminal {request_id=prior.request_id;
          reason="predecessor terminal proof has an active status"})
  in read [] prior_owners

let launch_replay_proven occurrence =
  owned_job_launch occurrence && Option.is_some occurrence.launch_invocation

let recoverable_lost_nodes children nodes dependencies =
  let* recorded_jobs = Nodes.fold (fun _ record prior ->
    let* jobs = prior in
    let occurrence = occurrence_of_record record in
    let job = result_read_dependency children occurrence in
    let replay_proven = child_ack_proven children occurrence || match record with
      | Attempting occurrence -> occurrence.readonly || launch_replay_proven occurrence
      | Settled (occurrence, completed, phase, job) ->
        (match job with
         | Some job_id -> valid_dependency_wait children occurrence completed.result phase job_id
         | None ->
           (match completed.result with
            | Tool_result.Completed _ -> true
            | Tool_result.Deferred _ -> false
            | Tool_result.Failed _ ->
              (match phase with
               | Some Tool_result.Proven_pre_effect ->
                 occurrence.readonly || child_intent_proven children occurrence || launch_replay_proven occurrence
               | Some Tool_result.Effect_outcome_unknown -> launch_replay_proven occurrence
               | None | Some Tool_result.Proven_post_effect -> false))) in
    if not replay_proven then Error (Invalid_result
        "lost continuation has a deferred or unproven node that cannot replay")
    else Ok (Option.to_list job @ jobs)) nodes (Ok []) in
  let recorded_jobs = normalize_dependencies recorded_jobs in
  if List.for_all (fun job_id -> List.mem job_id recorded_jobs) dependencies then Ok ()
  else Error (Invalid_result "original waiting dependencies are absent from the lost journal")

let validate_lost_without_wait children expected_owner nodes =
  Nodes.fold (fun _ record prior ->
    let* () = prior in
    let occurrence = occurrence_of_record record in
    if child_ack_proven children occurrence then Ok () else match record with
    | Attempting occurrence when occurrence.readonly || launch_replay_proven occurrence -> Ok ()
    | Attempting _ -> Error (Replay_not_proven occurrence.node_id)
    | Settled _ -> replay_for children expected_owner occurrence.node_id (Some record)
        |> Result.map (fun _ -> ())) nodes (Ok ())

let waiting_continuation journal = filesystem (fun () ->
  let* () = validate_artifacts ~base_path:journal.base_path journal.immutable_source in
  let* state = strict_read ~root:journal.root journal.path in
  let* () = check_source journal state in
  if state.resolution <> None then Ok None else
  let* () = validate_nested_producer journal in
  match state.owner with
  | None -> Ok None
  | Some expected_owner ->
    match Async.load_canonical_durable_terminal ~base_path:journal.base_path
        ~caller:journal.immutable_source.keeper_name expected_owner.request_id with
    | Error (Async.Canonical_terminal_runtime_active _ | Canonical_terminal_nonterminal _) -> Ok None
    | Error ((Async.Canonical_terminal_absent | Canonical_terminal_unreadable _
             | Canonical_terminal_access_rejected _ | Canonical_terminal_publication_ambiguous _
             | Canonical_terminal_noncanonical_location _) as error) -> Error (Prior_owner_not_terminal
        {request_id=expected_owner.request_id;reason=Async.canonical_terminal_error_to_string error})
    | Ok proof ->
      let entry = Async.durable_terminal_entry proof in
      let* () = entry_matches_source journal.immutable_source entry
        |> Result.map_error (fun reason -> Prior_owner_not_terminal {request_id=expected_owner.request_id;reason}) in
      match entry.status with
      | Async.Waiting_for_dependencies {dependencies;_} ->
        let* () = validate_child_links journal state.children state.nodes in
        let* dependencies,predecessor_terminals =
          match exact_waiting_dependencies state.children ~expected_owner state.nodes dependencies with
          | Ok jobs -> Ok (jobs,[])
          | Error error ->
            (match state.prior_owners with
             | (_,predecessor_nodes)::_ when state.nodes = predecessor_nodes ->
               let* original = prior_result_wait journal state.children state.prior_owners in
               (match original with
                | Some (jobs,proofs) when jobs = normalize_dependencies dependencies ->
                  let* () = recoverable_lost_nodes state.children state.nodes jobs in
                  Ok (jobs,proofs)
                | Some _ | None -> Error error)
             | _ -> Error error) in
        Ok (Some {journal;expected_owner;terminal_entry=entry;predecessor_terminals;
          suspended_nodes=state.nodes;suspended_children=state.children;dependencies})
      | Lost _ ->
        let* () = validate_child_links journal state.children state.nodes in
        let* original_wait = prior_result_wait journal state.children state.prior_owners in
        (match original_wait with
         | None ->
           (* No recorded wait is not proof of absent effects. Preserve the
              unresolved first owner before discovery considers retirement or
              a public resume falls back to ordinary request admission. *)
           let* () = validate_lost_without_wait state.children expected_owner state.nodes in
           let* child_admitted = nested_parent_accepted journal in
           let has_accepted_child = Nodes.exists (fun _ link -> Option.is_some link.accepted) state.children in
           let has_recheck_launch = Nodes.exists (fun _ record ->
             launch_replay_proven (occurrence_of_record record)) state.nodes in
           if child_admitted || has_accepted_child || has_recheck_launch then
             Ok (Some {journal;expected_owner;terminal_entry=entry;predecessor_terminals=[];
               suspended_nodes=state.nodes;suspended_children=state.children;dependencies=[]})
           else Ok None
         | Some (dependencies,predecessor_terminals) ->
           let* () = recoverable_lost_nodes state.children state.nodes dependencies in
           Ok (Some {journal;expected_owner;terminal_entry=entry;predecessor_terminals;
             suspended_nodes=state.nodes;suspended_children=state.children;dependencies}))
      | Queued | Running | Cancelling _ | Cancelled _
      | Persistence_failed _ | Done _ -> Ok None)

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

type discovery_scope = All_pending | Result_notifications of result_notification list

module Result_keys = Stdlib.Set.Make (struct
  type t = string * string * Dependency.t
  (* These closed immutable dependency values contain only original identities,
     including exact Skill revisions. This ordering never drives marker order. *)
  let compare = Stdlib.compare
end)

type pending_continuations =
  { inspected : int; ready : continuation list; waiting : int; unselected : int; retired : int
  ; failures : (string * error) list }
type discovery = Ready of continuation | Still_waiting | Unselected | Retired | Lock_infrastructure

let continuation_data_name name =
  let suffix = ".json" in
  String.length name = 64 + String.length suffix && String.ends_with ~suffix name
  && String.for_all (function '0'..'9' | 'a'..'f' -> true | _ -> false) (String.sub name 0 64)

let continuation_lock_data_name name =
  let suffix = ".lock" in
  if not (String.ends_with ~suffix name) then None else
  let data_name = String.sub name 0 (String.length name - String.length suffix) in
  if continuation_data_name data_name then Some data_name else None

let pending_continuations_with ~scope ~before_retire ~on_ready ~read_composition_result ~base_path =
  let* base_path = filesystem (fun () -> Ok (Fs_compat.realpath base_path)) in
  let root = Common.masc_dir_from_base_path ~base_path in
  let directory = continuation_directory ~base_path in
  let* names = filesystem (fun () ->
    let* inspection = Fs_compat.inspect_owned_directory_chain ~ownership_root:root directory
      |> Result.map_error (fun error -> Persistence_failed
          (Fs_compat.owned_directory_chain_rejection_to_string error)) in
    match inspection with
      | Fs_compat.Owned_directory_missing -> Ok []
      | Owned_directory _ -> Fs_compat.read_owned_directory ~owner_uid:(Unix.getuid ())
          ~ownership_root:root directory
          |> Result.map_error (fun error -> Persistence_failed
              (Fs_compat.owned_regular_file_read_error_to_string error))) in
  let result_keys = match scope with
    | All_pending -> None
    | Result_notifications notifications ->
      Some (List.fold_left (fun keys (notification : result_notification) ->
        Result_keys.add (notification.base_path,notification.keeper_name,notification.dependency) keys)
        Result_keys.empty notifications) in
  let selected (continuation : continuation) =
    match result_keys with
    | None -> true
    | Some keys ->
      (* Empty Lost waits need original recovery without a result binding.
         The immutable per-pass index matches sealed typed dependencies only;
         result readiness and intake authority are still read afresh. *)
      continuation.dependencies = [] || List.exists (fun dependency ->
        Result_keys.mem (continuation.journal.base_path,
          continuation.journal.immutable_source.keeper_name,dependency) keys)
        continuation.dependencies in
  let inspect name = filesystem (fun () ->
    let path = Filename.concat directory name in
    match continuation_lock_data_name name with
    | Some data_name ->
      (* Retirement unlinks only the marker data file, leaving this lock
         sibling behind. An existence-only check skips those orphaned locks
         without acquiring or validating them, so each pass stays
         proportional to live markers, not to every historical request. *)
      let data_path = Filename.concat directory data_name in
      if Fs_compat.file_exists data_path then
        let* _ = continuation_snapshot ~root data_path in
        Ok Lock_infrastructure
      else Ok Lock_infrastructure
    | None when not (continuation_data_name name) ->
      Error (Invalid_continuation_marker "unexpected pending partition filename")
    | None ->
      let* snapshot = continuation_snapshot ~root path in
      if Fs_compat.Private_jsonl_cursor.is_missing snapshot.cursor then Ok Retired
      else
        let* marker = decode_continuation_marker snapshot.bytes in
        if name <> continuation_filename marker.request_id
        then Error (Invalid_continuation_marker "marker filename does not bind its request") else
        let* journal = load_authority ~base_path ~keeper_name:marker.keeper_name
            ~composition_run_id:marker.composition_run_id in
        let* state = strict_read ~root journal.path in
        let* () = check_source journal state in
        let* () = match state.resolution with
          | Some _ -> Ok ()
          | None -> validate_artifacts ~base_path journal.immutable_source in
        match Async.load_canonical_durable_terminal ~base_path ~caller:marker.keeper_name marker.request_id with
        | Error (Async.Canonical_terminal_runtime_active _ | Canonical_terminal_nonterminal _) -> Ok Still_waiting
        | Error (Async.Canonical_terminal_absent | Async.Canonical_terminal_unreadable _
            | Async.Canonical_terminal_access_rejected _
            | Async.Canonical_terminal_publication_ambiguous _
            | Async.Canonical_terminal_noncanonical_location _ as error) ->
          Error (Prior_owner_not_terminal
            {request_id=marker.request_id;reason=Async.canonical_terminal_error_to_string error})
        | Ok proof ->
          let entry = Async.durable_terminal_entry proof in
          let* () = entry_matches_source journal.immutable_source entry
            |> Result.map_error (fun reason -> Invalid_continuation_marker reason) in
          let retire () =
            before_retire path;
            let* () = validate_owned_path ~root ~path ~create:true in
            let* receipt = Fs_compat.purge_private_jsonl_durable_locked_at_snapshot_result path
                ~expected:snapshot
              |> Fs_compat.private_jsonl_cursor_success_receipt
              |> Result.map_error (fun error -> Persistence_failed
                  (Fs_compat.private_jsonl_transaction_error_to_string error)) in
            ignore (continuation_receipt path receipt); Ok Retired in
          match state.resolution with
          | Some resolution ->
            if not (String.equal resolution.owner.request_id marker.request_id)
            then Error (Invalid_continuation_marker "resolved owner differs from pending marker") else
            let () = before_retire path in
            let* () = retire_resolution_marker ~root ~path ~snapshot resolution in
            Ok Retired
          | None -> match state.owner with
          | None -> Error (Invalid_continuation_marker "request has no bound journal owner")
          | Some current when current.request_id <> marker.request_id -> retire ()
          | Some _ ->
            match entry.status with
            | Async.Waiting_for_dependencies _ | Lost _ ->
              let* candidate = waiting_continuation journal in
              (match candidate with
               | None when (match entry.status with
                   | Async.Lost _ -> true
                   | Queued | Running | Cancelling _ | Cancelled _ | Persistence_failed _
                   | Waiting_for_dependencies _ | Done _ -> false) -> retire ()
               | None -> Error Ownership_changed
               | Some continuation when continuation_request_id continuation <> marker.request_id -> Error Ownership_changed
               | Some continuation when not (selected continuation) -> Ok Unselected
               | Some continuation ->
                 let* readiness = continuation_readiness ~read_composition_result continuation in
                 match readiness with
                 | Waiting_for_results -> Ok Still_waiting
                 | Results_ready -> Ok (Ready continuation))
            | Cancelled _ | Persistence_failed _ | Done _ -> retire ()
            | Queued | Running | Cancelling _ -> Error (Invalid_continuation_marker "terminal proof has an active status")) in
  let empty = {inspected=0;ready=[];waiting=0;unselected=0;retired=0;failures=[]} in
  let report = List.fold_left (fun report name ->
    match inspect name with
    | Ok Lock_infrastructure -> report
    | Ok (Ready continuation) ->
      (* The original reads have returned and released their authority scopes.
         Scheduling exceptions are not journal/filesystem failures. *)
      on_ready continuation;
      let report = {report with inspected=report.inspected+1} in
      {report with ready=continuation :: report.ready}
    | Ok Still_waiting ->
      let report = {report with inspected=report.inspected+1} in
      {report with waiting=report.waiting+1}
    | Ok Unselected ->
      {report with inspected=report.inspected+1;unselected=report.unselected+1}
    | Ok Retired ->
      let report = {report with inspected=report.inspected+1} in
      {report with retired=report.retired+1}
    (* Permanent Invalid_result retains its marker unless an explicit, durable
       owner-bound resolution seals this run and its exact marker snapshot.
       Missing authority never becomes retirement or replacement dispatch. *)
    | Error error ->
      let report = {report with inspected=report.inspected+1} in
      {report with failures=(name,error) :: report.failures}) empty names in
  Ok {report with ready=List.rev report.ready;failures=List.rev report.failures}

let discover_pending_continuations ~scope ~on_ready ~read_composition_result ~base_path =
  pending_continuations_with ~scope ~before_retire:(fun _ -> ()) ~on_ready ~read_composition_result ~base_path

let pending_continuations ~read_composition_result ~base_path =
  discover_pending_continuations ~scope:All_pending ~on_ready:ignore ~read_composition_result ~base_path

module For_testing = struct
  let pending_continuations ~before_retire ~read_composition_result ~base_path =
    pending_continuations_with ~scope:All_pending ~before_retire ~on_ready:ignore ~read_composition_result ~base_path
end

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
