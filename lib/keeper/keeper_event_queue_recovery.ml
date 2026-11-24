module Persistence = Keeper_event_queue_persistence

module Owner_identity = struct
  type t = Persistence.owner_identity

  let equal = Persistence.owner_identity_equal
  let hash = Persistence.owner_identity_hash
end

module Owner_claims = Hashtbl.Make (Owner_identity)
module String_map = Map.Make (String)
module String_set = Set.Make (String)

type projection_outcome =
  | No_pending_transition
  | Transition_converged
  | Claim_busy

type projection_error =
  | Owner_unavailable of Persistence.owner_identity_error
  | Owner_shutdown_reserved of Keeper_shutdown_types.Operation_id.t
  | Executor_unavailable of Executor_pool_ref.strict_submit_error
  | Outbox_unavailable of string
  | Target_transfer_projection_failed of
      { target_keeper : string
      ; detail : string
      }
  | Paused_transfer_target_projection_failed of
      { target_keeper : string
      ; cause : Keeper_paused_work_transfer_transaction.failure
      }
  | Ledger_projection_failed of string
  | Unexpected_projection_failure of Eio.Exn.with_bt

type discovery_error =
  | Durable_state_discovery_failed of string
  | Sweep_execution_failed of Eio.Exn.with_bt
  | Sweep_executor_unavailable of Executor_pool_ref.strict_submit_error

type owner_failure =
  { keeper_name : string
  ; error : projection_error
  }

type owner_budget_error = Invalid_owner_budget of int
type owner_budget = Owner_budget of int

type owner_resume =
  { owner : Persistence.owner_identity
  ; unvisited : String_set.t
  }

type sweep_cursor =
  { after_keeper : string option
  ; unfinished : owner_resume String_map.t
  }

type owner_projection =
  { keeper_name : string
  ; outcome : (projection_outcome, projection_error) result
  }

type sweep_report =
  { discovered : int
  ; processed : int
  ; deferred : int
  ; no_pending : int
  ; converged : int
  ; claim_busy : int
  ; shutdown_reserved : int
  ; projections : owner_projection list
  ; failures : owner_failure list
  ; discovery_error : discovery_error option
  }

type sweep_page =
  { report : sweep_report
  ; next_cursor : sweep_cursor
  }

let projection_error_to_string = function
  | Owner_unavailable error ->
    Persistence.owner_identity_error_to_string error
  | Owner_shutdown_reserved operation_id ->
    Printf.sprintf
      "event queue transition owner shutdown reserved operation=%s"
      (Keeper_shutdown_types.Operation_id.to_string operation_id)
  | Executor_unavailable error ->
    "event queue transition executor unavailable: "
    ^ Executor_pool_ref.strict_submit_error_to_string error
  | Outbox_unavailable detail ->
    "event queue transition outbox unavailable: " ^ detail
  | Target_transfer_projection_failed { target_keeper; detail } ->
    Printf.sprintf
      "event queue transfer target projection failed target_keeper=%s: %s"
      target_keeper
      detail
  | Paused_transfer_target_projection_failed { target_keeper; cause } ->
    Printf.sprintf
      "paused-work transfer target projection failed target_keeper=%s: %s"
      target_keeper
      (Keeper_paused_work_transfer_transaction.error_to_string
         { cause; reservation_release = None })
  | Ledger_projection_failed detail ->
    "event queue transition ledger projection failed: " ^ detail
  | Unexpected_projection_failure (exn, backtrace) ->
    Printf.sprintf
      "event queue transition projection raised: %s\n%s"
      (Printexc.to_string exn)
      (Printexc.raw_backtrace_to_string backtrace)
;;

let discovery_error_to_string = function
  | Durable_state_discovery_failed detail ->
    "durable event queue state discovery failed: " ^ detail
  | Sweep_execution_failed (exn, backtrace) ->
    Printf.sprintf
      "durable event queue state sweep raised: %s\n%s"
      (Printexc.to_string exn)
      (Printexc.raw_backtrace_to_string backtrace)
  | Sweep_executor_unavailable error ->
    "durable event queue state sweep executor unavailable: "
    ^ Executor_pool_ref.strict_submit_error_to_string error
