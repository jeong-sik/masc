module Candidate = Keeper_board_attention_candidate
module Exact_flow = Keeper_board_attention_exact_flow
module Partition = Keeper_board_attention_partition
module Wake = Keeper_board_attention_worker_wake

type contention =
  { keeper_name : string
  ; partition_id : string
  ; generation : Partition.Generation.t
  }

type step =
  | Idle
  | Contended of contention
  | Rescan_later of contention
  | Judgment_completed of
      { candidate_id : string
      ; owner_wake : Keeper_registry.exact_wakeup_outcome
      }
  | Candidate_already_consumed of { candidate_id : string }
  | Partition_blocked of
      { candidate_id : string
      ; reason : Partition.blocked_reason
      }

type retry_reason =
  | Exact_claim_contended
  | Selected_generation_changed

(* What the drain loop actually did before it stopped. A wake that finds an
   empty partition returns the same verdict as one that judged twenty
   candidates, so without these counts the log line cannot tell an operator
   whether the worker did any work: the two hours to 2026-08-22T02:03Z held
   120 pairs of textually identical [outcome=drained] lines, each pair a real
   drain followed by a wake that found nothing left. *)
type drain_progress =
  { judgments : int
      (* Candidates that produced a judgment on this drain. *)
  ; steps : int
      (* Loop iterations, including visits that found the candidate already
         consumed or its partition blocked. *)
  }

type drain_outcome =
  | Drained of drain_progress
  | Retry_later of
      { contention : contention
      ; reason : retry_reason
      ; progress : drain_progress
      }

type rearm_schedule =
  | Rearm_scheduled of { delay_s : float }
  | Rearm_deduplicated of { delay_s : float }

type rearm_ticket =
  { ticket_id : int
  ; delay_s : float
  }

type rearm_entry =
  { key : contention
  ; mutable next_delay_s : float
  ; mutable pending : rearm_ticket option
  ; mutable inflight : rearm_ticket option
  }

type rearm_scheduler =
  { mutex : Stdlib.Mutex.t
  ; fork : (unit -> unit) -> unit
  ; sleep : float -> unit
  ; request : unit -> (Wake.wake_result, string) result
  ; mutable next_ticket_id : int
  ; mutable entries : rearm_entry list
  }

let contention_rearm_base_delay_s = 0.05
let contention_rearm_max_delay_s = 5.0

let contention_equal (left : contention) (right : contention) =
  String.equal left.keeper_name right.keeper_name
  && String.equal left.partition_id right.partition_id
  && Partition.Generation.equal left.generation right.generation
;;

let contention_generation_label (contention : contention) =
  contention.generation
  |> Partition.Generation.to_yojson
  |> Yojson.Safe.to_string
;;

type contention_rearm_outcome =
  | Outcome_pending
  | Outcome_inflight
  | Outcome_scheduled
  | Outcome_stale_ticket
  | Outcome_signaled
  | Outcome_coalesced
  | Outcome_not_registered
  | Outcome_delivery_error
  | Outcome_delivery_reset
  | Outcome_delivery_retry
  | Outcome_sleep_cancelled
  | Outcome_fork_cancelled
  | Outcome_reset
  | Outcome_history_removed

let contention_rearm_outcome_label = function
  | Outcome_pending -> "pending"
  | Outcome_inflight -> "inflight"
  | Outcome_scheduled -> "scheduled"
  | Outcome_stale_ticket -> "stale_ticket"
  | Outcome_signaled -> "signaled"
  | Outcome_coalesced -> "coalesced"
  | Outcome_not_registered -> "not_registered"
  | Outcome_delivery_error -> "delivery_error"
  | Outcome_delivery_reset -> "delivery_reset"
  | Outcome_delivery_retry -> "delivery_retry"
  | Outcome_sleep_cancelled -> "sleep_cancelled"
  | Outcome_fork_cancelled -> "fork_cancelled"
  | Outcome_reset -> "reset"
  | Outcome_history_removed -> "history_removed"
;;

let log_contention_rearm event (contention : contention) ~delay_s ~outcome =
  let write =
    match outcome with
    | Outcome_delivery_error
    | Outcome_not_registered -> Log.Keeper.warn
    | Outcome_pending
    | Outcome_inflight
    | Outcome_scheduled
    | Outcome_stale_ticket
    | Outcome_signaled
    | Outcome_coalesced
    | Outcome_delivery_reset
    | Outcome_delivery_retry
    | Outcome_sleep_cancelled
    | Outcome_fork_cancelled
    | Outcome_reset
    | Outcome_history_removed -> Log.Keeper.info
  in
  write
    "board_attention_claim_contention event=%s keeper=%s partition=%s generation=%s delay_ms=%d outcome=%s"
    event
    contention.keeper_name
    contention.partition_id
    (contention_generation_label contention)
    (int_of_float (delay_s *. 1000.0))
    (contention_rearm_outcome_label outcome)
;;

let find_rearm_entry scheduler contention =
  List.find_opt
    (fun entry -> contention_equal entry.key contention)
    scheduler.entries
;;

let prepare_rearm_ticket_locked scheduler entry =
  let ticket =
    { ticket_id = scheduler.next_ticket_id
    ; delay_s = entry.next_delay_s
    }
  in
  scheduler.next_ticket_id <- scheduler.next_ticket_id + 1;
  entry.next_delay_s <-
    Float.min contention_rearm_max_delay_s (entry.next_delay_s *. 2.0);
  entry.pending <- Some ticket;
  ticket
;;

let cancel_rearm_ticket scheduler contention ticket outcome =
  let cancelled =
    Stdlib.Mutex.protect scheduler.mutex (fun () ->
      match find_rearm_entry scheduler contention with
      | Some entry ->
        (match entry.pending with
         | Some current when Int.equal current.ticket_id ticket.ticket_id ->
           entry.pending <- None;
           true
         | Some _ | None -> false)
      | None -> false)
  in
  if cancelled
  then log_contention_rearm "cancelled" contention ~delay_s:ticket.delay_s ~outcome
;;

let wake_result_outcome = function
  | Wake.Signaled -> Outcome_signaled
  | Wake.Coalesced -> Outcome_coalesced
  | Wake.Not_registered -> Outcome_not_registered
;;

