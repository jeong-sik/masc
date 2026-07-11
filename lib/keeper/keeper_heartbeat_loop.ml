(* keeper_heartbeat_loop — the main heartbeat loop body and its helpers:
   presence sync, board event collection, in-turn liveness pulse,
   unified turn dispatch, smart heartbeat gate, stage timing recording,
   and [run_heartbeat_loop].

   Extracted from keeper_keepalive.ml. *)

open Keeper_types
open Keeper_meta_contract
open Keeper_meta_store
open Keeper_types_profile
open Keeper_memory
open Keeper_execution
open Keeper_keepalive_signal
module Observations = Keeper_heartbeat_loop_observations
module Cycle = Keeper_heartbeat_loop_cycle

(* Presence/identity sync extracted to
   [Keeper_heartbeat_loop_presence] (godfile decomp). *)
let effective_keepalive_meta = Keeper_heartbeat_loop_presence.effective_keepalive_meta
let repair_identity_drift_for_keepalive = Keeper_heartbeat_loop_presence.repair_identity_drift_for_keepalive
let keeper_agent_status = Keeper_heartbeat_loop_presence.keeper_agent_status
let note_turn_failures_preserved_after_heartbeat = Keeper_heartbeat_loop_presence.note_turn_failures_preserved_after_heartbeat
let sync_keeper_presence = Keeper_heartbeat_loop_presence.sync_keeper_presence

(* Pending board-event collection extracted to
   [Keeper_heartbeat_loop_board_events] (godfile decomp). *)
let collect_keepalive_board_events = Keeper_heartbeat_loop_board_events.collect_keepalive_board_events

let in_turn_liveness_pulse_interval_sec =
  Keeper_heartbeat_loop_in_turn_pulse.in_turn_liveness_pulse_interval_sec

let with_in_turn_liveness_pulse_for_test =
  Keeper_heartbeat_loop_in_turn_pulse.with_in_turn_liveness_pulse_for_test

let emit_in_turn_liveness_pulse =
  Keeper_heartbeat_loop_in_turn_pulse.emit_in_turn_liveness_pulse

let with_in_turn_liveness_pulse =
  Keeper_heartbeat_loop_in_turn_pulse.with_in_turn_liveness_pulse

(* Event-Layer stimulus intake extracted to [Keeper_heartbeat_stimulus_intake]
   (godfile decomp). Type + entry point are re-exported as transparent
   aliases so callers (incl. .mli consumers) stay byte-identical. *)
module Stimulus_intake = Keeper_heartbeat_stimulus_intake

let stimulus_urgency_to_string = Stimulus_intake.stimulus_urgency_to_string
let pending_board_event_of_stimulus = Stimulus_intake.pending_board_event_of_stimulus
let record_recovery_stimulus_turn_started =
  Stimulus_intake.record_recovery_stimulus_turn_started
;;

let record_event_queue_stimulus_turn_started =
  Stimulus_intake.record_event_queue_stimulus_turn_started
;;

type heartbeat_event_intake = Stimulus_intake.heartbeat_event_intake = {
  pending_board_events : Keeper_world_observation.pending_board_event list;
  consumed_stimulus_count : int;
  consumed_stimuli : Keeper_event_queue.stimulus list;
  claimed_lease : Keeper_registry_event_queue.lease option;
  event_queue_claim_error : string option;
  event_queue_triggers : Keeper_world_observation.event_queue_trigger list;
}

type single_claim_admission = Stimulus_intake.single_claim_admission =
  | Admit_ready_single
  | Defer_failure_judgment

type turn_intake_admission =
  | Intake_admitted
  | Intake_lifecycle_blocked of Keeper_lifecycle_admission.autonomous_denial
  | Intake_pressure_blocked of Keeper_pressure_admission.block
  | Intake_blocking_approval_pending

let classify_turn_intake_admission
      ~lifecycle
      ~pressure
      ~blocking_approval_pending
  =
  match lifecycle with
  | Keeper_lifecycle_admission.Autonomous_denied denial ->
    Intake_lifecycle_blocked denial
  | Keeper_lifecycle_admission.Autonomous_admitted ->
    (match pressure with
     | Keeper_pressure_admission.Blocked block -> Intake_pressure_blocked block
     | Keeper_pressure_admission.Admitted ->
       if blocking_approval_pending
       then Intake_blocking_approval_pending
       else Intake_admitted)
;;

let consume_single_heartbeat_stimulus = Stimulus_intake.consume_single_heartbeat_stimulus
let consume_board_stimulus_batch = Stimulus_intake.consume_board_stimulus_batch
let heartbeat_event_intake = Stimulus_intake.heartbeat_event_intake

(* Keepalive scheduling decision (record + decide function) extracted to
   [Keeper_heartbeat_loop_scheduling] (godfile decomp). *)
type runtime_backpressure_decision = Observations.runtime_backpressure_decision =
  | Runtime_admitted
  | Runtime_backpressured of {
      runtime_id : string;
      reason : string;
    }

type keepalive_scheduling_decision = Keeper_heartbeat_loop_scheduling.keepalive_scheduling_decision = {
  turn_decision : Keeper_world_observation.keeper_cycle_decision;
  requested_should_run_turn : bool;
  runtime_backpressure : runtime_backpressure_decision;
  pacing_block : float option;
  should_run_turn : bool;
  verdict_reasons : string list;
  channel : string;
}

let decide_keepalive_scheduling = Keeper_heartbeat_loop_scheduling.decide_keepalive_scheduling

let provider_timeout_observation_reasons =
  Observations.provider_timeout_observation_reasons
;;

let record_provider_timeout_observation =
  Observations.record_provider_timeout_observation
;;

let record_runtime_backpressure_observation =
  Observations.record_runtime_backpressure_observation
;;

(* #10008 fm3: canonical metric name for proactive-scheduler skip
   reasons. Labels: [("keeper", <name>); ("reason", <skip_reason>)]. *)
let proactive_skip_reason_metric = Keeper_metrics.(to_string ProactiveSkip)

let clear_provider_timeout_failure_reason =
  Observations.clear_provider_timeout_failure_reason
;;

let prior_provider_timeout_strikes =
  Observations.prior_provider_timeout_strikes
;;

let is_provider_timeout_error = Observations.is_provider_timeout_error

let timeout_phase_of_provider_timeout_phase =
  Observations.timeout_phase_of_provider_timeout_phase
;;

let provider_timeout_policy_decision =
  Observations.provider_timeout_policy_decision
;;

let provider_timeout_metric_outcome =
  Observations.provider_timeout_metric_outcome
;;

(** Run keeper cycle with holder diagnostics. *)
let run_keeper_cycle = Cycle.run_keeper_cycle

(* T6 audit: outcome of one keepalive cycle evaluation.

   [cycle_crashed = true] means either the catch-all in
   [run_keepalive_unified_turn] swallowed an exception to keep the
   keeper fiber alive, or the durable event-queue claim/settlement did
   not commit. The failure has already been recorded via
   [Keeper_registry.increment_turn_failures] (the same counter the
   unified-turn failure path in [Keeper_unified_turn_failure] uses),
   so the caller reads a non-zero [turn_fail_count] and dispatches
   [Turn_failed] instead of [Turn_succeeded]. Such a cycle must also
   NOT refresh the work-as-heartbeat lease. *)
type keepalive_turn_outcome = {
  meta : keeper_meta;
  cycle_crashed : bool;
}

exception Event_queue_settlement_failed of string

let connector_attention_event_ids_of_stimuli stimuli =
  List.filter_map
    (fun (stimulus : Keeper_event_queue.stimulus) ->
      match stimulus.payload with
      | Keeper_event_queue.Connector_attention { event_id } -> Some event_id
      | Keeper_event_queue.Board_signal _
      | Keeper_event_queue.Fusion_completed _
      | Keeper_event_queue.Bg_completed _
      | Keeper_event_queue.Schedule_due _
      | Keeper_event_queue.Bootstrap
      | Keeper_event_queue.No_progress_recovery
      | Keeper_event_queue.Hitl_resolved _
      | Keeper_event_queue.Goal_verification_failed _
      | Keeper_event_queue.Failure_judgment _
      | Keeper_event_queue.Goal_assigned _
      | Keeper_event_queue.Goal_stagnation _ ->
        None)
    stimuli