;;

let owner_budget_error_to_string (Invalid_owner_budget max_owners) =
  Printf.sprintf
    "event queue transition projection owner budget must be positive (got %d)"
    max_owners
;;

let owner_budget ~max_owners =
  if max_owners > 0
  then Ok (Owner_budget max_owners)
  else Error (Invalid_owner_budget max_owners)
;;

let initial_sweep_cursor = { after_keeper = None; unfinished = String_map.empty }

let owner_claims = Owner_claims.create 16
let owner_claims_mutex = Mutex.create ()

let with_owner_claims_lock f =
  Mutex.lock owner_claims_mutex;
  Fun.protect ~finally:(fun () -> Mutex.unlock owner_claims_mutex) f
;;

let try_acquire_owner_claim owner =
  with_owner_claims_lock (fun () ->
    if Owner_claims.mem owner_claims owner
    then false
    else (
      Owner_claims.add owner_claims owner ();
      true))
;;

let release_owner_claim owner =
  with_owner_claims_lock (fun () -> Owner_claims.remove owner_claims owner)
;;

type 'a owner_claim_outcome =
  | Owner_claim_acquired of 'a
  | Owner_claim_busy

let with_owner_claim owner f =
  if not (try_acquire_owner_claim owner)
  then Owner_claim_busy
  else
    Fun.protect
      ~finally:(fun () -> release_owner_claim owner)
      (fun () -> Owner_claim_acquired (f ()))
;;

let wake_transfer_target ~base_path target_keeper =
  ignore
    (Keeper_registry.wakeup_running
       ~intent:Keeper_registry.Broadcast_signal
       ~base_path
       target_keeper :
       Keeper_registry.wakeup_outcome)
;;

let project_generic_transfer_target_result
      ~target_intake_token
      ~base_path
      (transfer : Keeper_registry_event_queue.accepted_transfer)
  =
  match
    Keeper_registry_event_queue.project_accepted_transfer_durable_result
      ~intake_token:target_intake_token
      ~base_path
      transfer.to_keeper
      ~transfer
  with
  | Keeper_registry_event_queue.Transfer_projection_committed
  | Keeper_registry_event_queue.Transfer_projection_already_committed ->
    wake_transfer_target ~base_path transfer.to_keeper;
    Ok ()
  | Keeper_registry_event_queue.Transfer_projection_storage_error detail ->
    Error
      (Target_transfer_projection_failed
         { target_keeper = transfer.to_keeper; detail })
  | Keeper_registry_event_queue.Transfer_projection_target_unavailable error ->
    Error
      (Target_transfer_projection_failed
         { target_keeper = transfer.to_keeper
         ; detail = Keeper_registry_event_queue.transfer_target_error_to_string error
         })
  | Keeper_registry_event_queue.Transfer_projection_shutdown_reserved operation_id ->
    Error
      (Target_transfer_projection_failed
         { target_keeper = transfer.to_keeper
         ; detail =
             Printf.sprintf
               "target Keeper shutdown owns durable intake operation=%s"
               (Keeper_shutdown_types.Operation_id.to_string operation_id)
         })
;;

let project_transfer_target_result
      ~target_intake_token
      ~base_path
      (entry : Persistence.outbox_entry)
  =
  match entry.receipt.transition with
  | Persistence.Cancel_accepted _
  | Persistence.Ack_source_terminal _ ->
    Ok ()
  | Persistence.Transfer_accepted transfer ->
    (match
       Keeper_paused_work_transfer_transaction.project_committed_target_if_receipted
         ~intake_token:target_intake_token
         (Workspace.default_config base_path)
         ~transfer
     with
     | Ok None ->
       project_generic_transfer_target_result
         ~target_intake_token
         ~base_path
         transfer
     | Ok (Some _) ->
       wake_transfer_target ~base_path transfer.to_keeper;
       Ok ()
     | Error cause ->
       Error
         (Paused_transfer_target_projection_failed
            { target_keeper = transfer.to_keeper; cause }))