let fire_rearm_ticket scheduler contention ticket ~launch_delivery_retry =
  let consumed =
    Stdlib.Mutex.protect scheduler.mutex (fun () ->
      match find_rearm_entry scheduler contention with
      | Some entry ->
        (match entry.pending, entry.inflight with
         | Some current, None when Int.equal current.ticket_id ticket.ticket_id ->
           entry.pending <- None;
           entry.inflight <- Some ticket;
           true
         | Some _, (Some _ | None)
         | None, (Some _ | None) -> false)
      | None -> false)
  in
  if not consumed
  then
    log_contention_rearm
      "cancelled"
      contention
      ~delay_s:ticket.delay_s
      ~outcome:Outcome_stale_ticket
  else
    let delivery = scheduler.request () in
    let completion =
      Stdlib.Mutex.protect scheduler.mutex (fun () ->
        match find_rearm_entry scheduler contention with
        | Some entry ->
          (match entry.inflight with
           | Some current when Int.equal current.ticket_id ticket.ticket_id ->
             entry.inflight <- None;
             (match delivery with
              | Ok wake -> `Delivered wake
              | Error _ ->
                `Retry (prepare_rearm_ticket_locked scheduler entry))
           | Some _ | None -> `Suppressed)
        | None -> `Suppressed)
    in
    match completion with
    | `Delivered wake ->
      log_contention_rearm
        "fired"
        contention
        ~delay_s:ticket.delay_s
        ~outcome:(wake_result_outcome wake)
    | `Retry next_ticket ->
      log_contention_rearm
        "fired"
        contention
        ~delay_s:ticket.delay_s
        ~outcome:Outcome_delivery_error;
      launch_delivery_retry next_ticket
    | `Suppressed ->
      log_contention_rearm
        "cancelled"
        contention
        ~delay_s:ticket.delay_s
        ~outcome:Outcome_delivery_reset
;;

let make_contention_rearm_scheduler ~fork ~sleep ~request () =
  { mutex = Stdlib.Mutex.create ()
  ; fork
  ; sleep
  ; request
  ; next_ticket_id = 0
  ; entries = []
  }
;;

let schedule_contention_rearm scheduler contention =
  let decision =
    Stdlib.Mutex.protect scheduler.mutex (fun () ->
      let entry =
        match find_rearm_entry scheduler contention with
        | Some entry -> entry
        | None ->
          let entry =
            { key = contention
            ; next_delay_s = contention_rearm_base_delay_s
            ; pending = None
            ; inflight = None
            }
          in
          scheduler.entries <- entry :: scheduler.entries;
          entry
      in
      match entry.pending, entry.inflight with
      | Some ticket, (Some _ | None) ->
        `Deduplicated (ticket.delay_s, Outcome_pending)
      | None, Some ticket ->
        `Deduplicated (ticket.delay_s, Outcome_inflight)
      | None, None ->
        `Scheduled (prepare_rearm_ticket_locked scheduler entry))
  in
  match decision with
  | `Deduplicated (delay_s, outcome) ->
    log_contention_rearm
      "deduplicated"
      contention
      ~delay_s
      ~outcome;
    Rearm_deduplicated { delay_s }
  | `Scheduled ticket ->
    let rec launch ticket =
      (try
         scheduler.fork (fun () ->
           (try scheduler.sleep ticket.delay_s with
            | exn ->
              cancel_rearm_ticket
                scheduler
                contention
                ticket
                Outcome_sleep_cancelled;
              raise exn);
           fire_rearm_ticket
             scheduler
             contention
             ticket
             ~launch_delivery_retry:(fun next_ticket ->
               launch next_ticket;
               log_contention_rearm
                 "scheduled"
                 contention
                 ~delay_s:next_ticket.delay_s
                 ~outcome:Outcome_delivery_retry))
       with
       | exn ->
         cancel_rearm_ticket scheduler contention ticket Outcome_fork_cancelled;
         raise exn)
    in
    launch ticket;
    log_contention_rearm
      "scheduled"
      contention
      ~delay_s:ticket.delay_s
      ~outcome:Outcome_scheduled;
    Rearm_scheduled { delay_s = ticket.delay_s }
;;

let reset_contention_rearms scheduler ~keep =
  let removed =
    Stdlib.Mutex.protect scheduler.mutex (fun () ->
      let retained, removed =
        List.partition
          (fun entry ->
             match keep with
             | Some contention -> contention_equal entry.key contention
             | None -> false)
          scheduler.entries
      in
      scheduler.entries <- retained;
      removed)
  in
  List.iter
    (fun entry ->
       match entry.pending, entry.inflight with
       | Some ticket, (Some _ | None)
       | None, Some ticket ->
         log_contention_rearm
           "cancelled"
           entry.key
           ~delay_s:ticket.delay_s
           ~outcome:Outcome_reset
       | None, None ->
         log_contention_rearm
           "reset"
           entry.key
           ~delay_s:0.0
           ~outcome:Outcome_history_removed)
    removed
;;

(* The drain verdict as one token. Retry_later carries its reason so a stuck
   worker is distinguishable from a contended one: Exact_claim_contended means
   another flow holds the claim, Selected_generation_changed means the partition
   moved under this worker. *)
let drain_outcome_label = function
  | Drained _ -> "drained"
  | Retry_later { reason = Exact_claim_contended; _ } -> "retry_claim_contended"
  | Retry_later { reason = Selected_generation_changed; _ } ->
    "retry_generation_changed"
;;

(* The drain line derives its level from the outcome it reports. [Retry_later]
   leaves the durable partition undrained and re-arms the same contention, so a
   worker that keeps returning it makes no progress while its candidate ledger
   grows; at [Info] that state reads the same as normal draining. *)
let drain_outcome_log_level = function
  | Drained _ -> Log.Info
  | Retry_later _ -> Log.Warn
;;

let drain_outcome_progress = function
  | Drained progress -> progress
  | Retry_later { progress; _ } -> progress
;;

let apply_drain_rearm scheduler = function
  | Drained _ ->
    reset_contention_rearms scheduler ~keep:None;
    None
  | Retry_later { contention; reason = _ } ->
    reset_contention_rearms scheduler ~keep:(Some contention);
    Some (schedule_contention_rearm scheduler contention)
;;

type settlement =
  | No_completed_partition
  | Partition_settled of
      { candidate_id : string
      ; continuation_wake : Keeper_registry.wakeup_outcome option
      }

type fatal_stage =
  | Registration
  | Process_start_recovery
  | Durable_drain
  | Control_loop

type fatal_error =
  { stage : fatal_stage
  ; detail : string
  }

let fatal_stage_to_string = function
  | Registration -> "registration"
  | Process_start_recovery -> "process_start_recovery"
  | Durable_drain -> "durable_drain"
  | Control_loop -> "control_loop"
;;

let fatal_error_to_string error =
  Printf.sprintf
    "Board attention worker fatal stage=%s detail=%s"
    (fatal_stage_to_string error.stage)
    error.detail
;;

let ( let* ) = Result.bind

let owner_wake ~base_path ~keeper_name =
  Keeper_registry.wakeup_running
    ~intent:Keeper_registry.Attention_result
    ~base_path
    keeper_name
;;

let exact_owner_wake ~base_path ~keeper_name =
  match Keeper_registry.get ~base_path keeper_name with
  | None -> Keeper_registry.Exact_wake_missing
  | Some entry ->
    Keeper_registry.wakeup_running_exact
      ~intent:Keeper_registry.Attention_result
      entry
;;

let candidate_by_id candidate_id candidates =
  List.find_opt
    (fun (candidate : Candidate.candidate) ->
       String.equal candidate.candidate_id candidate_id)
    candidates
;;

let validate_partition_member partition candidate =
  if not (String.equal partition.Partition.keeper_name candidate.Candidate.keeper_name)
  then Error "partition member Keeper identity changed"
  else if not (Float.equal partition.created_at candidate.recorded_at)
  then Error "partition member recorded_at changed"
  else
    let* context_key = Candidate.Context_key.of_candidate candidate in
    if Candidate.Context_key.equal partition.context_key context_key
    then Ok ()
    else Error "partition member Keeper context changed"
;;

let confirm_blocked_transition ~base_path transition =
  match transition.Partition.write_outcome with
  | Partition.Fsync_completed -> Ok transition.partition
  | Partition.Visible_sync_unconfirmed _ ->
    let* confirmed =
      Partition.confirm_blocked ~base_path ~partition:transition.partition
    in
    (match confirmed.write_outcome with
     | Partition.Fsync_completed -> Ok confirmed.partition
     | Partition.Visible_sync_unconfirmed detail ->
       Error ("Blocked partition fsync remains unconfirmed: " ^ detail))
;;

let failure_category_of_reason = function
  | Partition.Candidate_membership_conflict _ ->
    Candidate.Candidate_membership_conflict
  | Partition.Durable_partition_invariant _ ->
    Candidate.Durable_partition_invariant
  | Partition.Exact_setup_unavailable _ -> Candidate.Exact_setup_unavailable
  | Partition.Exact_flow_replayed -> Candidate.Exact_flow_replayed
  | Partition.Exact_execution_terminal -> Candidate.Exact_execution_terminal
  | Partition.Domain_output_invalid _ -> Candidate.Domain_output_invalid
  | Partition.Execution_provenance_mismatch _ ->
    Candidate.Execution_provenance_mismatch
  | Partition.Unexpected_worker_failure _ ->
    Candidate.Unexpected_worker_failure
  | Partition.Exact_execution_quarantined _ ->
    Candidate.Exact_execution_quarantined
;;

let candidate_provenance (provenance : Partition.exact_provenance) :
    Candidate.attempt_provenance
  =
  { slot_id = provenance.slot_id
  ; call_id = provenance.call_id
  ; plan_fingerprint = provenance.plan_fingerprint
  ; request_body_sha256 = provenance.request_body_sha256
  }
;;

