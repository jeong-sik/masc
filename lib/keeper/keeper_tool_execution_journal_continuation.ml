module Plan = Keeper_tool_plan
module Async = Keeper_msg_async
module Dependency = Keeper_composition_dependency
module Nodes = Map.Make (String)
open Result.Syntax
open Keeper_tool_execution_journal_types
open Keeper_tool_execution_journal_model
open Keeper_tool_execution_journal_state_decode
open Keeper_tool_execution_journal_store
open Keeper_tool_execution_journal_binding

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