;;

let record_schedule_due_turn_started_reactions ~ctx ~keeper_name stimuli =
  List.iter
    (fun (stimulus : Keeper_event_queue.stimulus) ->
       match stimulus.payload with
       | Keeper_event_queue.Schedule_due _ ->
         record_event_queue_stimulus_turn_started ~ctx ~keeper_name stimulus
       | Keeper_event_queue.Board_signal _
       | Keeper_event_queue.Fusion_completed _
       | Keeper_event_queue.Bg_completed _
       | Keeper_event_queue.Bootstrap
       | Keeper_event_queue.No_progress_recovery
       | Keeper_event_queue.Connector_attention _
       | Keeper_event_queue.Hitl_resolved _
       | Keeper_event_queue.Goal_verification_failed _
       | Keeper_event_queue.Failure_judgment _
       | Keeper_event_queue.Goal_assigned _
       | Keeper_event_queue.Goal_stagnation _ -> ())
    stimuli
;;

let mark_connector_attention_ignored_after_turn ~base_path ~keeper_name event_ids =
  match event_ids with
  | [] -> ()
  | _ :: _ ->
    (match
       Keeper_external_attention.mark_ignored
         ~base_path
         ~keeper_name
         ~event_ids
         ~reason:"connector_attention_turn_completed_without_direct_reply"
         ()
     with
     | Ok () -> ()
     | Error err ->
       Log.Keeper.warn
         "connector attention mark_ignored after turn failed keeper=%s events=[%s]: %s"
         keeper_name
         (String.concat "," event_ids)
         err)
;;

(* T6 audit: record a swallowed cycle exception as a turn failure.

   Catch-and-survive is intentional (the fiber must outlive the
   crash); the bug being fixed is that the crash was invisible to the
   scheduling/escalation layer. Incrementing the registry counter
   routes the crash through the same channel other turn failures use:
   the caller loop dispatches [Turn_failed] and raises
   [Keeper_fiber_crash] at the same threshold, and
   [Keeper_unified_turn_failure.record_failure_and_maybe_escalate]
   reads the same counter for its escalation decision. *)
let record_crashed_cycle_failure ~base_path ~keeper_name exn =
  (* Capture the backtrace before any other call can clobber it. *)
  let backtrace = Printexc.get_backtrace () in
  Keeper_registry.increment_turn_failures ~base_path keeper_name;
  Health.record_failure
    ~agent_name:keeper_name
    ~reason:(Keeper_types_profile.short_preview (Printexc.to_string exn));
  Otel_metric_store.inc_counter
    Keeper_metrics.(to_string CycleExceptions)
    ~labels:[ "keeper", keeper_name ]
    ();
  Log.Keeper.error
    "%s: keeper cycle exception (recorded as turn failure): %s%s"
    keeper_name
    (Printexc.to_string exn)
    (if String.equal backtrace "" then "" else "\n" ^ backtrace)
;;

let failure_judgment_of_stimuli = function
  | [ { Keeper_event_queue.payload =
          Keeper_event_queue.Failure_judgment judgment
      ; _
      } ] ->
    Ok (Some judgment)
  | stimuli ->
    if
      List.exists
        (fun (stimulus : Keeper_event_queue.stimulus) ->
           match stimulus.payload with
           | Keeper_event_queue.Failure_judgment _ -> true
           | Keeper_event_queue.Board_signal _
           | Keeper_event_queue.Fusion_completed _
           | Keeper_event_queue.Bg_completed _
           | Keeper_event_queue.Schedule_due _
           | Keeper_event_queue.Bootstrap
           | Keeper_event_queue.No_progress_recovery
           | Keeper_event_queue.Connector_attention _
           | Keeper_event_queue.Hitl_resolved _
           | Keeper_event_queue.Goal_verification_failed _
           | Keeper_event_queue.Goal_assigned _
           | Keeper_event_queue.Goal_stagnation _ ->
             false)
        stimuli
    then Error "failure judgment must be the sole stimulus in its event queue lease"
    else Ok None
;;

let failure_judgment_successor
      ~arrived_at
      (failure : Keeper_unified_turn.turn_failure)
      judgment
      provenance
      detail
  =
  let payload : Keeper_event_queue.failure_judgment =
    { fj_runtime_id = failure.runtime_id
    ; fj_judgment = judgment
    ; fj_provenance = provenance
    ; fj_detail = detail
    }
  in
  { Keeper_event_queue.post_id = Keeper_event_queue.failure_judgment_post_id payload
  ; urgency = Keeper_event_queue.Normal
  ; arrived_at
  ; payload = Keeper_event_queue.Failure_judgment payload
  }
;;

let settlement_of_failure ~settled_at failure =
  match failure.Keeper_unified_turn.source_lease_disposition with
  | Keeper_unified_turn.Acknowledge_after_in_turn_handling ->
    Keeper_registry_event_queue.Ack
  | Keeper_unified_turn.Follow_failure_route ->
    (match failure.Keeper_unified_turn.route with
     | Keeper_runtime_failure_route.Retry_after_pacing _ ->
       Keeper_registry_event_queue.Requeue
         Keeper_registry_event_queue.Retry_after_pacing
     | Keeper_runtime_failure_route.Rotate_now _ ->
       Keeper_registry_event_queue.Requeue Keeper_registry_event_queue.Rotate_now
     | Keeper_runtime_failure_route.Escalate_judgment
         { judgment; provenance; detail } ->
       Keeper_registry_event_queue.Escalate
         { reason = Keeper_registry_event_queue.Failure_judgment_requested
         ; successor =
             Some
               (failure_judgment_successor
                  ~arrived_at:settled_at
                  failure
                  judgment
                  provenance
                  detail)
         })
;;

let settlement_of_cycle_outcome ~settled_at ~stop_requested ~lease:_ = function
  | Some (Cycle.Completed _) -> Keeper_registry_event_queue.Ack
  | Some (Cycle.Cancelled _) ->
    Keeper_registry_event_queue.Requeue Keeper_registry_event_queue.Cancelled
  | Some (Cycle.Skipped _) ->
    Keeper_registry_event_queue.Requeue
      Keeper_registry_event_queue.Turn_not_scheduled
  | Some (Cycle.Busy _) ->
    Keeper_registry_event_queue.Requeue Keeper_registry_event_queue.Cycle_busy
  | Some (Cycle.Failed { failure; _ }) ->
    settlement_of_failure ~settled_at failure
  | Some (Cycle.Judgment_settled { outcome; _ }) ->
    (match outcome with
     | Cycle.Judgment_boundary_failed { detail } ->
       Keeper_registry_event_queue.Escalate
         { reason =
             Keeper_registry_event_queue.Failure_judgment_boundary_failed
               { detail }
         ; successor = None
         }
     | Cycle.Judgment_operator_required { judge_runtime_id; rationale } ->
       Keeper_registry_event_queue.Escalate
         { reason =
             Keeper_registry_event_queue.Failure_judgment_operator_required
               { judge_runtime_id; rationale }
         ; successor = None
         })
  | None ->
    if stop_requested
    then Keeper_registry_event_queue.Requeue Keeper_registry_event_queue.Cancelled
    else
      Keeper_registry_event_queue.Requeue
        Keeper_registry_event_queue.Turn_not_scheduled
;;

let reaction_kind_of_settlement = function
  | Keeper_registry_event_queue.Ack -> Keeper_reaction_ledger.Event_queue_ack
  | Keeper_registry_event_queue.Requeue _ ->
    Keeper_reaction_ledger.Event_queue_requeued
  | Keeper_registry_event_queue.Escalate _ ->
    Keeper_reaction_ledger.Event_queue_escalated
;;