;;

(* Bound one recovery drain pass so a deep transition outbox cannot pin
   [Executor_pool_ref] / [owner_claims] indefinitely in a single turn. *)
let max_drain_entries_per_pass = 64

let outbox_entry_id (entry : Persistence.outbox_entry) =
  entry.receipt.transition_id
;;

let project_claimed_owner owner ~unvisited =
  let base_path = Persistence.owner_identity_base_path owner in
  let keeper_name = Persistence.owner_identity_keeper_name owner in
  let project_open_owner ?target_intake_token ~expected_transition_id () =
    match Persistence.load_state_result ~base_path ~keeper_name with
    | Error detail -> Error (Outbox_unavailable detail)
    | Ok state ->
      (match
         List.find_opt
           (fun (entry : Persistence.outbox_entry) ->
              String.equal entry.receipt.transition_id expected_transition_id)
           (Keeper_event_queue_state.transition_outbox state)
       with
       | None -> Ok false
       | Some entry ->
         let project_target =
           match entry.receipt.transition, target_intake_token with
           | Persistence.Transfer_accepted _, Some target_intake_token ->
             project_transfer_target_result
               ~target_intake_token
               ~base_path
               entry
           | Persistence.Transfer_accepted _, None ->
             Error
               (Outbox_unavailable
                  "transfer recovery entered without its ordered target intake fence")
           | (Persistence.Cancel_accepted _ | Persistence.Ack_source_terminal _), _ ->
             Ok ()
         in
         (match project_target with
          | Error _ as error -> error
          | Ok () ->
            (match
               Keeper_reaction_ledger.project_event_queue_transition_outbox_result
                 ~base_path
                 ~keeper_name
                 ~expected_transition_id:entry.receipt.transition_id
             with
             | Ok () -> Ok true
             | Error detail -> Error (Ledger_projection_failed detail))))
  in
  let step (entry : Persistence.outbox_entry) =
    let transition_id = outbox_entry_id entry in
    match entry.receipt.transition with
    | Persistence.Transfer_accepted transfer ->
      (match
         Keeper_shutdown_intake_fence.run_transfer_intake_if_open
           ~base_path
           ~from_keeper:keeper_name
           ~to_keeper:transfer.to_keeper
           (fun ~source_intake_token:_ ~target_intake_token ->
              Schedule_store.with_ledger_lock
                (Workspace.default_config base_path)
                (fun () ->
                   project_open_owner ~target_intake_token
                     ~expected_transition_id:transition_id ()))
       with
       | Keeper_shutdown_intake_fence.Transfer_intake_committed result ->
         `Step result
       | Keeper_shutdown_intake_fence.Transfer_intake_source_shutdown_reserved
           operation_id ->
         `Source_shutdown (Owner_shutdown_reserved operation_id)
       | Keeper_shutdown_intake_fence.Transfer_intake_target_shutdown_reserved
           operation_id ->
         `Step (Error (Owner_shutdown_reserved operation_id)))
    | Persistence.Cancel_accepted _ | Persistence.Ack_source_terminal _ ->
      (match
         Keeper_shutdown_intake_fence.run_durable_intake_if_open
           ~base_path
           ~keeper_name
           (fun _source_intake_token ->
              project_open_owner ~expected_transition_id:transition_id ())
       with
       | Keeper_shutdown_intake_fence.Intake_committed result -> `Step result
       | Keeper_shutdown_intake_fence.Intake_shutdown_reserved operation_id ->
         `Source_shutdown (Owner_shutdown_reserved operation_id))
  in
  let rec drain ~budget ~first_error ~converged entries =
    match budget, entries with
    | 0, _ | _, [] ->
      let outcome =
        match first_error with
        | Some error -> Error error
        | None ->
          if converged then Ok Transition_converged else Ok No_pending_transition
      in
      outcome, entries
    | _, entry :: remaining ->
      (match step entry with
       | `Source_shutdown error -> Error error, entries
       | `Step (Ok applied) ->
         drain ~budget:(budget - 1) ~first_error
           ~converged:(applied || converged) remaining
       | `Step (Error error) ->
         let first_error =
           match first_error with
           | Some _ -> first_error
           | None -> Some error
         in
         drain ~budget:(budget - 1) ~first_error ~converged remaining)
  in
  match Persistence.load_state_result ~base_path ~keeper_name with
  | Error detail -> Error (Outbox_unavailable detail), unvisited
  | Ok state ->
    let pending = Keeper_event_queue_state.transition_outbox state in
    (* Use the current durable order and drop ids another projector retired.
       Once the saved suffix is exhausted, the next pass retries blocked
       entries and includes transitions appended after this round began. *)
    let entries =
      match
        List.filter
          (fun entry -> String_set.mem (outbox_entry_id entry) unvisited)
          pending
      with
      | [] -> pending
      | remaining -> remaining
    in
    let outcome, remaining =
      drain
        ~budget:max_drain_entries_per_pass
        ~first_error:None
        ~converged:false
        entries
    in
    let unvisited =
      List.fold_left
        (fun ids entry -> String_set.add (outbox_entry_id entry) ids)
        String_set.empty
        remaining
    in
    outcome, unvisited