let attempt_provenance_of_reason = function
  | Partition.Exact_execution_quarantined (Partition.Bound provenance) ->
    Some (candidate_provenance provenance)
  | Partition.Exact_execution_quarantined
      (Partition.Advancing
         { execution_anchor = Some failed; last_from = _; next = _ }) ->
    Some (candidate_provenance failed)
  | Partition.Exact_execution_quarantined
      (Partition.Advancing
         { execution_anchor = None; last_from = _; next = _ }) ->
    None
  | Partition.Exact_execution_quarantined Partition.Unbound
  | Partition.Candidate_membership_conflict _
  | Partition.Durable_partition_invariant _
  | Partition.Exact_setup_unavailable _
  | Partition.Exact_flow_replayed
  | Partition.Exact_execution_terminal
  | Partition.Domain_output_invalid _
  | Partition.Execution_provenance_mismatch _
  | Partition.Unexpected_worker_failure _ -> None
;;

let quarantine_blocked_partition ~base_path partition =
  match partition.Partition.state with
  | Partition.Blocked { reason; blocked_at } ->
    let* candidates =
      Candidate.load_candidates
        ~base_path
        ~keeper_name:partition.keeper_name
    in
    let* candidate =
      match
        List.find_opt
          (fun candidate ->
             String.equal candidate.Candidate.candidate_id partition.candidate_id)
          candidates
      with
      | Some candidate -> Ok candidate
      | None ->
        Error
          ("Blocked partition candidate is absent: "
           ^ partition.candidate_id)
    in
    Candidate.quarantine
      ~base_path
      ~candidate
      ~partition_id:partition.partition_id
      ~partition_generation:partition.generation
      ~failure_category:(failure_category_of_reason reason)
      ~attempt_provenance:(attempt_provenance_of_reason reason)
      ~quarantined_at:blocked_at
    |> Result.map ignore
  | Partition.Ready
  | Partition.Running _
  | Partition.Completed _
  | Partition.Settled _ ->
    Error ("partition is not Blocked: " ^ partition.partition_id)
;;

let blocked_step ~now ~worker_epoch ~base_path partition reason =
  let* transition =
    Partition.block
      ~now
      ~worker_epoch
      ~base_path
      ~partition
      reason
  in
  let* blocked = confirm_blocked_transition ~base_path transition in
  let* () = quarantine_blocked_partition ~base_path blocked in
  Ok (Partition_blocked { candidate_id = blocked.candidate_id; reason })
;;

let confirm_completed_transition
      ~base_path
      latest_partition
      operation
      (transition : Partition.exact_transition)
  =
  latest_partition := transition.partition;
  match transition.write_outcome with
  | Partition.Fsync_completed -> Ok transition.partition
  | Partition.Visible_sync_unconfirmed _ ->
    (match
       Partition.confirm_completed
         ~base_path
         ~partition:transition.partition
     with
     | Error detail -> Error (operation ^ " confirmation failed: " ^ detail)
     | Ok confirmed ->
       latest_partition := confirmed.partition;
       (match confirmed.write_outcome with
        | Partition.Fsync_completed -> Ok confirmed.partition
        | Partition.Visible_sync_unconfirmed detail ->
          Error
            (operation
             ^ " remained visible but fsync is unconfirmed after confirmation: "
             ^ detail)))
;;

let complete_partition ~now ~worker_epoch ~base_path latest_partition judgment =
  let item : Partition.completed_item =
    { candidate_id = (!latest_partition).Partition.candidate_id; judgment }
  in
  Partition.complete
    ~now
    ~worker_epoch
    ~base_path
    ~partition:!latest_partition
    ~item
;;

let running_progress partition =
  match partition.Partition.state with
  | Partition.Running { progress; _ } -> Some progress
  | Partition.Ready
  | Partition.Completed _
  | Partition.Settled _
  | Partition.Blocked _ -> None
;;

let preserve_durable_progress partition fallback =
  match running_progress partition with
  | Some ((Partition.Bound _ | Partition.Advancing _) as progress) ->
    Partition.Exact_execution_quarantined progress
  | Some Partition.Unbound | None -> fallback
;;

type completion_projection =
  | Completion_projected of Partition.t * Keeper_registry.registry_entry
  | Completion_blocked of step

let complete_projection
      ~now
      ~worker_epoch
      ~base_path
      latest_partition
      judgment
  =
  match
    complete_partition
      ~now
      ~worker_epoch
      ~base_path
      latest_partition
      judgment
  with
  | Ok transition ->
    let* completed =
      confirm_completed_transition
        ~base_path
        latest_partition
        "exact completion"
        transition
    in
    (match
       Keeper_registry.get
         ~base_path
         completed.Partition.keeper_name
     with
     | Some owner -> Ok (Completion_projected (completed, owner))
     | None ->
       Error
         ("exact completion lost its registered owner before projection: "
          ^ completed.keeper_name))
  | Error detail ->
    let reason =
      preserve_durable_progress
        !latest_partition
        (Partition.Durable_partition_invariant
           ("exact completion failed: " ^ detail))
    in
    blocked_step
      ~now
      ~worker_epoch
      ~base_path
      !latest_partition
      reason
    |> Result.map (fun step -> Completion_blocked step)
;;

let signal_completion = function
  | Completion_blocked step -> Ok step
  | Completion_projected (completed, owner) ->
    let owner_wake =
      Keeper_registry.wakeup_running_exact
        ~intent:Keeper_registry.Attention_result
        owner
    in
    Ok
      (Judgment_completed
         { candidate_id = completed.candidate_id; owner_wake })
;;

let partition_provenance
      (provenance : Exact_flow.attempt_provenance)
      : Partition.exact_provenance
  =
  { slot_id = provenance.slot_id
  ; call_id = provenance.call_id
  ; plan_fingerprint = provenance.plan_fingerprint
  ; request_body_sha256 = provenance.request_body_sha256
  }
;;

let partition_candidate_visit (visit : Exact_flow.candidate_visit) :
    Partition.candidate_visit
  =
  { flow_id = visit.flow_id
  ; ordinal = visit.ordinal
  ; slot_id = visit.slot_id
  ; catalog_generation_fingerprint = visit.catalog_generation_fingerprint
  ; catalog_evidence_sha256 = visit.catalog_evidence_sha256
  ; target_identity_fingerprint = visit.target_identity_fingerprint
  }
;;

let partition_advance_source = function
  | Exact_flow.Executed_failure provenance ->
    Partition.Executed_failure (partition_provenance provenance)
  | Exact_flow.Predispatch_rejection visit ->
    Partition.Predispatch_rejection (partition_candidate_visit visit)
;;

let setup_error_detail = function
  | Exact_flow.Network_unavailable -> "network context unavailable"
  | Exact_flow.Candidate_not_pending -> "candidate is no longer pending"
  | Exact_flow.Prompt_contract_unavailable detail ->
    "prompt contract unavailable: " ^ detail
  | Exact_flow.Registry_unavailable -> "runtime registry unavailable"
  | Exact_flow.Lane_unavailable -> "board exact lane unavailable"
  | Exact_flow.Lane_preference_unavailable detail ->
    "board exact lane preference unavailable: " ^ detail
  | Exact_flow.Lane_resolved_without_slots ->
    "board exact lane has no admitted slots"
  | Exact_flow.Candidate_invalid { position; slot_id = _ } ->
    Printf.sprintf "board exact lane slot %d has invalid identity" position
  | Exact_flow.Flow_snapshot_failed -> "AGENT_CORE exact-flow snapshot failed"
  | Exact_flow.Flow_start_failed -> "AGENT_CORE exact-flow start failed"
;;

let exact_provenance_equal
      (left : Partition.exact_provenance)
      (right : Partition.exact_provenance)
  =
  String.equal left.Partition.slot_id right.Partition.slot_id
  && String.equal left.call_id right.call_id
  && String.equal left.plan_fingerprint right.plan_fingerprint
  && String.equal left.request_body_sha256 right.request_body_sha256
;;

let candidate_visit_equal
      (left : Partition.candidate_visit)
      (right : Partition.candidate_visit)
  =
  String.equal left.flow_id right.flow_id
  && Int.equal left.ordinal right.ordinal
  && String.equal left.slot_id right.slot_id
  && String.equal
       left.catalog_generation_fingerprint
       right.catalog_generation_fingerprint
  && String.equal left.catalog_evidence_sha256 right.catalog_evidence_sha256
  && String.equal
       left.target_identity_fingerprint
       right.target_identity_fingerprint
;;