let project_transition_outbox ~base_path ~keeper_name =
  let rec project_stimuli ~reaction_kind ~receipt = function
    | [] -> Ok ()
    | stimulus :: rest ->
      (match
         Keeper_reaction_ledger.record_event_queue_transition_reaction_result
           ~base_path
           ~keeper_name
           ~reaction_kind
           ~receipt
           stimulus
       with
       | Error _ as error -> error
       | Ok () -> project_stimuli ~reaction_kind ~receipt rest)
  in
  match Keeper_registry_event_queue.transition_outbox_result ~base_path keeper_name with
  | Error _ as error -> error
  | Ok [] -> Ok ()
  | Ok [ (entry : Keeper_registry_event_queue.outbox_entry) ] ->
    let receipt = entry.receipt in
    let reaction_kind = reaction_kind_of_settlement receipt.settlement in
    (match project_stimuli ~reaction_kind ~receipt entry.stimuli with
     | Error _ as error -> error
     | Ok () ->
       Keeper_registry_event_queue.mark_transition_projected_result
         ~base_path
         keeper_name
         ~transition_id:receipt.transition_id)
  | Ok (_ :: _ :: _) -> Error "event queue state has multiple unprojected transitions"
;;

let settle_claimed_lease
      ~base_path
      ~keeper_name
      ~settled_at
      ~lease
      ~settlement
  =
  Eio.Cancel.protect (fun () ->
    Keeper_registry_event_queue.settle_result
      ~base_path
      keeper_name
      ~settled_at
      ~lease
      ~settlement)
;;

let settlement_is_ack = function
  | Keeper_registry_event_queue.Ack -> true
  | Keeper_registry_event_queue.Requeue _
  | Keeper_registry_event_queue.Escalate _ ->
    false
;;

(* Pure: post-turn status event derived from the registry turn-failure
   counter. Extracted from the loop body so the crashed-cycle ->
   [Turn_failed] mapping is unit-testable. *)
let turn_status_event ~turn_fail_count ~max_allowed : Keeper_state_machine.event =
  if turn_fail_count > 0
  then Keeper_state_machine.Turn_failed { consecutive = turn_fail_count; max_allowed }
  else Keeper_state_machine.Turn_succeeded
;;