;;

let project_resolved_owner owner ~resume =
  let unvisited =
    match resume with
    | Some prior when Owner_identity.equal owner prior.owner -> prior.unvisited
    | _ -> String_set.empty
  in
  match
    with_owner_claim owner (fun () ->
      try project_claimed_owner owner ~unvisited with
      | Eio.Cancel.Cancelled _ as exn ->
        let backtrace = Printexc.get_raw_backtrace () in
        Printexc.raise_with_backtrace exn backtrace
      | exn ->
        let backtrace = Printexc.get_raw_backtrace () in
        Error (Unexpected_projection_failure (exn, backtrace)), unvisited)
  with
  | Owner_claim_busy -> Ok Claim_busy, resume
  | Owner_claim_acquired (outcome, unvisited) ->
    let resume =
      if String_set.is_empty unvisited then None else Some { owner; unvisited }
    in
    outcome, resume
;;

let project_owner_result_inline ~base_path ~keeper_name ~resume =
  match Persistence.resolve_owner_identity ~base_path ~keeper_name with
  | Error error -> Error (Owner_unavailable error), resume
  | Ok owner -> project_resolved_owner owner ~resume
;;

let project_owner_result ~base_path ~keeper_name =
  match
    Executor_pool_ref.submit_strict ~name:__FUNCTION__ (fun () ->
      project_owner_result_inline ~base_path ~keeper_name ~resume:None |> fst)
  with
  | Ok outcome -> outcome
  | Error (Executor_pool_ref.Work_failed failure) ->
    Error (Unexpected_projection_failure failure)
  | Error
      ((Executor_pool_ref.Pool_unavailable
       | Executor_pool_ref.Caller_not_in_eio
       | Executor_pool_ref.Submission_failed _) as error) ->
    Error (Executor_unavailable error)
;;

let ordered_owner_page ~budget:(Owner_budget max_owners) ~after_keeper names =
  let names = List.sort_uniq String.compare names in
  let ordered =
    match after_keeper with
    | None -> names
    | Some after ->
      let later, earlier =
        List.partition (fun keeper_name -> String.compare keeper_name after > 0) names
      in
      later @ earlier
  in
  let rec take remaining acc = function
    | _ when remaining = 0 -> List.rev acc
    | [] -> List.rev acc
    | keeper_name :: rest -> take (remaining - 1) (keeper_name :: acc) rest
  in
  let selected = take max_owners [] ordered in
  let deferred = List.length names - List.length selected in
  let after_keeper =
    if deferred = 0
    then None
    else
      match List.rev selected with
      | [] -> None
      | keeper_name :: _ -> Some keeper_name
  in
  names, selected, deferred, after_keeper
