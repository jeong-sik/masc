module Persistence = Keeper_event_queue_persistence

module Owner_identity = struct
  type t = Persistence.owner_identity

  let equal = Persistence.owner_identity_equal
  let hash = Persistence.owner_identity_hash
end

module Owner_claims = Hashtbl.Make (Owner_identity)

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
type sweep_cursor = Sweep_cursor of string option

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

let initial_sweep_cursor = Sweep_cursor None

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

let project_claimed_owner owner =
  let base_path = Persistence.owner_identity_base_path owner in
  let keeper_name = Persistence.owner_identity_keeper_name owner in
  let project_open_owner ?target_intake_token () =
    match Persistence.load_state_result ~base_path ~keeper_name with
    | Error detail -> Error (Outbox_unavailable detail)
    | Ok state ->
      (match Keeper_event_queue_state.transition_outbox state with
       | [] -> Ok No_pending_transition
       | entry :: _ ->
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
             | Ok () -> Ok Transition_converged
             | Error detail -> Error (Ledger_projection_failed detail))))
  in
  match Persistence.load_state_result ~base_path ~keeper_name with
  | Error detail -> Error (Outbox_unavailable detail)
  | Ok state ->
    (match Keeper_event_queue_state.transition_outbox state with
     | { receipt = { transition = Persistence.Transfer_accepted transfer; _ }; _ }
       :: _ ->
       (match
          Keeper_shutdown_intake_fence.run_transfer_intake_if_open
            ~base_path
            ~from_keeper:keeper_name
            ~to_keeper:transfer.to_keeper
            (fun ~source_intake_token:_ ~target_intake_token ->
               project_open_owner ~target_intake_token ())
        with
        | Keeper_shutdown_intake_fence.Transfer_intake_committed result -> result
        | Keeper_shutdown_intake_fence.Transfer_intake_source_shutdown_reserved operation_id
        | Keeper_shutdown_intake_fence.Transfer_intake_target_shutdown_reserved operation_id ->
          Error (Owner_shutdown_reserved operation_id))
     | []
     | { receipt =
           { transition =
               (Persistence.Cancel_accepted _ | Persistence.Ack_source_terminal _)
           ; _
           }
       ; _
       }
       :: _ ->
       (match
          Keeper_shutdown_intake_fence.run_durable_intake_if_open
            ~base_path
            ~keeper_name
            (fun _source_intake_token -> project_open_owner ())
        with
        | Keeper_shutdown_intake_fence.Intake_committed result -> result
        | Keeper_shutdown_intake_fence.Intake_shutdown_reserved operation_id ->
          Error (Owner_shutdown_reserved operation_id)))
;;

let project_resolved_owner owner =
  match
    with_owner_claim owner (fun () ->
      try project_claimed_owner owner with
      | Eio.Cancel.Cancelled _ as exn ->
        let backtrace = Printexc.get_raw_backtrace () in
        Printexc.raise_with_backtrace exn backtrace
      | exn ->
        let backtrace = Printexc.get_raw_backtrace () in
        Error (Unexpected_projection_failure (exn, backtrace)))
  with
  | Owner_claim_busy -> Ok Claim_busy
  | Owner_claim_acquired result -> result
;;

let project_owner_result_inline ~base_path ~keeper_name =
  match Persistence.resolve_owner_identity ~base_path ~keeper_name with
  | Error error -> Error (Owner_unavailable error)
  | Ok owner -> project_resolved_owner owner
;;

let project_owner_result ~base_path ~keeper_name =
  match
    Executor_pool_ref.submit_strict (fun () ->
      project_owner_result_inline ~base_path ~keeper_name)
  with
  | Ok outcome -> outcome
  | Error (Executor_pool_ref.Work_failed failure) ->
    Error (Unexpected_projection_failure failure)
  | Error error -> Error (Executor_unavailable error)
;;

let ordered_owner_page ~budget:(Owner_budget max_owners) ~cursor:(Sweep_cursor cursor) names =
  let names = List.sort_uniq String.compare names in
  let ordered =
    match cursor with
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
  let next_cursor =
    if deferred = 0
    then initial_sweep_cursor
    else
      match List.rev selected with
      | [] -> initial_sweep_cursor
      | keeper_name :: _ -> Sweep_cursor (Some keeper_name)
  in
  names, selected, deferred, next_cursor
;;

let project_discovery_inline
    ~base_path
    ~budget
    ~cursor
    (discovery : Persistence.durable_state_discovery) =
  let names, selected, deferred, next_cursor =
    ordered_owner_page ~budget ~cursor discovery.keeper_names
  in
  let initial =
    { discovered = List.length names
    ; processed = List.length selected
    ; deferred
    ; no_pending = 0
    ; converged = 0
    ; claim_busy = 0
    ; projections = []
    ; failures = []
    ; discovery_error =
        Option.map
          (fun detail -> Durable_state_discovery_failed detail)
          discovery.read_error
    }
  in
  let report =
    List.fold_left
      (fun report keeper_name ->
         let outcome = project_owner_result_inline ~base_path ~keeper_name in
         let report =
           { report with
             projections = { keeper_name; outcome } :: report.projections
           }
         in
         match outcome with
         | Ok No_pending_transition ->
           { report with no_pending = report.no_pending + 1 }
         | Ok Transition_converged ->
           { report with converged = report.converged + 1 }
         | Ok Claim_busy ->
           { report with claim_busy = report.claim_busy + 1 }
         | Error error ->
           { report with
             failures = { keeper_name; error } :: report.failures
           })
      initial
      selected
  in
  { report =
      { report with
        projections = List.rev report.projections
      ; failures = List.rev report.failures
      }
  ; next_cursor
  }
;;

let project_discovered_bounded ~base_path ~budget ~cursor =
  match
    Executor_pool_ref.submit_strict (fun () ->
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
      | error -> Sweep_executor_unavailable error
    in
    { report =
        { discovered = 0
        ; processed = 0
        ; deferred = 0
        ; no_pending = 0
        ; converged = 0
        ; claim_busy = 0
        ; projections = []
        ; failures = []
        ; discovery_error = Some discovery_error
        }
    ; next_cursor = cursor
    }
;;

module For_testing = struct
  type 'a claim_outcome =
    | Claim_acquired of 'a
    | Claim_already_held

end