let run_keepalive_unified_turn
      ~(ctx : _ context)
      ~(meta_after_triage : keeper_meta)
      ~pending_board_events
      ~(stop : bool Atomic.t)
      ~(proactive_warmup_elapsed : bool)
      ~(reactive_wake : bool)
      ~(shared_context : Agent_sdk.Context.t)
  : keepalive_turn_outcome
  =
  if not proactive_warmup_elapsed
  then { meta = meta_after_triage; cycle_crashed = false }
  else (
    let consumed_stimuli = ref [] in
    let claimed_lease = ref None in
    let cycle_outcome_ref = ref None in
    let lease_settled = ref false in
    let settlement_failed = ref false in
    let record_settlement_failure message =
      settlement_failed := true;
      match !cycle_outcome_ref with
      | Some (Cycle.Failed _) ->
        (* The failed turn already recorded its failure counter.  The queue
           error remains explicit in the log and active durable lease. *)
        ()
      | Some
          ( Cycle.Completed _
          | Cycle.Cancelled _
          | Cycle.Skipped _
          | Cycle.Busy _
          | Cycle.Judgment_settled _ )
      | None ->
        record_crashed_cycle_failure
          ~base_path:ctx.config.base_path
          ~keeper_name:meta_after_triage.name
          (Event_queue_settlement_failed message)
    in
    let requeue_unsettled reason =
      match !claimed_lease with
      | None -> ()
      | Some _ when !lease_settled -> ()
      | Some lease ->
        (match
           settle_claimed_lease
             ~base_path:ctx.config.base_path
             ~keeper_name:meta_after_triage.name
             ~settled_at:(Time_compat.now ())
             ~lease
             ~settlement:(Keeper_registry_event_queue.Requeue reason)
         with
         | Ok
             ( Keeper_registry_event_queue.Settled _
             | Keeper_registry_event_queue.Already_settled _ ) ->
           lease_settled := true
         | Error message ->
           Log.Keeper.error
             "registry: failed to requeue unsettled lease keeper=%s: %s"
             meta_after_triage.name
             message)
    in
    try
      (match
         project_transition_outbox
           ~base_path:ctx.config.base_path
           ~keeper_name:meta_after_triage.name
       with
       | Ok () -> ()
       | Error message -> raise (Event_queue_settlement_failed message));
      (* RFC-0310 §3.3: before intake, surface any live goal that has gone
         stale as a Goal_stagnation stimulus so it flows through the normal
         event-queue intake below and drives this turn. The producer is
         edge-gated (episode key = goal_id + updated_at) and deduped against
         the reaction ledger, so re-scanning an unadvanced goal each tick does
         not re-enqueue — no blind cadence is introduced here. *)
      (if meta_after_triage.active_goal_ids <> []
       then
         ignore
           (Keeper_goal_stagnation_wake.enqueue_goal_stagnation_wakes
              ~config:ctx.config
              ~keeper_name:meta_after_triage.name
              ~active_goal_ids:meta_after_triage.active_goal_ids
              ~now:(Time_compat.now ())
              ~threshold_sec:
                (float_of_int
                   (Keeper_config.keeper_goal_stagnation_threshold_sec ()))
              ()));
      let single_claim_admission =
        match
          Keeper_failure_judge.claim_eligibility
            ~keeper_name:meta_after_triage.name
        with
        | Keeper_failure_judge.Claim_eligible -> Admit_ready_single
        | Keeper_failure_judge.Claim_deferred_by_runtime_pacing _ ->
          Defer_failure_judgment
      in
      let event_intake =
        heartbeat_event_intake
          ~single_claim_admission
          ~ctx
          ~meta_after_triage
          ~pending_board_events
      in
      consumed_stimuli := event_intake.consumed_stimuli;
      claimed_lease := event_intake.claimed_lease;
      let failure_judgment =
        match failure_judgment_of_stimuli event_intake.consumed_stimuli with
        | Ok judgment -> judgment
        | Error message -> raise (Event_queue_settlement_failed message)
      in
      let judgment_control_turn = Option.is_some failure_judgment in
      (match event_intake.event_queue_claim_error with
       | None -> ()
       | Some message -> record_settlement_failure message);
      let pending_board_events = event_intake.pending_board_events in
      let obs =
        Keeper_world_observation.observe
          ~pending_board_events:(Some pending_board_events)
          ~config:ctx.config
          ~meta:meta_after_triage
      in
      let scheduling =
        decide_keepalive_scheduling
          ~reactive_wake
          ~event_queue_triggers:event_intake.event_queue_triggers
          ~keeper_resilience_of_name:(fun keeper_name ->
            (* A durable judgment is the typed recovery path for the failure
               that made this Keeper unhealthy. Reapplying that derived health
               gate here would make recovery unreachable. Explicit lifecycle
               gates in [keeper_cycle_decision] remain authoritative. *)
            if judgment_control_turn
            then None
            else if Health.is_healthy ~agent_name:keeper_name
            then None
            else Some "unhealthy")
            (* RFC-0313 W3: with [pacing.mode = enforce] the scheduler
               consumes failure revisit pacing — the next turn waits until
               the earliest runtime revisit is eligible. Shadow mode keeps
               the pre-W3 behavior (pacing observed, never consulted).
               [next_due_remaining] (in-memory) is consulted first so the
               per-tick hot path only pays the [Runtime.pacing] toml read
               while a revisit is actually pending. *)
          ~pacing_block_of_name:(fun keeper_name ->
            if judgment_control_turn
            then
              (* Exact judge-runtime pacing is checked by stimulus intake
                 before durable claim. Rechecking after claim would recreate
                 the claim/requeue heartbeat loop. *)
              None
            else
              match Keeper_pacing_shadow.next_due_remaining ~keeper_name with
              | None -> None
              | Some _ as remaining
                when Keeper_pacing_shadow.pacing_enforced () ->
                remaining
              | Some _ -> None)
          ~stop
          ~meta:meta_after_triage
          obs
      in
      let turn_decision = scheduling.turn_decision in
      (* Manual reconcile blocker check removed — keepers no longer get
         stuck behind sticky blockers. Failed turns record evidence via
         Keeper_registry; recovery is autonomous (next turn's observation)
         or operator-driven (board/keeper_chat), not blocker-driven. *)
      let runtime_backpressure = scheduling.runtime_backpressure in
      let should_run_turn = scheduling.should_run_turn in
      let format_opt_int = function
        | Some value -> string_of_int value
        | None -> "-"
      in
      let verdict_strs = scheduling.verdict_reasons in
      let channel_str = scheduling.channel in
      if not should_run_turn
      then (
        (* #10008 fm3: emit per-reason skip counter so operators can
           see why proactive scheduler never fires for a given keeper.
           scholar/executor stayed at [proactive_count_total=0,
           last_proactive_ts=0.0] for 45+ min despite
           proactive_enabled=true — the info log alone buried the
           reason across many lines.  Labelled counter lets Grafana
           split [no_signal] vs [cooldown_pending] vs
           [scheduled_autonomous_disabled] so the bootstrap problem
           ("need signals to fire, need to fire to generate signals")
           is visible fleet-wide. *)
        List.iter
          (fun reason_str ->
             Otel_metric_store.inc_counter proactive_skip_reason_metric
               ~labels:[ "keeper", meta_after_triage.name; "reason", reason_str ]
               ())
          verdict_strs;
        (* #10940 follow-up — Otel_metric_store counters aggregate skip reasons
           across time, but operators need recent skip verdict context
           when diagnosing idle/quiet keepers. Stamping the registry on
           every skip preserves that local context. *)
        (match runtime_backpressure with
         | Runtime_admitted ->
           Keeper_registry.record_skip_reasons
             ~base_path:ctx.config.base_path
             meta_after_triage.name
             ~reasons:verdict_strs;
           Keeper_registry.touch_last_turn_ts
             ~base_path:ctx.config.base_path
             meta_after_triage.name
         | Runtime_backpressured { runtime_id; reason } ->
           record_runtime_backpressure_observation
             ~base_path:ctx.config.base_path
             ~keeper_name:meta_after_triage.name
             ~reason;
           Log.Keeper.info
             "keepalive turn backpressured for %s: runtime=%s reason=%s requested=[%s]"
             meta_after_triage.name
             runtime_id
             reason
             (String.concat "," verdict_strs));
        let paused_info =
          if meta_after_triage.paused
          then (
            let blocker_str =
              match meta_after_triage.runtime.last_blocker with
              | Some info ->
                let trimmed = String.trim info.detail in
                if String.equal trimmed ""
                then Keeper_meta_contract.blocker_class_to_string info.klass
                else trimmed
              | None -> "unknown"
            in
            let paused_since_sec =
              match
                Workspace_resilience.Time.parse_iso8601_opt meta_after_triage.updated_at
              with
              | Some ts -> int_of_float (max 0.0 (Time_compat.now () -. ts))
              | None -> -1
            in
            Printf.sprintf " blocker=%s paused_since=%ds" blocker_str paused_since_sec)
          else ""
        in
        let log_not_scheduled =
          match runtime_backpressure, turn_decision.verdict with
          | Runtime_admitted, Keeper_world_observation.Skip _ -> Log.Keeper.debug
          | _ -> Log.Keeper.info
        in
        log_not_scheduled
          "keepalive turn not scheduled for %s: should_run=%b channel=%s reasons=[%s] \
           idle=%ds since_last=%s idle_gate=%s cooldown=%s task_cooldown=%s%s"
          meta_after_triage.name
          turn_decision.should_run
          channel_str
          (String.concat "," verdict_strs)
          obs.idle_seconds
          (Keeper_keepalive_signal.format_since_last_scheduled_autonomous
             turn_decision.since_last_scheduled_autonomous)
          (format_opt_int turn_decision.idle_gate_sec)
          (format_opt_int turn_decision.effective_cooldown)
          (format_opt_int turn_decision.task_reactive_cooldown)
          paused_info);
      if should_run_turn
      then
        Log.Keeper.info
          "keepalive turn scheduled for %s: channel=%s reasons=%s"
          meta_after_triage.name
          channel_str
          (String.concat "," verdict_strs);
      let tool_usage_entries =
        Keeper_registry.tool_usage_of
          ~base_path:ctx.config.base_path
          meta_after_triage.name
      in
      let available_tools =
        Keeper_tool_policy.keeper_allowed_tool_names meta_after_triage
      in
      let tool_diversity_summary =
        let stats = Keeper_tool_diversity.stats_of_registry_entries tool_usage_entries in
        Keeper_tool_diversity.compute_diversity ~available_tools stats
      in
      Keeper_tool_diversity.record_underused_tool_metrics
        ~keeper_name:meta_after_triage.name
        ~available_tools
        tool_diversity_summary;
      (* Phase A2: record decision in audit trail (skip all work when disabled) *)
      if Keeper_decision_audit.audit_enabled ()
      then (
        let audit_wall_clock = Time_compat.now () in
        let tool_diversity_entropy =
          if tool_usage_entries = []
          then None
          else Some tool_diversity_summary.normalized_entropy
        in
        Keeper_decision_audit.append
          ~keeper_name:meta_after_triage.name
          (Keeper_decision_audit.make
             ~cycle_id:
               (Printf.sprintf
                  "cycle-%s-%Ld"
                  meta_after_triage.name
                  (Int64.of_float (audit_wall_clock *. 1000.0)))
             ~keeper_name:meta_after_triage.name
             ~generation:meta_after_triage.runtime.generation
             ~heartbeat_verdict:Keeper_heartbeat_smart.Emit
             ~turn_verdict:turn_decision.verdict
             ~wall_clock:audit_wall_clock
             ?tool_diversity_entropy
             ());
        Keeper_decision_audit.flush_if_needed
          ~base_path:ctx.config.base_path
          ~keeper_name:meta_after_triage.name);
      let meta_after_cycle =
        if Atomic.get stop
        then meta_after_triage
        else if should_run_turn
        then (
          (* fd/disk pressure and typed Blocking HITL ownership are pre-checked
             by [classify_turn_intake_admission] in [run_heartbeat_loop] BEFORE
             stimulus intake, so this branch is reached only when a turn is
             admitted. The four prior inline pressure gates here were removed: they
             ran AFTER intake had already consumed the stimulus, forcing a
             consume/requeue churn loop, and logged only at DEBUG (a silent skip). *)
          record_schedule_due_turn_started_reactions
            ~ctx
            ~keeper_name:meta_after_triage.name
            !consumed_stimuli;
          let event_bus = Keeper_event_bus.get () in
          (* A [Hitl_resolved] wake is the SSOT for both continuation delivery
             and an optional exact-action grant. The unified turn derives those
             two cycle-scoped views from this single typed resolution. First
             consumed resolution wins; other lanes leave this [None]. *)
          let hitl_resolution =
            List.find_map
              (fun (stim : Keeper_event_queue.stimulus) ->
                match stim.Keeper_event_queue.payload with
                | Keeper_event_queue.Hitl_resolved resolution ->
                  Some resolution
                | _ -> None)
              !consumed_stimuli
          in
          (* Non-board intake consumes exactly one stimulus per turn. Project
             its exact reply route without choosing between wake families or
             coalescing unrelated connector conversations. Board batches carry
             no continuation channel and therefore leave this [None]. *)
          let continuation_delivery_channel =
            match !consumed_stimuli with
            | [ { Keeper_event_queue.payload = Hitl_resolved resolution; _ } ]
              when Keeper_continuation_channel.is_routable resolution.channel ->
              Some resolution.channel
            | [ { Keeper_event_queue.payload = Fusion_completed completion; _ } ]
              when Keeper_continuation_channel.is_routable completion.channel ->
              Some completion.channel
            | [] | [ _ ] | _ :: _ :: _ -> None
          in
          (* #16 (38-bug campaign PR-5): [reactive_wake] tells us this cycle
             was triggered by an external signal rather than the proactive
             cadence tick, but by itself does not say *which* stimulus (or
             whether the event queue drained anything at all). Pairing it
             with [!consumed_stimuli] — already drained above, unchanged
             until the post-turn ack/requeue below — gives
             [mark_turn_started] a total, typed answer instead of the
             boolean the registry previously discarded. *)
          let wake : Keeper_registry.wake_reason =
            if reactive_wake
            then
              Keeper_registry.Woken
                (List.map
                   (fun (stim : Keeper_event_queue.stimulus) ->
                      stim.Keeper_event_queue.payload)
                   !consumed_stimuli)
            else Keeper_registry.Proactive_tick
          in
          let cycle_outcome =
            run_keeper_cycle
              ?event_bus
              ?hitl_resolution
              ?continuation_delivery_channel
              ~ctx
              ~meta_after_triage
              ~stop
              ~obs
              ~turn_decision
              ~shared_context
              ~wake
              ?failure_judgment
              ()
          in
          cycle_outcome_ref := Some cycle_outcome;
          Cycle.meta cycle_outcome)
        else meta_after_triage
      in
      (* Queue ownership follows the typed cycle outcome.  Pending removal,
         lease removal, an optional judgment successor, and the transition
         outbox receipt commit in one event-queue.json rename. *)
      (match !claimed_lease with
       | None ->
         (match !cycle_outcome_ref with
          | Some (Cycle.Failed { failure; _ }) ->
            (match failure.Keeper_unified_turn.route with
             | Keeper_runtime_failure_route.Escalate_judgment
                 { judgment; provenance; detail } ->
               let successor =
                 failure_judgment_successor
                   ~arrived_at:(Time_compat.now ())
                   failure
                   judgment
                   provenance
                   detail
               in
               (match
                  Keeper_registry_event_queue.enqueue_durable_result
                    ~base_path:ctx.config.base_path
                    meta_after_triage.name
                    successor
                with
                | Ok () -> ()
                | Error message ->
                  Log.Keeper.error
                    "registry: unleased failure judgment enqueue failed keeper=%s: %s"
                    meta_after_triage.name
                    message;
                  record_settlement_failure message)
             | Keeper_runtime_failure_route.Retry_after_pacing _
             | Keeper_runtime_failure_route.Rotate_now _ ->
               ())
          | Some (Cycle.Judgment_settled _) ->
            record_settlement_failure
              "failure judgment completed without an owning event queue lease"
          | Some
              ( Cycle.Completed _
              | Cycle.Cancelled _
              | Cycle.Skipped _
              | Cycle.Busy _ )
          | None ->
            ())
       | Some lease ->
         let settled_at = Time_compat.now () in
         let settlement =
           settlement_of_cycle_outcome
             ~settled_at
             ~stop_requested:(Atomic.get stop)
             ~lease
             !cycle_outcome_ref
         in
         (match
            settle_claimed_lease
              ~base_path:ctx.config.base_path
              ~keeper_name:meta_after_triage.name
              ~settled_at
              ~lease
              ~settlement
          with
          | Error message ->
            Log.Keeper.error
              "registry: durable lease settlement failed keeper=%s: %s"
              meta_after_triage.name
              message;
            record_settlement_failure message
          | Ok
              ( Keeper_registry_event_queue.Settled _
              | Keeper_registry_event_queue.Already_settled _ ) ->
            lease_settled := true;
            (match
               project_transition_outbox
                 ~base_path:ctx.config.base_path
                 ~keeper_name:meta_after_triage.name
             with
             | Error message -> raise (Event_queue_settlement_failed message)
             | Ok () -> ());
            if settlement_is_ack settlement
            then
              mark_connector_attention_ignored_after_turn
                ~base_path:ctx.config.base_path
                ~keeper_name:meta_after_triage.name
                (connector_attention_event_ids_of_stimuli !consumed_stimuli)));
      { meta = meta_after_cycle; cycle_crashed = !settlement_failed }
    with
    | Eio.Cancel.Cancelled _ as e ->
      let backtrace = Printexc.get_raw_backtrace () in
      requeue_unsettled Keeper_registry_event_queue.Cancelled;
      Printexc.raise_with_backtrace e backtrace
    | Keeper_registry.Keeper_fiber_crash as e ->
      let backtrace = Printexc.get_raw_backtrace () in
      requeue_unsettled Keeper_registry_event_queue.Cycle_crashed;
      Printexc.raise_with_backtrace e backtrace
    | exn ->
      requeue_unsettled Keeper_registry_event_queue.Cycle_crashed;
      (* T6 audit: keep the fiber alive, but surface the crash as a
         turn failure so the caller does not dispatch
         [Turn_succeeded] for a cycle that never completed. *)
      record_crashed_cycle_failure
        ~base_path:ctx.config.base_path
        ~keeper_name:meta_after_triage.name
        exn;
      { meta = meta_after_triage; cycle_crashed = true })
;;

let refresh_work_as_heartbeat = Keeper_heartbeat_loop_refresh_work.refresh_work_as_heartbeat

let dispatch_recurring_keepalive = Keeper_heartbeat_loop_dispatch_recurring.dispatch_recurring_keepalive

(** Whether a smart-heartbeat decision should allow the keepalive
    cycle to continue evaluating turns.

    Pure for testability. The full [run_smart_heartbeat_gate] layers
    side-effects (sleep, cycle-timestamp update) on top of this
    decision. Regression guard for the "claim-holding keeper
    starvation" bug: [Skip_busy] must NOT gate cycle execution,
    otherwise any keeper with [current_task_id=Some _] is blocked
    from ever running a turn (discovered 2026-04-25 — 8/14 keepers
    frozen with claimed tasks). *)
(* Visibility-gate primitives extracted to
   [Keeper_heartbeat_visibility_gate] (godfile decomp). *)
let smart_heartbeat_cycle_continues =
  Keeper_heartbeat_visibility_gate.smart_heartbeat_cycle_continues
;;

let cycle_continues_after_wake = Keeper_heartbeat_visibility_gate.cycle_continues_after_wake

let unobserved_visibility_idle_window_s =
  Keeper_heartbeat_visibility_gate.unobserved_visibility_idle_window_s
;;

let visible_consumer_count = Keeper_heartbeat_visibility_gate.visible_consumer_count
let visibility_gate_decision = Keeper_heartbeat_visibility_gate.visibility_gate_decision

let run_smart_heartbeat_gate
      ~(config : Workspace.config)
      ~(clock : _ Eio.Time.clock)
      ~(stop : bool Atomic.t)
      ~(wakeup : bool Atomic.t)
      ~(meta_current : keeper_meta)
      ~(smart_hb_enabled : unit -> bool)
      ~(smart_hb_config : Keeper_heartbeat_smart.config)
      ~(last_successful_heartbeat_ts : float ref)
      ~(last_heartbeat_cycle_ts : float ref)
      ~(wake_source : Keeper_keepalive_signal.sleep_outcome ref)
  : bool
  =
  let smart_hb_decision =
    if smart_hb_enabled ()
    then (
      let agent_status = keeper_agent_status meta_current in
      Keeper_heartbeat_smart.should_emit
        ~config:smart_hb_config
        ~agent_status
        ~last_activity:!last_successful_heartbeat_ts
        ~last_heartbeat:!last_heartbeat_cycle_ts)
    else Keeper_heartbeat_smart.Emit
  in
  (* RFC-0020 Rule 2: the Event Layer queue overrides the Smart Heartbeat
     policy. When the queue holds an unprocessed stimulus, force [Emit]
     regardless of the busy/idle decision so the next cycle consumes the
     stimulus on time. Pinned by KeeperEventQueue.tla
     QueueNeverStarvedBySkip invariant. *)
  let pending_signal_present =
    lazy
      (let queue =
         Keeper_registry_event_queue.snapshot
           ~base_path:config.base_path
           meta_current.name
       in
       if not (Keeper_event_queue.is_empty queue)
       then (
         Otel_metric_store.inc_counter
           Keeper_metrics.(to_string EventQueueOverride)
           ~labels:[ "keeper", meta_current.name; "reason", "event_queue" ]
           ();
         true)
       else (
         if
           Keeper_world_observation.durable_signal_present
             ~pending_board_events:None
             ~config
             ~meta:meta_current
         then (
           Otel_metric_store.inc_counter
             Keeper_metrics.(to_string EventQueueOverride)
             ~labels:[ "keeper", meta_current.name; "reason", "durable_state" ]
             ();
           Log.Keeper.info
             "smart heartbeat: durable signal present - cycle resumed before stale \
              watchdog";
           true)
         else false))
  in
  let smart_hb_decision =
    if Keeper_heartbeat_smart.should_emit_now smart_hb_decision
    then smart_hb_decision
    else (
      (* Skip_busy already continues the cycle (no idle sleep), so
         probing the world-observation signal here would be redundant
         backlog/board I/O.  The durable-signal probe only matters when
         the gate would otherwise sleep on Skip_idle. *)
      match smart_hb_decision with
      | Keeper_heartbeat_smart.Skip_idle _ when Lazy.force pending_signal_present ->
        Keeper_heartbeat_smart.Emit
      | Keeper_heartbeat_smart.Skip_idle _
      | Keeper_heartbeat_smart.Skip_busy
      | Keeper_heartbeat_smart.Emit -> smart_hb_decision)
  in
  let smart_hb_decision =
    match smart_hb_decision with
    | Keeper_heartbeat_smart.Emit when smart_hb_enabled () ->
      let consumers = visible_consumer_count () in
      let now = Time_compat.now () in
      let delay_possible =
        consumers <= 0
        && !last_heartbeat_cycle_ts > 0.0
        && now -. !last_heartbeat_cycle_ts < unobserved_visibility_idle_window_s
      in
      let gated =
        if delay_possible
        then
          visibility_gate_decision
            ~visible_consumers:consumers
            ~has_pending_signal:(Lazy.force pending_signal_present)
            ~now
            ~last_heartbeat_cycle_ts:!last_heartbeat_cycle_ts
            smart_hb_decision
        else smart_hb_decision
      in
      (match gated with
       | Keeper_heartbeat_smart.Skip_idle _ ->
         Otel_metric_store.inc_counter
           proactive_skip_reason_metric
           ~labels:[ "keeper", meta_current.name; "reason", "no_visible_consumers" ]
           ();
         Log.Keeper.debug
           "smart heartbeat: no visible consumers - delaying idle turn dispatch"
       | Keeper_heartbeat_smart.Emit | Keeper_heartbeat_smart.Skip_busy -> ());
      gated
    | Keeper_heartbeat_smart.Emit
    | Keeper_heartbeat_smart.Skip_busy
    | Keeper_heartbeat_smart.Skip_idle _ -> smart_hb_decision
  in
  (* Run side-effects (idle sleep, cycle-timestamp update) per the
     decision, then delegate the gate answer to [cycle_continues_after_wake]
     so the [Skip_idle + Woken] case can promote to [true] (closing the
     [MissedWakeup] gap in KeeperHeartbeat.tla — sibling of #10078). The
     pure helpers stay testable without an Eio runtime. *)
  let sleep_outcome =
    match smart_hb_decision with
    | Keeper_heartbeat_smart.Skip_busy ->
      Log.Keeper.debug
        "smart heartbeat: busy (task=%s) — cycle continues, broadcast may be debounced"
        (match meta_current.current_task_id with
         | Some t -> Keeper_id.Task_id.to_string t
         | None -> "?");
      last_heartbeat_cycle_ts := Time_compat.now ();
      Keeper_keepalive_signal.Timeout
    | Keeper_heartbeat_smart.Skip_idle next_time ->
      let wait = Float.max 1.0 (next_time -. Time_compat.now ()) in
      Log.Keeper.debug "smart heartbeat: skip (idle, next in %.1fs)" wait;
      Observations.record_smart_idle_sleep_admission
        ~base_path:config.base_path
        ~keeper_name:meta_current.name;
      let jitter = wait *. 0.1 *. Random.float 1.0 in
      let outcome =
        Keeper_keepalive_signal.interruptible_sleep ~clock ~stop ~wakeup (wait +. jitter)
      in
      (match outcome with
       | Keeper_keepalive_signal.Woken ->
         (* External wakeup arrived during idle backoff: the keeper is
            no longer idle. Stamp the cycle timestamp so the next
            [should_emit] does not immediately re-classify as Skip_idle,
            and let the cycle proceed (presence/board/turn dispatch).
            Spec: KeeperHeartbeat.tla HeartbeatTick — turn_state must
            transition to "running". Otel_metric_store counter is the operator-
            visible positive signal for the #12271 fix path. *)
         Log.Keeper.info "smart heartbeat: idle wake — cycle resumed (post=consumed)";
         last_heartbeat_cycle_ts := Time_compat.now ();
         Otel_metric_store.inc_counter
           Keeper_metrics.(to_string SkipIdleWakeResumed)
           ~labels:[ "keeper", meta_current.name ]
           ()
       | Keeper_keepalive_signal.Timeout ->
         Observations.record_smart_idle_sleep_observation
           ~base_path:config.base_path
           ~keeper_name:meta_current.name
       | Keeper_keepalive_signal.Stopped -> ());
      (* Carry the idle-backoff sleep result forward so the turn evaluator can
         tell a broadcast-driven [Woken] from this keeper's own cadence
         [Timeout]. Only the real sleep (Skip_idle) writes here; Emit/Skip_busy
         synthesize [Timeout] without sleeping and must NOT clobber the prior
         inter-cycle wake source used by active keepers. *)
      wake_source := outcome;
      outcome
    | Keeper_heartbeat_smart.Emit ->
      last_heartbeat_cycle_ts := Time_compat.now ();
      Keeper_keepalive_signal.Timeout
  in
  cycle_continues_after_wake smart_hb_decision sleep_outcome
;;

let maybe_write_heartbeat_snapshot = Keeper_heartbeat_loop_snapshot_timing.maybe_write_heartbeat_snapshot
let record_keepalive_stage_timing = Keeper_heartbeat_loop_snapshot_timing.record_keepalive_stage_timing

(* Spec navigation (OCaml -> TLA+) — plan §19 Cycle 27 anchor for
   B1 (Heartbeat).  Authoritative spec mirror is
   specs/keeper-state-machine/KeeperHeartbeat.tla (Cycle 7 / Tier B1,
   PR #11408).

   The spec preamble cites this module by function name
   ([run_heartbeat_loop]); it used to carry a line number but iter 64
   N-2.a removed it — function names are stable, line numbers drift, and
   spec-preamble line refs are now guarded by
   scripts/audit-tla-ml-line-refs.sh (iter 64 N-2.c).  This comment is
   the authoritative reverse-direction citation; the OCaml-docstring
   side is guarded by scripts/audit-ocaml-spec-nav-line-refs.sh
   (iter 72 R-1.a).

   Action mapping (TLA+ -> OCaml):
     WakeupSignal     external code sets [wakeup] Atomic to true
                      (e.g., wakeup_keeper / operator_resume).
     HeartbeatTick    [Keeper_keepalive_signal.interruptible_sleep]
                      consumes the wakeup via
                      [Atomic.compare_and_set wakeup true false], then
                      the loop body services the pending event.
     TurnComplete     turn body finishes; loop returns to next sleep
                      cycle.
     MissedWakeup     bug action — the wakeup is observed and cleared
                      but the loop fails to start a turn.  In OCaml
                      this would be a regression where the
                      compare_and_set succeeds but the surrounding
                      branch returns early without dispatching.  The
                      spec's NoMissedSignals invariant catches that
                      drift; in code, the structural invariant is
                      that every successful compare_and_set is
                      followed by the dispatch path on the same loop
                      iteration. *)

let run_heartbeat_loop
      ~proactive_warmup_sec
      (ctx : _ context)
      (m : keeper_meta)
      (stop : bool Atomic.t)
      ~(wakeup : bool Atomic.t)
  : unit
  =
  let keepalive_started_ts = Time_compat.now () in
  let snapshot_interval_sec () =
    Runtime_params.get Governance_registry.keeper_snapshot_sec
  in
  let last_snapshot_ts = ref 0.0 in
  let consecutive_failures = ref 0 in
  (* Cycle 43: KeeperHeartbeat.tla [turn_state] mirror. Single-fiber by
     construction — only this loop body reads/writes the ref. *)
  let turn_running = ref false in
  (* Phase 0: per-stage timing ring buffer.
     ring_size is read once at fiber start — mid-flight resize requires
     ring buffer reallocation, so new values apply on next fiber restart. *)
  let ring_sz = Keeper_keepalive_signal.stage_timing_ring_size () in
  let timing_ring =
    Array.make
      ring_sz
      { presence_ms = 0.0
      ; snapshot_ms = 0.0
      ; board_ms = 0.0
      ; turn_ms = 0.0
      ; recurring_ms = 0.0
      }
  in
  let timing_cursor = ref 0 in
  let timing_filled = ref 0 in
  (* Phase 1: work-as-heartbeat freshness tracking.
     Updated ONLY on Workspace.heartbeat success after turn. *)
  let last_successful_heartbeat_ts = ref (Time_compat.now ()) in
  let work_as_hb () = Runtime_params.get Governance_registry.keeper_work_as_hb_enabled in
  let _max_silence () =
    Runtime_params.get Governance_registry.keeper_work_as_hb_max_silence_sec
  in
  (* Phase 2: smart heartbeat — adaptive scheduling via Keeper_heartbeat_smart *)
  let smart_hb_enabled () =
    Runtime_params.get Governance_registry.keeper_smart_hb_enabled
  in
  let smart_hb_config = Keeper_heartbeat_smart.default_config in
  let last_heartbeat_cycle_ts = ref 0.0 in
  (* Persistent OAS Context.t — created once per keeper lifecycle.
     OAS Context.t is a mutable cross-turn state container for values
     written directly into the shared context. This preserves shared
     metadata across turns, but per-turn context_injector-local timing
     and tool-call counters are recreated inside run_turn and therefore
     do not accumulate for the full keeper lifecycle. *)
  let shared_context = Agent_sdk.Context.create () in
  (* Mtime-based change detection for keeper meta disk reads.
     Avoids re-parsing the JSON file on every heartbeat cycle when
     no operator has modified it.  Initialized to 0.0 so the first
     cycle always reads. *)
  let last_meta_mtime = ref 0.0 in
  (* Wake-source carry (thundering-herd fix). Records whether the most recent
     sleep ended via an external broadcast wakeup ([Woken]) or this keeper's own
     cadence timer ([Timeout]). Read at turn dispatch so a broadcast-driven early
     wake does not let the GLOBAL task backlog drive a turn on every keeper at
     once. Single-fiber owned, like the other loop-local refs above. *)
  let last_wake_source = ref Keeper_keepalive_signal.Timeout in
  let rec loop () =
    if Atomic.get stop
    then ()
    else (
      (* Yield before each heartbeat cycle to prevent N keeper fibers
               from monopolizing the Eio scheduler during CPU-bound phases
               (tool filtering, snapshot construction, prompt building). *)
      Eio_guard.fair_yield ();
      (* Phase 0: timing markers *)
      let t_presence_start = Time_compat.now () in
      let disk_meta_opt, new_meta_mtime =
        match read_meta_if_changed ctx.config m.name ~last_mtime:!last_meta_mtime with
        | Some (latest, new_mtime) -> Some latest, Some new_mtime
        | None -> None, None
      in
      Option.iter (fun new_mtime -> last_meta_mtime := new_mtime) new_meta_mtime;
      let meta_current =
        effective_keepalive_meta
          ~base_path:ctx.config.base_path
          ~fallback:m
          ~disk_meta_opt
      in
      let meta_current =
        match repair_identity_drift_for_keepalive ~ctx meta_current with
        | Some repaired -> repaired
        | None -> meta_current
      in
      (* Sync disk meta to registry so dashboard reads live values.  #5364.
         When disk meta is unchanged we still prefer the registry copy because
         runtime writes update it via the write_meta hook. This keeps
         continuity/runtime fields fresh even if disk mtime does not advance
         between rapid writes inside a single loop window. *)
      let registry_meta =
        match Keeper_registry.get ~base_path:ctx.config.base_path meta_current.name with
        | Some entry -> entry.meta
        | None -> m
      in
      if meta_current != registry_meta
      then
        Keeper_registry.update_meta
          ~base_path:ctx.config.base_path
          meta_current.name
          meta_current;
      if
        run_smart_heartbeat_gate
          ~config:ctx.config
          ~clock:ctx.clock
          ~stop
          ~wakeup
          ~meta_current
          ~smart_hb_enabled
          ~smart_hb_config
          ~last_successful_heartbeat_ts
          ~last_heartbeat_cycle_ts
          ~wake_source:last_wake_source
      then (
        (* Phase 1: sync presence and emit heartbeat metric *)
        let meta_current =
          sync_keeper_presence
            ~ctx
            ~meta_current
            ~consecutive_failures
            ~last_successful_heartbeat_ts
        in
        (* RFC-0002: fiber crash on heartbeat threshold breach *)
        if
          !consecutive_failures
          >= Keeper_heartbeat_snapshot.max_consecutive_heartbeat_failures ()
        then (
          Keeper_registry.set_failure_reason
            ~base_path:ctx.config.base_path
            m.name
            (Some (Keeper_registry.Heartbeat_consecutive_failures !consecutive_failures));
          raise Keeper_registry.Keeper_fiber_crash);
        let t_presence_end = Time_compat.now () in
        let now_ts = t_presence_end in
        (* IR-4 fix: expire stale approval-queue entries every heartbeat cycle.
           Uses [Keeper_config.approval_queue_stale_max_wait_sec] so the timeout
           is explicit and discoverable. Critical entries are excluded by
           expire_stale itself, so only Low/Medium/High are swept. *)
        Keeper_approval_queue.expire_stale
          ~max_wait_s:Keeper_config.approval_queue_stale_max_wait_sec;
        let t_snapshot_start = now_ts in
        maybe_write_heartbeat_snapshot
          ~ctx
          ~meta_current
          ~now_ts
          ~consecutive_hb_failures:!consecutive_failures
          ~last_snapshot_ts
          ~snapshot_interval_sec:(snapshot_interval_sec ())
          ~timing_ring
          ~timing_filled:!timing_filled;
        let t_snapshot_end = Time_compat.now () in
        let t_board_start = t_snapshot_end in
        (* Compute warmup state BEFORE board collection so cursor
                 is not advanced while keeper cannot act on events. *)
        let proactive_warmup_elapsed =
          proactive_warmup_sec <= 0
          || now_ts -. keepalive_started_ts >= float_of_int proactive_warmup_sec
        in
        (* Turn-intake preconditions (typed lifecycle, fd/disk pressure, and a
           typed Blocking HITL lane) are evaluated ONCE here, BEFORE board collection and durable
           stimulus intake. A blocked keeper therefore neither advances the
           board cursor nor leases and requeues the same event every heartbeat.
           Nonblocking approvals never enter this gate.
           The fleet observer logs one WARN per pressure episode (was four per-turn
           DEBUG gates inside run_keepalive_unified_turn, now removed). last_turn_ts
           is refreshed on the blocked path so the RFC-0250 stale-turn watchdog
           (Keeper_supervisor.assess_stale_run) does not crash-restart a keeper that
           is correctly suspended by a shared circuit breaker rather than stalled. *)
        let turn_admission =
          Keeper_pressure_admission_observer.decide_observed
            ~masc_root:(Workspace.masc_root_dir ctx.config)
            ~active_keepers:(Keeper_registry.count_running ())
            ()
        in
        let approval_pending =
          Keeper_approval_queue.has_blocking_pending_for_keeper
            ~keeper_name:meta_current.name
        in
        let lifecycle_state =
          Keeper_lifecycle_admission.state
            ~paused:meta_current.paused
            ~latched_reason:meta_current.latched_reason
        in
        let intake_admission =
          classify_turn_intake_admission
            ~lifecycle:
              (Keeper_lifecycle_admission.admit_autonomous lifecycle_state)
            ~pressure:turn_admission
            ~blocking_approval_pending:approval_pending
        in
        let admitted_turn =
          match intake_admission with
          | Intake_admitted -> true
          | Intake_lifecycle_blocked _
          | Intake_pressure_blocked _
          | Intake_blocking_approval_pending -> false
        in
        let lifecycle_blocked =
          match intake_admission with
          | Intake_lifecycle_blocked _ -> true
          | Intake_admitted
          | Intake_pressure_blocked _
          | Intake_blocking_approval_pending -> false
        in
        let terminal_lifecycle_blocked =
          match intake_admission with
          | Intake_lifecycle_blocked
              Keeper_lifecycle_admission.Autonomous_dead_tombstone -> true
          | Intake_lifecycle_blocked (Keeper_lifecycle_admission.Autonomous_paused _) -> false
          | Intake_admitted
          | Intake_pressure_blocked _
          | Intake_blocking_approval_pending -> false
        in
        let keeper_health_blocker =
          if Health.is_healthy ~agent_name:meta_current.name then None else Some "unhealthy"
        in
        let runtime_id = Keeper_meta_contract.runtime_id_of_meta meta_current in
        let provider_cooldown_remaining_sec =
          Keeper_world_observation.provider_cooldown_remaining_sec_for_runtime
            ~keeper_name:meta_current.name
            ~runtime_id
        in
        let provider_cooldown_pending = Option.is_some provider_cooldown_remaining_sec in
        (match intake_admission with
         | Intake_admitted -> ()
         | Intake_lifecycle_blocked denial ->
           let reason =
             Keeper_lifecycle_admission.autonomous_denial_to_wire denial
           in
           Otel_metric_store.inc_counter
             Keeper_metrics.(to_string LifecycleDispatchRejections)
             ~labels:
               [ "keeper", meta_current.name
               ; "event", "heartbeat_pre_intake"
               ; "reason", reason
               ]
             ();
           Keeper_registry.record_skip_reasons
             ~base_path:ctx.config.base_path
             meta_current.name
             ~reasons:[ "lifecycle_" ^ reason ];
           Log.Keeper.info
             "%s: heartbeat intake denied by lifecycle admission: %s"
             meta_current.name
             reason;
           if terminal_lifecycle_blocked
           then
             (* A dead tombstone owns no runnable lane. Ordinary pause keeps
                its lane parked so an explicit resume remains local. *)
             Atomic.set stop true
           else
             Keeper_registry.touch_last_turn_ts
               ~base_path:ctx.config.base_path
               meta_current.name
         | Intake_pressure_blocked block ->
           Keeper_registry.record_skip_reasons
             ~base_path:ctx.config.base_path
             meta_current.name
             ~reasons:[ Keeper_pressure_admission.skip_reason block ];
           Keeper_registry.touch_last_turn_ts
             ~base_path:ctx.config.base_path
             meta_current.name
         | Intake_blocking_approval_pending ->
           Keeper_registry.record_skip_reasons
             ~base_path:ctx.config.base_path
             meta_current.name
             ~reasons:
               [ Keeper_world_observation.skip_reason_to_string
                   Keeper_world_observation.Approval_pending
               ];
           Keeper_registry.touch_last_turn_ts
             ~base_path:ctx.config.base_path
             meta_current.name);
        (match keeper_health_blocker with
         | None -> ()
         | Some blocker when admitted_turn && proactive_warmup_elapsed ->
           record_runtime_backpressure_observation
             ~base_path:ctx.config.base_path
             ~keeper_name:meta_current.name
             ~reason:("keeper_health_" ^ blocker)
         | Some _ -> ());
        (match provider_cooldown_remaining_sec with
         | None -> ()
         | Some remaining_sec when admitted_turn && proactive_warmup_elapsed ->
           Keeper_registry.record_skip_reasons
             ~base_path:ctx.config.base_path
             meta_current.name
             ~reasons:
               [ Keeper_world_observation.skip_reason_to_string
                   (Keeper_world_observation.Provider_cooldown_pending { remaining_sec })
               ];
           Keeper_registry.touch_last_turn_ts
             ~base_path:ctx.config.base_path
             meta_current.name
         | Some _ -> ());
        let pending_board_events, meta_after_triage =
          if admitted_turn
          then
            collect_keepalive_board_events
              ~ctx
              ~meta_current
              ~proactive_warmup_elapsed
              ~approval_pending
              ~keeper_backpressured:(Option.is_some keeper_health_blocker)
              ~provider_cooldown_pending
          else [], meta_current
        in
        let t_board_end = Time_compat.now () in
        let t_turn_start = t_board_end in
        let turn_outcome =
          if not admitted_turn
          then { meta = meta_current; cycle_crashed = false }
          else (
            (* Cycle 43: KeeperHeartbeat.tla TurnComplete bracket — the
               [turn_running] flag toggles around the dispatch and the
               pre/post guards mirror the spec's [turn_state] transition
               "running" -> "idle". *)
            turn_running := true;
            (* [Woken] => this cycle was triggered by an external broadcast, not
               the keeper's own cadence; suppress global-backlog-driven turns to
               avoid the all-keeper stampede. *)
            let reactive_wake =
              match !last_wake_source with
              | Keeper_keepalive_signal.Woken -> true
              | Keeper_keepalive_signal.Timeout | Keeper_keepalive_signal.Stopped ->
                false
            in
            let r =
              run_keepalive_unified_turn
                ~ctx
                ~meta_after_triage
                ~pending_board_events
                ~stop
                ~proactive_warmup_elapsed
                ~reactive_wake
                ~shared_context
            in
            Keeper_keepalive_signal.pre_turn_complete_heartbeat ~turn_running;
            turn_running := false;
            Keeper_keepalive_signal.post_turn_complete_heartbeat ~turn_running;
            r)
        in
        let meta_after_proactive = turn_outcome.meta in
        if not lifecycle_blocked
        then (
          (* Turn failure threshold: registry tracks count (via unified_turn,
             and via [record_crashed_cycle_failure] for swallowed cycle
             exceptions), keepalive raises to terminate the fiber for
             supervisor restart. A lifecycle-blocked cycle did not run a turn
             and must not emit a false [Turn_succeeded]. *)
          let turn_fail_count =
            Keeper_registry.get_turn_failures
              ~base_path:ctx.config.base_path
              m.name
          in
          (* RFC-0002: dispatch turn status event *)
          Keeper_keepalive_signal.dispatch_keepalive_event
            ~ctx
            ~keeper_name:m.name
            (turn_status_event
               ~turn_fail_count
               ~max_allowed:
                 (Keeper_heartbeat_snapshot.max_consecutive_turn_failures ()));
          if
            turn_fail_count
            >= Keeper_heartbeat_snapshot.max_consecutive_turn_failures ()
          then (
            Keeper_registry.set_failure_reason
              ~base_path:ctx.config.base_path
              m.name
              (Some (Keeper_registry.Turn_consecutive_failures turn_fail_count));
            raise Keeper_registry.Keeper_fiber_crash);
          (* Phase 1: work-as-heartbeat — renew point (b).
             After turn, call Workspace.heartbeat to prove workspace I/O health.
             On success: refresh freshness lease + reset consecutive_failures.
             On failure: leave timestamp unchanged → presence sync resumes next cycle.
             T6 audit: a crashed cycle proves nothing about health — do not
             refresh the lease or reset consecutive_failures for it. *)
          if turn_outcome.cycle_crashed
          then
            Log.Keeper.info
              "%s: skipping work-as-heartbeat refresh after crashed keepalive cycle"
              m.name
          else
            refresh_work_as_heartbeat
              ~ctx
              ~meta_after_proactive
              ~proactive_warmup_elapsed
              ~work_as_hb
              ~last_successful_heartbeat_ts
              ~consecutive_failures);
        let t_turn_end = Time_compat.now () in
        let t_recurring_start = t_turn_end in
        (* Recurring task dispatch (#3190) *)
        let _recurring_dispatched =
          if lifecycle_blocked
          then false
          else dispatch_recurring_keepalive ~ctx ~meta_after_proactive ~now_ts
        in
        let t_recurring_end = Time_compat.now () in
        let base =
          if smart_hb_enabled ()
          then
            Keeper_heartbeat_smart.effective_interval
              ~config:smart_hb_config
              ~last_activity:!last_successful_heartbeat_ts
          else float_of_int (Keeper_heartbeat_snapshot.keepalive_interval_sec ())
        in
        (* Phase 0: push stage timing to ring buffer *)
        record_keepalive_stage_timing
          ~timing_ring
          ~timing_cursor
          ~timing_filled
          ~ring_sz
          ~t_presence_start
          ~t_presence_end
          ~t_snapshot_start
          ~t_snapshot_end
          ~t_board_start
          ~t_board_end
          ~t_turn_start
          ~t_turn_end
          ~t_recurring_start
          ~t_recurring_end;
        let jitter =
          base *. Env_config.KeeperKeepalive.jitter_factor *. Random.float 1.0
        in
        (* Carry the inter-cycle sleep result into the next iteration so the
           turn evaluator can distinguish a broadcast wakeup ([Woken]) from this
           keeper's own cadence ([Timeout]). For active keepers this is the only
           sleep, so it is the dominant wake-source signal. *)
        last_wake_source :=
          Keeper_keepalive_signal.interruptible_sleep
            ~clock:ctx.clock
            ~stop
            ~wakeup
            (base +. jitter));
      if Atomic.get stop then () else loop ())
  in
  loop ()
;;