let callback_invariant operation cause =
  Partition.Durable_partition_invariant
    (Printf.sprintf "%s callback disagrees with durable progress: %s" operation cause)
;;

let before_dispatch_failure_reason partition ~cause ~current =
  let projected = partition_provenance current in
  match running_progress partition with
  | Some (Partition.Bound durable as progress)
    when exact_provenance_equal durable projected ->
    Partition.Exact_execution_quarantined progress
  | Some (Partition.Advancing { next; _ } as progress)
    when String.equal next.slot_id projected.slot_id ->
    Partition.Exact_execution_quarantined progress
  | Some Partition.Unbound
  | Some (Partition.Bound _)
  | Some (Partition.Advancing _)
  | None -> callback_invariant "before-dispatch" cause
;;

let before_advance_failure_reason partition ~cause ~failed ~next =
  let source = partition_advance_source failed in
  let next = partition_candidate_visit next in
  match running_progress partition with
  | Some
      (Partition.Advancing
         { execution_anchor = Some anchor; last_from = None; next = durable_next }
       as progress)
    when (match source with
          | Partition.Executed_failure failed ->
            exact_provenance_equal anchor failed
            && candidate_visit_equal durable_next next
          | Partition.Predispatch_rejection _ -> false) ->
    Partition.Exact_execution_quarantined progress
  | Some
      (Partition.Advancing
         { execution_anchor = _
         ; last_from = Some durable_from
         ; next = durable_next
         } as progress)
    when (match source with
          | Partition.Predispatch_rejection rejected ->
            candidate_visit_equal durable_from rejected
            && candidate_visit_equal durable_next next
          | Partition.Executed_failure _ -> false) ->
    Partition.Exact_execution_quarantined progress
  | Some (Partition.Advancing _ as progress) ->
    Partition.Exact_execution_quarantined progress
  | Some (Partition.Bound durable as progress) ->
    (match source with
     | Partition.Executed_failure failed
       when exact_provenance_equal durable failed ->
       Partition.Exact_execution_quarantined progress
     | Partition.Executed_failure _
     | Partition.Predispatch_rejection _ ->
       callback_invariant "before-advance" cause)
  | Some Partition.Unbound ->
    (match source with
     | Partition.Predispatch_rejection last_from ->
       Partition.Exact_execution_quarantined
         (Partition.Advancing
            { execution_anchor = None
            ; last_from = Some last_from
            ; next
            })
     | Partition.Executed_failure _ -> callback_invariant "before-advance" cause)
  | None -> callback_invariant "before-advance" cause
;;

type execution_disposition =
  | Execution_blocked of Partition.blocked_reason

let execution_disposition partition = function
  | Exact_flow.Flow_already_started _ ->
    Execution_blocked
      (preserve_durable_progress partition Partition.Exact_flow_replayed)
  | Exact_flow.Before_dispatch_persistence_failed
      { cause; current; evidence = _ } ->
    Execution_blocked
      (before_dispatch_failure_reason partition ~cause ~current)
  | Exact_flow.Before_advance_persistence_failed
      { cause; failed; next; evidence = _ } ->
    Execution_blocked
      (before_advance_failure_reason partition ~cause ~failed ~next)
  | Exact_flow.Exact_execution_failed _ ->
    Execution_blocked
      (preserve_durable_progress partition Partition.Exact_execution_terminal)
  | Exact_flow.Provenance_mismatch detail ->
    Execution_blocked
      (preserve_durable_progress
         partition
         (Partition.Execution_provenance_mismatch detail))
  | Exact_flow.Domain_output_invalid detail ->
    Execution_blocked
      (preserve_durable_progress
         partition
         (Partition.Domain_output_invalid detail))
;;

let confirm_exact_transition latest_partition operation = function
  | Error detail -> Error (operation ^ " failed: " ^ detail)
  | Ok transition ->
    latest_partition := transition.Partition.partition;
    (match transition.write_outcome with
     | Partition.Fsync_completed -> Ok ()
     | Partition.Visible_sync_unconfirmed detail ->
       Error (operation ^ " visible but fsync is unconfirmed: " ^ detail))
;;

let before_dispatch
      ~worker_epoch
      ~base_path
      latest_partition
      provenance
  =
  let provenance = partition_provenance provenance in
  Partition.bind_before_dispatch
    ~worker_epoch
    ~base_path
    ~partition:!latest_partition
    ~provenance
  |> confirm_exact_transition latest_partition "exact before-dispatch bind"
;;

let before_advance
      ~worker_epoch
      ~base_path
      latest_partition
      ~failed
      ~next
  =
  let source = partition_advance_source failed in
  let next = partition_candidate_visit next in
  Partition.record_before_advance
    ~worker_epoch
    ~base_path
    ~partition:!latest_partition
    ~source
    ~next
  |> confirm_exact_transition latest_partition "exact before-advance record"
;;

let complete_existing_judgment
      ~now
      ~worker_epoch
      ~base_path
      latest_partition
      judgment
  =
  let item : Partition.completed_item =
    { Partition.candidate_id = (!latest_partition).Partition.candidate_id; judgment }
  in
  match
    Partition.complete_existing_judgment
      ~now:(now ())
      ~worker_epoch
      ~base_path
      ~partition:!latest_partition
      ~item
  with
  | Ok transition ->
    let* completed =
      confirm_completed_transition
        ~base_path
        latest_partition
        "existing judgment completion"
        transition
    in
    let owner_wake =
      exact_owner_wake
        ~base_path
        ~keeper_name:completed.Partition.keeper_name
    in
    Ok
      (Judgment_completed
         { candidate_id = completed.candidate_id; owner_wake })
  | Error detail ->
    blocked_step
      ~now:(now ())
      ~worker_epoch
      ~base_path
      !latest_partition
      (Partition.Durable_partition_invariant
         ("existing judgment completion failed: " ^ detail))
;;

let settle_existing_consumed
      ~now
      ~worker_epoch
      ~base_path
      latest_partition
      judgment
  =
  let item : Partition.completed_item =
    { Partition.candidate_id = (!latest_partition).Partition.candidate_id; judgment }
  in
  match
    Partition.complete_existing_judgment
      ~now:(now ())
      ~worker_epoch
      ~base_path
      ~partition:!latest_partition
      ~item
  with
  | Error detail ->
    blocked_step
      ~now:(now ())
      ~worker_epoch
      ~base_path
      !latest_partition
      (Partition.Durable_partition_invariant
         ("existing consumed completion failed: " ^ detail))
  | Ok transition ->
    let* completed =
      confirm_completed_transition
        ~base_path
        latest_partition
        "existing consumed completion"
        transition
    in
    let* (_ : Candidate.candidate) =
      Candidate.normalize_requeued_consumed
        ~base_path
        ~keeper_name:completed.keeper_name
        ~candidate_id:completed.candidate_id
    in
    let* settled =
      Partition.settle ~now:(now ()) ~base_path ~partition:completed
    in
    Ok (Candidate_already_consumed { candidate_id = settled.candidate_id })
;;

let process_pending
      ~now
      ~worker_epoch
      ~base_path
      ~execute
      latest_partition
      prepared
  =
  match
    execute
      ~before_dispatch:
        (before_dispatch ~worker_epoch ~base_path latest_partition)
      ~before_advance:
        (before_advance ~worker_epoch ~base_path latest_partition)
      prepared
  with
  | Error error ->
    (match execution_disposition !latest_partition error with
     | Execution_blocked reason ->
       blocked_step
         ~now:(now ())
         ~worker_epoch
         ~base_path
         !latest_partition
         reason)
  | Ok judgment ->
    let* projection =
      complete_projection
        ~now:(now ())
        ~worker_epoch
        ~base_path
        latest_partition
        judgment
    in
    signal_completion projection
;;