;;

let project_discovery_inline
    ~base_path
    ~budget
    ~cursor
    (discovery : Persistence.durable_state_discovery) =
  let names, selected, deferred, after_keeper =
    ordered_owner_page ~budget ~after_keeper:cursor.after_keeper discovery.keeper_names
  in
  let unfinished =
    match discovery.read_error with
    | Some _ -> cursor.unfinished
    | None ->
      let discovered = String_set.of_list names in
      String_map.filter
        (fun keeper_name _ -> String_set.mem keeper_name discovered)
        cursor.unfinished
  in
  let initial =
    { discovered = List.length names
    ; processed = List.length selected
    ; deferred
    ; no_pending = 0
    ; converged = 0
    ; claim_busy = 0
    ; shutdown_reserved = 0
    ; projections = []
    ; failures = []
    ; discovery_error =
        Option.map
          (fun detail -> Durable_state_discovery_failed detail)
          discovery.read_error
    }
  in
  let unfinished, report =
    List.fold_left
      (fun (unfinished, report) keeper_name ->
         let resume = String_map.find_opt keeper_name unfinished in
         let outcome, resume =
           project_owner_result_inline ~base_path ~keeper_name ~resume
         in
         let unfinished =
           match resume with
           | None -> String_map.remove keeper_name unfinished
           | Some resume -> String_map.add keeper_name resume unfinished
         in
         let report =
           { report with
             projections = { keeper_name; outcome } :: report.projections
           }
         in
         let report =
           match outcome with
           | Ok No_pending_transition ->
             { report with no_pending = report.no_pending + 1 }
           | Ok Transition_converged ->
             { report with converged = report.converged + 1 }
           | Ok Claim_busy ->
             { report with claim_busy = report.claim_busy + 1 }
           | Error (Owner_shutdown_reserved _) ->
             { report with shutdown_reserved = report.shutdown_reserved + 1 }
           | Error
               (( Owner_unavailable _
                | Executor_unavailable _
                | Outbox_unavailable _
                | Target_transfer_projection_failed _
                | Paused_transfer_target_projection_failed _
                | Ledger_projection_failed _
                | Unexpected_projection_failure _ ) as error) ->
             { report with
               failures = { keeper_name; error } :: report.failures
             }
         in
         unfinished, report)
      (unfinished, initial)
      selected
  in
  { report =
      { report with
        projections = List.rev report.projections
      ; failures = List.rev report.failures
      }
  ; next_cursor = { after_keeper; unfinished }
  }
;;

let project_discovered_bounded ~base_path ~budget ~cursor =
  match
    Executor_pool_ref.submit_strict ~name:__FUNCTION__ (fun () ->
      let discovery =
        Keeper_event_queue_persistence.discover_keeper_names_with_durable_state
          ~base_path
      in
      project_discovery_inline ~base_path ~budget ~cursor discovery)
  with
  | Ok page -> page
  | Error error ->
    let discovery_error =
      match error with
      | Executor_pool_ref.Work_failed failure ->
        Sweep_execution_failed failure
      | (Executor_pool_ref.Pool_unavailable | Executor_pool_ref.Caller_not_in_eio | Executor_pool_ref.Submission_failed _) as error -> Sweep_executor_unavailable error
    in
    { report =
        { discovered = 0
        ; processed = 0
        ; deferred = 0
        ; no_pending = 0
        ; converged = 0
        ; claim_busy = 0
        ; shutdown_reserved = 0
        ; projections = []
        ; failures = []
        ; discovery_error = Some discovery_error
        }
    ; next_cursor = cursor
    }
;;