let process_claimed
      ~now
      ~worker_epoch
      ~base_path
      ~prepared
      ~execute
      latest_partition
      candidates
  =
  let partition = !latest_partition in
  match candidate_by_id partition.Partition.candidate_id candidates with
  | None ->
    blocked_step
      ~now:(now ())
      ~worker_epoch
      ~base_path
      partition
      (Partition.Candidate_membership_conflict
         ("candidate ledger lacks partition member " ^ partition.candidate_id))
  | Some candidate ->
    (match validate_partition_member partition candidate with
     | Error detail ->
       blocked_step
         ~now:(now ())
         ~worker_epoch
         ~base_path
         partition
         (Partition.Candidate_membership_conflict detail)
     | Ok () ->
       (match Candidate.status_view candidate.status with
        | Candidate.Direct_resumable (Candidate.Resumable_pending _)
        | Candidate.Requeued_resumable
            { resumable = Candidate.Resumable_pending _; _ } ->
          (match prepared with
           | Some (candidate_id, prepared)
             when String.equal candidate_id candidate.candidate_id ->
             process_pending
               ~now
               ~worker_epoch
               ~base_path
               ~execute
               latest_partition
               prepared
           | Some _ | None ->
             Error
               ("Board attention claimed Pending candidate without successful "
                ^ "pre-claim exact setup: "
                ^ candidate.candidate_id))
        | Candidate.Direct_resumable (Candidate.Resumable_judged judged)
        | Candidate.Requeued_resumable
            { resumable = Candidate.Resumable_judged judged; _ } ->
          complete_existing_judgment
            ~now
            ~worker_epoch
            ~base_path
            latest_partition
            judged.judgment
        | Candidate.Direct_resumable (Candidate.Resumable_consumed consumed)
        | Candidate.Requeued_resumable
            { resumable = Candidate.Resumable_consumed consumed; _ } ->
          settle_existing_consumed
            ~now
            ~worker_epoch
            ~base_path
            latest_partition
            consumed.judgment
        | Candidate.Suspended_quarantine _ ->
          Error
            ("Quarantined Board attention candidate became claimable: "
             ^ candidate.candidate_id)))
;;

let prepare_next_ready
      ~base_path
      ~keeper_name
      ~prepare
      candidates
  =
  let* partitions = Partition.load ~base_path ~keeper_name in
  match
    List.find_opt
      (fun (partition : Partition.t) ->
         match partition.state with
         | Partition.Ready -> true
         | Partition.Running _
         | Partition.Completed _
         | Partition.Settled _
         | Partition.Blocked _ -> false)
      partitions
  with
  | None -> Ok None
  | Some partition ->
    let selected prepared =
      Ok (Some (partition.partition_id, partition.generation, prepared))
    in
    (match candidate_by_id partition.candidate_id candidates with
     | None -> selected None
     | Some candidate ->
       (match validate_partition_member partition candidate with
        | Error _ -> selected None
        | Ok () ->
          (match Candidate.status_view candidate.status with
           | Candidate.Direct_resumable (Candidate.Resumable_pending _)
           | Candidate.Requeued_resumable
               { resumable = Candidate.Resumable_pending _; _ } ->
             (match prepare candidate with
              | Ok prepared ->
                selected (Some (candidate.candidate_id, prepared))
              | Error error ->
                Error
                  ("Board attention exact setup unavailable before claim: "
                   ^ setup_error_detail error))
           | Candidate.Direct_resumable
               (Candidate.Resumable_judged _
               | Candidate.Resumable_consumed _)
           | Candidate.Requeued_resumable
               { resumable =
                   (Candidate.Resumable_judged _
                   | Candidate.Resumable_consumed _)
               ; _
               }
           | Candidate.Suspended_quarantine _ -> selected None)))
;;

let confirm_requeue_transition ~base_path transition =
  match transition.Partition.write_outcome with
  | Partition.Fsync_completed -> Ok transition
  | Partition.Visible_sync_unconfirmed _ ->
    let* confirmed =
      Partition.confirm_ready
        ~base_path
        ~partition:transition.partition
    in
    (match confirmed.write_outcome with
     | Partition.Fsync_completed -> Ok confirmed
     | Partition.Visible_sync_unconfirmed detail ->
       Error ("requeued partition fsync remains unconfirmed: " ^ detail))
;;

let rec converge_requeue_conflict
    ?(remaining_cursor_retries = 2)
    ~base_path
    ~keeper_name
    ~partition
    ~expected_quarantine_id
    ()
  =
  let* candidates = Candidate.load_candidates ~base_path ~keeper_name in
  let* candidate =
    match
      List.find_opt
        (fun candidate ->
           String.equal
             candidate.Candidate.candidate_id
             partition.Partition.candidate_id)
        candidates
    with
    | Some candidate -> Ok candidate
    | None ->
      Error
        ("partition candidate disappeared during requeue convergence: "
         ^ partition.candidate_id)
  in
  let* () =
    match Candidate.status_view candidate.status with
    | Candidate.Requeued_resumable
        { quarantine =
            { quarantine
            ; phase = Candidate.Requeued _
            }
        ; _
        }
      when String.equal quarantine.partition_id partition.partition_id
           && String.equal quarantine.quarantine_id expected_quarantine_id
           && Partition.Generation.equal
                quarantine.partition_generation
                partition.generation ->
      Ok ()
    | Candidate.Direct_resumable _
    | Candidate.Requeued_resumable _
    | Candidate.Suspended_quarantine _ ->
      Error
        ("candidate quarantine generation changed during requeue convergence: "
         ^ partition.partition_id)
  in
  let* partitions = Partition.load ~base_path ~keeper_name in
  let* current =
    match
      List.find_opt
        (fun current ->
           String.equal current.Partition.partition_id partition.partition_id)
        partitions
    with
    | Some current -> Ok current
    | None ->
      Error
        ("partition disappeared during requeue convergence: "
         ^ partition.partition_id)
  in
  match current.state with
  | Partition.Ready
    when Partition.Generation.is_direct_successor
           ~previous:partition.generation
           current.generation ->
    let* confirmation = Partition.confirm_ready ~base_path ~partition:current in
    confirm_requeue_transition ~base_path confirmation
  | Partition.Blocked _ when current = partition ->
    if remaining_cursor_retries <= 0
    then
      Error
        ("partition ledger cursor remained conflicted after bounded requeue retries: "
         ^ partition.partition_id)
    else
      let* outcome = Partition.requeue_blocked ~base_path ~partition:current in
      (match outcome with
       | Partition.Requeued transition ->
         confirm_requeue_transition ~base_path transition
       | Partition.Cursor_conflict _ ->
         converge_requeue_conflict
           ~remaining_cursor_retries:(remaining_cursor_retries - 1)
           ~base_path
           ~keeper_name
           ~partition
           ~expected_quarantine_id
           ()
       | Partition.Generation_conflict detail ->
         Error ("partition target generation changed during requeue: " ^ detail))
  | Partition.Ready
  | Partition.Blocked _
  | Partition.Running _
  | Partition.Completed _
  | Partition.Settled _ ->
    Error
      ("partition generation changed during requeue convergence: "
       ^ partition.partition_id)
;;

let confirm_requeue_outcome
      ~base_path
      ~keeper_name
      ~partition
      ~expected_quarantine_id
  = function
  | Partition.Requeued transition ->
    confirm_requeue_transition ~base_path transition
  | Partition.Cursor_conflict _ ->
    converge_requeue_conflict
      ~base_path
      ~keeper_name
      ~partition
      ~expected_quarantine_id
      ()
  | Partition.Generation_conflict detail ->
    Error ("partition target generation changed during requeue: " ^ detail)
;;

let reconcile_quarantines ~now ~base_path ~keeper_name =
  let* partitions = Partition.load ~base_path ~keeper_name in
  (* The candidate store is read once and carried, not re-read per partition.
     Only one branch below writes a candidate, and it re-reads for the rest;
     every other branch leaves the store alone, so re-reading after them
     re-parsed a ledger that had not moved.

     Measured 2026-09-05 on this fleet: one keeper carries 1,219 partitions
     against 1,216 candidates, so the loop parsed a 27 MB ledger 1,219 times
     in a pass. That site allocated 2.1 GB in twenty-five seconds, the
     largest single source in an otherwise idle server.

     What each iteration sees is unchanged: after a write the next iteration
     reads the store again, exactly as it did when every iteration read. *)
  let* initial_candidates = Candidate.load_candidates ~base_path ~keeper_name in
  let rec loop candidates = function
    | [] -> Ok ()
    | partition :: rest ->
      let loop_reloaded rest =
        let* candidates = Candidate.load_candidates ~base_path ~keeper_name in
        loop candidates rest
      in
      (* Shadowed so the branches below read the same as they did: the ones
         that changed nothing carry the list on, and the one that wrote
         re-binds this to the reloading form. *)
      let loop rest = loop candidates rest in
      (match
         List.find_opt
           (fun candidate ->
              String.equal
                candidate.Candidate.candidate_id
                partition.Partition.candidate_id)
           candidates
       with
       | None ->
         (* Mirror of the Completed finalizer's [Candidate_absent] outcome
            (#28770): a retire moves the whole candidate store aside and
            leaves no tombstone, so a quarantine naming a retired candidate
            can never be acknowledged or requeued. Erroring here fataled the
            whole worker at every process start (stage=process_recovery,
            2026-08-16, three fleet keepers), which is exactly the permanent
            re-encounter the finalizer branch exists to stop. Terminal
            Blocked settles; every other state passes through the same way a
            present candidate with a non-quarantine status does below. *)
         (match partition.state with
          | Partition.Blocked _ ->
            Log.Keeper.error
              "Board attention candidate permanently absent during quarantine reconciliation; settling blocked partition keeper=%s partition=%s candidate=%s"
              keeper_name
              partition.partition_id
              partition.candidate_id;
            let* (_ : Partition.t) = Partition.settle ~now ~base_path ~partition in
            loop rest
          | Partition.Ready | Partition.Running _ | Partition.Completed _
          | Partition.Settled _ -> loop rest)
       | Some candidate ->
         (match partition.state, Candidate.status_view candidate.status with
       | ( Partition.Blocked _
         , (Candidate.Suspended_quarantine state
           | Candidate.Requeued_resumable { quarantine = state; _ }) )
         when String.equal
                state.quarantine.partition_id
                partition.partition_id
              && Partition.Generation.equal
                   state.quarantine.partition_generation
                   partition.generation ->
         (match state.phase with
          | Candidate.Requeue_requested _ ->
            let* (_ : Candidate.candidate) =
              Candidate.finish_quarantine_requeue
                ~base_path
                ~candidate
                ~partition_id:partition.partition_id
                ~expected_quarantine_id:state.quarantine.quarantine_id
                ~requeued_at:now
            in
            (* This branch wrote a candidate; the rest of the pass reads the
               store again rather than the copy taken before it. *)
            let loop rest = loop_reloaded rest in
            let* (_ : Partition.exact_transition) =
              let* outcome = Partition.requeue_blocked ~base_path ~partition in
              confirm_requeue_outcome
                ~base_path
                ~keeper_name
                ~partition
                ~expected_quarantine_id:state.quarantine.quarantine_id
                outcome
            in
            loop rest
          | Candidate.Quarantined -> loop rest
          | Candidate.Requeued _ ->
            let* (_ : Partition.exact_transition) =
              let* outcome = Partition.requeue_blocked ~base_path ~partition in
              confirm_requeue_outcome
                ~base_path
                ~keeper_name
                ~partition
                ~expected_quarantine_id:state.quarantine.quarantine_id
                outcome
            in
            loop rest)
       | Partition.Blocked _, _ ->
         let* () = quarantine_blocked_partition ~base_path partition in
         loop rest
       | ( Partition.Ready
         , (Candidate.Suspended_quarantine state
           | Candidate.Requeued_resumable { quarantine = state; _ }) )
         when String.equal
                state.quarantine.partition_id
                partition.partition_id
              && Partition.Generation.is_direct_successor
                   ~previous:state.quarantine.partition_generation
                   partition.generation ->
         (match state.phase with
          | Candidate.Requeue_requested _ ->
            Error
              ("Ready partition preceded candidate requeue authorization: "
               ^ partition.partition_id)
          | Candidate.Quarantined ->
            Error
              ("Ready partition has an unacknowledged quarantine: "
               ^ partition.partition_id)
          | Candidate.Requeued _ ->
            let* confirmation =
              Partition.confirm_ready ~base_path ~partition
            in
            let* (_ : Partition.exact_transition) =
              confirm_requeue_transition ~base_path confirmation
            in
            loop rest)
       | ( Partition.Ready
         , (Candidate.Suspended_quarantine state
           | Candidate.Requeued_resumable { quarantine = state; _ }) )
         when String.equal
                state.quarantine.partition_id
                partition.partition_id ->
         Error
           ("Ready partition is not the quarantined generation successor: "
            ^ partition.partition_id)
          | Partition.Ready, _
          | Partition.Running _, _
          | Partition.Completed _, _
          | Partition.Settled _, _ ->
            loop rest))
  in
  loop initial_candidates partitions
;;

let process_next_with_claim_ready_exact_current
      ~claim_ready_exact
      ~now
      ~worker_epoch
      ~base_path
      ~keeper_name
      ~prepare
      ~execute
  =
  let* candidates = Candidate.load_candidates ~base_path ~keeper_name in
  let* (_ : int) = Partition.ensure_roots ~base_path ~keeper_name candidates in
  let selected_generation_is_ready ~partition_id ~generation =
    let* partitions = Partition.load ~base_path ~keeper_name in
    Ok
      (List.exists
        (fun (partition : Partition.t) ->
           String.equal partition.partition_id partition_id
           && Partition.Generation.equal partition.generation generation
           &&
           match partition.state with
           | Partition.Ready -> true
           | Partition.Running _
           | Partition.Completed _
           | Partition.Settled _
           | Partition.Blocked _ -> false)
        partitions)
  in
  let process_selected prepared partition =
    let latest_partition : Partition.t ref = ref partition in
    try
      let* current_candidates =
        Candidate.load_candidates ~base_path ~keeper_name
      in
      process_claimed
        ~now
        ~worker_epoch
        ~base_path
        ~prepared
        ~execute
        latest_partition
        current_candidates
    with
    | Eio.Cancel.Cancelled _ as exn -> raise exn
    | exn ->
      Log.Keeper.error
        "Board attention worker raised unexpectedly keeper=%s partition=%s: %s"
        keeper_name
        (!latest_partition).partition_id
        (Printexc.to_string exn);
      let reason =
        preserve_durable_progress
          !latest_partition
          (Partition.Unexpected_worker_failure
             "Board attention worker raised unexpectedly")
      in
      blocked_step
        ~now:(now ())
        ~worker_epoch
        ~base_path
        !latest_partition
        reason
  in
  let* selected =
    prepare_next_ready ~base_path ~keeper_name ~prepare candidates
  in
  match selected with
  | None -> Ok Idle
  | Some (partition_id, generation, prepared) ->
    let rec claim_selected attempts_remaining =
      let* claimed =
        claim_ready_exact
          ~now:(now ())
          ~worker_epoch
          ~base_path
          ~keeper_name
          ~partition_id
          ~generation
      in
      match claimed with
      | Some partition -> process_selected prepared partition
      | None ->
        let* remains_ready =
          selected_generation_is_ready ~partition_id ~generation
        in
        if not remains_ready
        then Ok (Rescan_later { keeper_name; partition_id; generation })
        else if attempts_remaining > 1
        then claim_selected (attempts_remaining - 1)
        else Ok (Contended { keeper_name; partition_id; generation })
    in
    claim_selected 3
;;

let process_next_with_claim_ready_exact
      ~claim_ready_exact
      ~now
      ~worker_epoch
      ~base_path
      ~keeper_name
      ~prepare
      ~execute
  =
  process_next_with_claim_ready_exact_current
    ~claim_ready_exact
    ~now
    ~worker_epoch
    ~base_path
    ~keeper_name
    ~prepare
    ~execute
;;

let process_next_current
      ~now
      ~worker_epoch
      ~base_path
      ~keeper_name
      ~prepare
      ~execute
  =
  process_next_with_claim_ready_exact_current
    ~claim_ready_exact:Partition.claim_ready_exact
    ~now
    ~worker_epoch
    ~base_path
    ~keeper_name
    ~prepare
    ~execute
;;

let process_next ~now ~worker_epoch ~base_path ~keeper_name ~prepare ~execute =
  process_next_current
    ~now
    ~worker_epoch
    ~base_path
    ~keeper_name
    ~prepare
    ~execute
;;

let prepare_exact ~base_path ~keeper_name ~net =
  Exact_flow.prepare ~base_path ~keeper_name ~net
;;

(* Provider exhaustion is the one terminal a second transport can answer. The
   persistence and provenance arms say the durable record is in doubt, and
   asking another model does not settle that; a domain-invalid answer is a
   contract failure, not an unreachable provider. This is the split the
   librarian and HITL lanes already apply (RFC cli-runtimes-as-lane-slots).

   Every arm is written out so that a new terminal has to be classified here
   rather than silently inheriting the fallback. *)
let cli_tail_may_answer : _ Exact_flow.execution_error -> bool = function
  | Exact_flow.Exact_execution_failed _ -> true
  | Exact_flow.Flow_already_started _
  | Exact_flow.Before_dispatch_persistence_failed _
  | Exact_flow.Before_advance_persistence_failed _
  | Exact_flow.Provenance_mismatch _
  | Exact_flow.Domain_output_invalid _ -> false
;;

let execute_exact
      ~clock
      ~base_path
      ~keeper_name
      ~before_dispatch
      ~before_advance
      prepared
  =
  match Exact_flow.execute ~clock ~before_dispatch ~before_advance prepared with
  | Error exhausted when cli_tail_may_answer exhausted ->
    (match Exact_flow.run_cli_tail ~base_path prepared with
     | Ok (slot_id, judgment) ->
       Log.Keeper.info
         "board_attention_cli_tail_judged keeper=%s slot=%s"
         keeper_name
         slot_id;
       Ok judgment
     | Error reason ->
       Log.Keeper.warn
         "board_attention_cli_tail_failed keeper=%s reason=%s"
         keeper_name
         (Exact_flow.cli_tail_error_to_string reason);
       Error exhausted)
  | outcome -> outcome
;;

let process_next_exact ~clock ~net ~now ~worker_epoch ~base_path ~keeper_name =
  process_next_current
    ~now
    ~worker_epoch
    ~base_path
    ~keeper_name
    ~prepare:(prepare_exact ~base_path ~keeper_name ~net)
    ~execute:(execute_exact ~clock ~base_path ~keeper_name)
;;

let completed_in_order ~base_path ~keeper_name =
  let* completed = Partition.completed ~base_path ~keeper_name in
  Ok
    (List.sort
       (fun left right ->
          match Float.compare left.Partition.created_at right.Partition.created_at with
          | 0 -> String.compare left.partition_id right.partition_id
          | order -> order)
       completed)
;;

let confirm_loaded_completed
      ~base_path
      operation
      partition
  =
  match Partition.confirm_completed ~base_path ~partition with
  | Error detail -> Error (operation ^ " confirmation failed: " ^ detail)
  | Ok transition ->
    (match transition.write_outcome with
     | Partition.Fsync_completed -> Ok transition.partition
     | Partition.Visible_sync_unconfirmed detail ->
       Error
         (operation
          ^ " remained visible but fsync is unconfirmed after confirmation: "
          ^ detail))
;;

let replay_completed_owner_wake
      ~base_path
      ~keeper_name
      ~wake_owner
  =
  let* completed = completed_in_order ~base_path ~keeper_name in
  match completed with
  | [] -> Ok None
  | partition :: _ ->
    let* (_ : Partition.t) =
      confirm_loaded_completed
        ~base_path
        "completed owner-wake replay"
        partition
    in
    Ok (Some (wake_owner ~base_path ~keeper_name))
;;

(* What this boundary rations is admission into the Keeper, and only a
   [Relevant] verdict admits anything: [Candidate.consume_judged] enqueues a
   stimulus and wakes the owner for [Relevant], and writes one consumed record
   for [Not_relevant]. Counting a discarded signal against the same per-turn
   slot puts every relevant verdict behind however many irrelevant ones share
   its [created_at] order, which is the shape RFC-0334 removed when it deleted
   the fanout limit and arrival window. Settle the discards, stop on the
   delivery. *)
let settles_without_admitting (item : Partition.completed_item) =
  match item.judgment.Candidate.verdict.Keeper_board_attention_judgment.decision with
  | Keeper_board_attention_judgment.Not_relevant -> true
  | Keeper_board_attention_judgment.Relevant -> false
;;

(* Each settlement performs at least the candidate-consumption write and the
   partition transition write, so one owner turn performs at most twice the
   configured settlement bound (default 8, see Keeper_config) such durability
   operations before persisting a continuation wake for the remainder.
   This is deliberately a settlement bound, not a scan or arrival-window
   heuristic: every successful iteration removes one exact Completed
   partition.

   This is a batch-size knob, not a workaround cap: continuation_wake
   re-wakes the owner for exactly one more Completed partition per
   heartbeat cycle rather than moving remaining work off-turn, so the
   choice is cycle-count vs per-cycle-blocking-time, not block-vs-don't
   (masc#27054 adversarial review). See Keeper_config for the runtime_params
   registration and its value derivation. *)
let max_completed_settlements_per_owner_turn () =
  Keeper_config.keeper_board_attention_settlements_per_turn ()

(* [Eio.Fiber.yield] raises [Effect.Unhandled] when no Eio event loop is
   running — the Alcotest suite drives [settle_one_completed] directly without
   [Eio_main.run]. Production heartbeats always run under Eio, so the yield is
   effective there; end-to-end drain behavior is tracked by masc#27055. *)
let yield_between_discard_settlements () =
  try Eio.Fiber.yield () with
  | Effect.Unhandled _ -> ()
;;

let settle_one_completed
      ~base_path
      ~keeper_name
  =
  let settle_head partition =
    let* partition =
      confirm_loaded_completed
        ~base_path
        "completed owner settlement"
        partition
    in
    match partition.Partition.state with
    | Partition.Completed { item; _ } ->
      let* delivery =
        Candidate.apply_judgment_and_deliver
          ~base_path
          ~keeper_name
          ~candidate_id:item.candidate_id
          ~judgment:item.judgment
      in
      (* [Candidate_absent] means the candidate this item names is gone from
         the live ledger for good (a retire moves the whole store aside as one
         directory and leaves no tombstone to re-check later), so no delivery
         can ever land for it. Settling the partition here without one is the
         terminal outcome, not a fallback: the alternative is exactly what
         this branch exists to stop — a settlement error that propagates and
         leaves the same [Completed] item to be handed to this function again
         next cycle, permanently, since the ledger it depends on cannot come
         back (masc, board attention finalizer, 2026-08-16). Discarded rather
         than [settles_without_admitting item]: no stimulus reached the
         Keeper regardless of what the lost judgment's verdict was, so the
         owner-turn batch must keep draining instead of stopping as if this
         had been an admission. *)
      let discarded_only =
        match delivery with
        | Candidate.Candidate_absent ->
          Log.Keeper.error
            "Board attention candidate permanently absent from the ledger; settling partition without delivery keeper=%s partition=%s candidate=%s"
            keeper_name
            partition.partition_id
            item.candidate_id;
          true
        | Candidate.Delivered (_ : Candidate.candidate) ->
          settles_without_admitting item
      in
      let* settled =
        Partition.settle ~now:(Time_compat.now ()) ~base_path ~partition
      in
      Ok (settled, discarded_only)
    | Partition.Ready
    | Partition.Running _
    | Partition.Settled _
    | Partition.Blocked _ ->
      Error
        ("completed partition query returned non-Completed state: "
         ^ partition.partition_id)
  in
  (* Terminates within the owner-turn bound: every iteration settles one
     partition out of [completed]. Completions beyond the bound, including ones
     the worker adds while this runs, are left for the continuation wake. *)
  let rec settle_until_admission ~last_settled ~discarded = function
    | [] -> Ok (last_settled, discarded)
    | _ when discarded >= max_completed_settlements_per_owner_turn () ->
      Ok (last_settled, discarded)
    | partition :: rest ->
      let* settled, discarded_only = settle_head partition in
      if discarded_only
      then (
        yield_between_discard_settlements ();
        settle_until_admission
          ~last_settled:settled
          ~discarded:(discarded + 1)
          rest)
      else Ok (settled, discarded)
  in
  let* completed = completed_in_order ~base_path ~keeper_name in
  match completed with
  | [] -> Ok No_completed_partition
  | first :: _ ->
    let* settled, discarded =
      settle_until_admission ~last_settled:first ~discarded:0 completed
    in
    if discarded > 0
    then
      Log.Keeper.info
        "board_attention_discards_settled keeper=%s count=%d"
        keeper_name
        discarded;
    let* remaining = completed_in_order ~base_path ~keeper_name in
    let continuation_wake =
      match remaining with
      | [] -> None
      | _ :: _ -> Some (owner_wake ~base_path ~keeper_name)
    in
    Ok
      (Partition_settled
         { candidate_id = settled.Partition.candidate_id; continuation_wake })
;;

let recovered_mutex = Stdlib.Mutex.create ()
let recovered_process_keys : (string, unit) Hashtbl.t = Hashtbl.create 16

let claim_process_recovery ~base_path ~keeper_name =
  let key = Keeper_registry_types.registry_key ~base_path keeper_name in
  Stdlib.Mutex.protect recovered_mutex (fun () ->
    if Hashtbl.mem recovered_process_keys key
    then false
    else (
      Hashtbl.add recovered_process_keys key ();
      true))
;;

let release_process_recovery ~base_path ~keeper_name =
  let key = Keeper_registry_types.registry_key ~base_path keeper_name in
  Stdlib.Mutex.protect recovered_mutex (fun () ->
    Hashtbl.remove recovered_process_keys key)
;;

let protect_process_recovery_release release =
  match Eio.Fiber.is_cancelled () with
  | true | false -> Eio.Cancel.protect release
  | exception Effect.Unhandled _ -> release ()
;;

let with_process_recovery_claim ~base_path ~keeper_name run =
  let claimed = claim_process_recovery ~base_path ~keeper_name in
  Fun.protect
    ~finally:(fun () ->
      if claimed
      then
        protect_process_recovery_release (fun () ->
          release_process_recovery ~base_path ~keeper_name))
    (fun () -> run claimed)
;;

let observe_error ~base_path ~keeper_name detail =
  (try Keeper_registry_error_recording.record ~base_path keeper_name detail with
   | Eio.Cancel.Cancelled _ as exn -> raise exn
   | exn ->
     Log.Keeper.error
       "Board attention worker failure observation also failed keeper=%s worker_error=%s observer_error=%s"
       keeper_name
       detail
       (Printexc.to_string exn));
  Log.Keeper.error "Board attention worker failed keeper=%s: %s" keeper_name detail
;;

let drain_available_with_process ~yield ~process =
  let rec loop progress =
    match process () with
    | Ok Idle -> Ok (Drained progress)
    | Ok (Contended contention) ->
      Ok (Retry_later { contention; reason = Exact_claim_contended; progress })
    | Ok (Rescan_later contention) ->
      Ok
        (Retry_later
           { contention; reason = Selected_generation_changed; progress })
    | Ok (Judgment_completed _) ->
      yield ();
      loop
        { judgments = progress.judgments + 1; steps = progress.steps + 1 }
    | Ok (Candidate_already_consumed _ | Partition_blocked _) ->
      yield ();
      loop { progress with steps = progress.steps + 1 }
    | Error detail -> Error detail
  in
  loop { judgments = 0; steps = 0 }
;;

let drain_available_current
      ~yield
      ~now
      ~worker_epoch
      ~base_path
      ~keeper_name
      ~prepare
      ~execute
  =
  drain_available_with_process
    ~yield
    ~process:(fun () ->
      process_next_current
        ~now
        ~worker_epoch
        ~base_path
        ~keeper_name
        ~prepare
        ~execute)
;;

let drain_available
      ~yield
      ~now
      ~worker_epoch
      ~base_path
      ~keeper_name
      ~prepare
      ~execute
  =
  drain_available_current
    ~yield
    ~now
    ~worker_epoch
    ~base_path
    ~keeper_name
    ~prepare
    ~execute
;;

let run
      ~sw
      ~(clock : [> float Eio.Time.clock_ty ] Eio.Resource.t)
      ~net
      ~base_path
      ~keeper_name
  =
  match Wake.register ~sw ~base_path ~keeper_name with
  | Error detail ->
    observe_error ~base_path ~keeper_name detail;
    Error { stage = Registration; detail }
  | Ok registration ->
    Fun.protect
      ~finally:(fun () ->
        protect_process_recovery_release (fun () -> Wake.unregister registration))
      (fun () ->
         with_process_recovery_claim ~base_path ~keeper_name
         @@ fun owns_process_recovery ->
         let worker_epoch = Partition.Worker_epoch.generate () in
         (* Until this line existed, three states were byte-identical from
            outside: the worker was never forked, it was forked and never
            inspected the ledger, or it inspected and found nothing. Measured
            2026-08-05 while pending grew 425 -> 1031 with zero contention
            lines and zero worker failures, so the logs that did exist could
            not tell them apart. *)
         Log.Keeper.info
           "board_attention_worker_start keeper=%s epoch=%s"
           keeper_name
           (Partition.Worker_epoch.to_string worker_epoch);
         let fail stage detail =
           observe_error ~base_path ~keeper_name detail;
           Error { stage; detail }
         in
         let startup =
           if not owns_process_recovery
           then Ok ()
           else
             let now = Time_compat.now () in
             let* (_ : int) =
               Partition.recover_for_process_start
                 ~now
                 ~base_path
                 ~keeper_name
             in
             let* () =
               reconcile_quarantines ~now ~base_path ~keeper_name
             in
             let* (_ : Keeper_registry.wakeup_outcome option) =
               replay_completed_owner_wake
                 ~base_path
                 ~keeper_name
                 ~wake_owner:owner_wake
             in
             Ok ()
         in
         match startup with
         | Error detail -> fail Process_start_recovery detail
         | Ok () ->
           let prepare =
             prepare_exact ~base_path ~keeper_name ~net
           in
           let execute = execute_exact ~clock ~base_path ~keeper_name in
           let contention_rearms =
             make_contention_rearm_scheduler
               ~fork:(fun task -> Eio.Fiber.fork ~sw task)
               ~sleep:(Eio.Time.sleep clock)
               ~request:(fun () -> Wake.request ~base_path ~keeper_name)
               ()
           in
           let rec await () =
             match Wake.await registration with
             | Wake.Registration_closed -> Ok ()
             | Wake.Wake -> drain ()
           and drain () =
             match
               drain_available_current
                 ~yield:Eio.Fiber.yield
                 ~now:Time_compat.now
                 ~worker_epoch
                 ~base_path
                 ~keeper_name
                 ~prepare
                 ~execute
             with
             | Ok outcome ->
               let progress = drain_outcome_progress outcome in
               Log.Keeper.emit
                 (drain_outcome_log_level outcome)
                 (Printf.sprintf
                    "board_attention_worker_drain keeper=%s outcome=%s \
                     judgments=%d steps=%d"
                    keeper_name
                    (drain_outcome_label outcome)
                    progress.judgments
                    progress.steps);
               ignore
                 (apply_drain_rearm contention_rearms outcome
                  : rearm_schedule option);
               await ()
             | Error detail -> fail Durable_drain detail
           in
           (try drain () with
            | Eio.Cancel.Cancelled _ as exn -> raise exn
            | exn ->
              fail
                Control_loop
                ("Board attention worker control loop raised: "
                 ^ Printexc.to_string exn)))
;;

module For_testing = struct
  let cli_tail_may_answer = cli_tail_may_answer

  type nonrec rearm_scheduler = rearm_scheduler

  let reconcile_quarantines = reconcile_quarantines
  let process_next = process_next
  let process_next_exact = process_next_exact
  let process_next_with_claim_ready_exact = process_next_with_claim_ready_exact
  let drain_available = drain_available
  let drain_available_with_process = drain_available_with_process
  let make_contention_rearm_scheduler = make_contention_rearm_scheduler
  let schedule_contention_rearm = schedule_contention_rearm
  let reset_contention_rearms = reset_contention_rearms
  let drain_outcome_label = drain_outcome_label
  let drain_outcome_progress = drain_outcome_progress
  let drain_outcome_log_level = drain_outcome_log_level
  let apply_drain_rearm = apply_drain_rearm
  let replay_completed_owner_wake = replay_completed_owner_wake
  let with_process_recovery_claim = with_process_recovery_claim
end
;;
