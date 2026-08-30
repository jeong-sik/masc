(* keeper_heartbeat_loop — the main heartbeat loop body and its helpers:
   presence sync, board event collection, in-turn liveness pulse,
   unified turn dispatch, exact cadence sleep, stage timing recording,
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
module Deferred_runtime_store = Keeper_deferred_runtime_lane_store

(* Presence/identity sync extracted to
   [Keeper_heartbeat_loop_presence] (godfile decomp). *)
let effective_keepalive_meta = Keeper_heartbeat_loop_presence.effective_keepalive_meta
let keeper_agent_status = Keeper_heartbeat_loop_presence.keeper_agent_status
let sync_keeper_presence = Keeper_heartbeat_loop_presence.sync_keeper_presence

(* Pending board-event collection extracted to
   [Keeper_heartbeat_loop_board_events] (godfile decomp). *)
let collect_keepalive_board_events = Keeper_heartbeat_loop_board_events.collect_keepalive_board_events

let in_turn_liveness_pulse_interval_sec =
  Keeper_heartbeat_loop_in_turn_pulse.in_turn_liveness_pulse_interval_sec

let emit_in_turn_liveness_pulse =
  Keeper_heartbeat_loop_in_turn_pulse.emit_in_turn_liveness_pulse

let with_in_turn_liveness_pulse =
  Keeper_heartbeat_loop_in_turn_pulse.with_in_turn_liveness_pulse

(* Event-Layer stimulus intake extracted to [Keeper_heartbeat_stimulus_intake]
   (godfile decomp). Type + entry point are re-exported as transparent
   aliases so callers (incl. .mli consumers) stay byte-identical. *)
module Stimulus_intake = Keeper_heartbeat_stimulus_intake

let record_event_queue_stimulus_turn_started =
  Stimulus_intake.record_event_queue_stimulus_turn_started
;;

type heartbeat_event_intake = Stimulus_intake.heartbeat_event_intake = {
  pending_board_events : Keeper_world_observation.pending_board_event list;
  consumed_stimulus_count : int;
  consumed_stimuli : Keeper_event_queue.stimulus list;
  pending_selection : Keeper_event_queue_state.pending_selection option;
  consumed_selections : Keeper_event_queue_state.pending_selection list;
  event_queue_intake_error : Stimulus_intake.event_queue_intake_error option;
  event_queue_triggers : Keeper_world_observation.event_queue_trigger list;
}

type turn_intake_admission =
  | Intake_admitted
  | Intake_lifecycle_blocked of Keeper_lifecycle_admission.autonomous_denial

let classify_turn_intake_admission ~lifecycle =
  match lifecycle with
  | Keeper_lifecycle_admission.Autonomous_denied denial ->
    Intake_lifecycle_blocked denial
  | Keeper_lifecycle_admission.Autonomous_admitted -> Intake_admitted
;;

let heartbeat_event_intake = Stimulus_intake.heartbeat_event_intake

(* Keepalive scheduling decision (record + decide function) extracted to
   [Keeper_heartbeat_loop_scheduling] (godfile decomp). *)
type keepalive_scheduling_decision = Keeper_heartbeat_loop_scheduling.keepalive_scheduling_decision = {
  turn_decision : Keeper_world_observation.keeper_cycle_decision;
  should_run_turn : bool;
  verdict_reasons : string list;
  channel : string;
}

let decide_keepalive_scheduling = Keeper_heartbeat_loop_scheduling.decide_keepalive_scheduling

let should_run_turn_after_event_intake
      ~scheduled
      ~consumed_stimulus_count
      ~event_queue_intake_error
  =
  scheduled
  &&
  match event_queue_intake_error with
  | None -> true
  | Some (Stimulus_intake.Transient_board_read _) -> consumed_stimulus_count > 0
  | Some (Stimulus_intake.Pending_selection_failed _) -> false
;;

let provider_timeout_observation_reasons =
  Observations.provider_timeout_observation_reasons
;;

let record_provider_timeout_observation =
  Observations.record_provider_timeout_observation
;;

(* #10008 fm3: canonical metric name for proactive-scheduler skip
   reasons. Labels: [("keeper", <name>); ("reason", <skip_reason>)]. *)
let proactive_skip_reason_metric = Keeper_metrics.(to_string ProactiveSkip)


(** Run keeper cycle with holder diagnostics. *)
let run_keeper_cycle = Cycle.run_keeper_cycle

(* T6 audit: outcome of one keepalive cycle evaluation.

   [cycle_crashed = true] means either the catch-all in
   [run_keepalive_unified_turn] swallowed an exception to keep the
   keeper fiber alive, or event-queue work did not complete. The failure has
   already been recorded via
   [Keeper_registry.increment_turn_failures] (the same counter the
   unified-turn failure path in [Keeper_unified_turn_failure] uses),
   so the caller reads a non-zero [turn_fail_count] and dispatches
   [Turn_failed] instead of [Turn_succeeded]. Such a cycle must also
   NOT refresh the work-as-heartbeat lease; the count is observation and never
   terminates the Keeper lane. *)
type keepalive_cycle_status =
  | Turn_cycle_completed
  | Turn_cycle_interrupted
  | Turn_cycle_crashed
  | Turn_cycle_busy of Keeper_owner.autonomous_block

type work_heartbeat_action =
  | Refresh_work_heartbeat
  | Preserve_work_heartbeat

type keepalive_cycle_action =
  | Defer_autonomous_work of Keeper_owner.autonomous_block
  | Skip_interrupted_turn
  | Record_turn_status of work_heartbeat_action

let decide_keepalive_cycle_action = function
  | Turn_cycle_completed -> Record_turn_status Refresh_work_heartbeat
  | Turn_cycle_interrupted -> Skip_interrupted_turn
  | Turn_cycle_crashed -> Record_turn_status Preserve_work_heartbeat
  | Turn_cycle_busy block -> Defer_autonomous_work block
;;

type keepalive_turn_outcome = {
  meta : keeper_meta;
  cycle_status : keepalive_cycle_status;
  stimuli_acked : bool;
      (** The cycle admitted at least one event-queue stimulus and acked
          every entry of that batch on completion. *)
}

let consume_deferred_runtime_lane_hint hint_ref expected =
  match !hint_ref with
  | Some current
    when Keeper_turn_driver.equal_deferred_runtime_lane expected current ->
    hint_ref := None;
    true
  | None | Some _ -> false
;;

exception Event_queue_cycle_failed of string

let connector_attention_event_ids_of_stimuli stimuli =
  List.filter_map
    (fun (stimulus : Keeper_event_queue.stimulus) ->
      match stimulus.payload with
      | Keeper_event_queue.Connector_attention { event_id } -> Some event_id
      | Keeper_event_queue.Board_signal _
      | Keeper_event_queue.Board_attention _
      | Keeper_event_queue.Fusion_completed _
      | Keeper_event_queue.Schedule_due _
      | Keeper_event_queue.Bootstrap
      | Keeper_event_queue.Hitl_resolved _
      | Keeper_event_queue.Ask_answered _
      | Keeper_event_queue.Completion_authority_rejected _
      | Keeper_event_queue.Task_cancelled _
      | Keeper_event_queue.Workspace_message _
      | Keeper_event_queue.Delegate_completed _
      | Keeper_event_queue.Composition_completed _ ->
        None)
    stimuli
;;

let record_replay_owned_turn_started_reactions ~ctx ~keeper_name stimuli =
  List.iter
    (fun (stimulus : Keeper_event_queue.stimulus) ->
       match stimulus.payload with
       (* Same shape as the HITL resolution beside it: an async thing this
          keeper was waiting on came back, and the turn's cause should say so. *)
       | ( Keeper_event_queue.Schedule_due _
         | Keeper_event_queue.Hitl_resolved _
         | Keeper_event_queue.Ask_answered _ ) ->
         record_event_queue_stimulus_turn_started ~ctx ~keeper_name stimulus
       | Keeper_event_queue.Board_signal _
       | Keeper_event_queue.Board_attention _
       | Keeper_event_queue.Fusion_completed _
       | Keeper_event_queue.Bootstrap
       | Keeper_event_queue.Connector_attention _
       | Keeper_event_queue.Completion_authority_rejected _
       | Keeper_event_queue.Task_cancelled _
       | Keeper_event_queue.Workspace_message _
       | Keeper_event_queue.Delegate_completed _
       | Keeper_event_queue.Composition_completed _ -> ())
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

let mark_connector_attention_resolved_after_delivery ~base_path ~keeper_name event_ids =
  match event_ids with
  | [] -> ()
  | _ :: _ ->
    (match
       Keeper_external_attention.mark_resolved
         ~base_path
         ~keeper_name
         ~event_ids
         ~reason:"connector_attention_reply_delivered"
         ()
     with
     | Ok () -> ()
     | Error err ->
       Log.Keeper.warn
         "connector attention mark_resolved after delivery failed keeper=%s events=[%s]: %s"
         keeper_name
         (String.concat "," event_ids)
         err)
;;

type connector_attention_outcome =
  | Attention_resolved
  | Attention_ignored

let connector_attention_outcome_of_route
    (route : Keeper_unified_turn.continuation_route_disposition) =
  match route with
  | Keeper_unified_turn.Continuation_route_addressed -> Attention_resolved
  | Keeper_unified_turn.Continuation_route_not_addressed -> Attention_ignored
;;

(* T6 audit: record a swallowed cycle exception as a turn failure.

   Catch-and-survive is intentional (the fiber must outlive the
   crash); the bug being fixed is that the crash was invisible to the
   scheduling/observation layer. Incrementing the registry counter routes the
   crash through the same [Turn_failed] telemetry channel as other failures. *)
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

let handle_cycle_exception ~base_path ~(meta : keeper_meta) exn =
  if Keeper_registry_types.is_operator_interrupt exn
  then (
    Log.Keeper.info
      ~keeper_name:meta.name
      "%s: keeper cycle interrupted by operator; no turn failure recorded"
      meta.name;
    { meta; cycle_status = Turn_cycle_interrupted; stimuli_acked = false })
  else (
    record_crashed_cycle_failure
      ~base_path
      ~keeper_name:meta.name
      exn;
    { meta; cycle_status = Turn_cycle_crashed; stimuli_acked = false })
;;




(* The queue records attention that a Keeper must observe, not provider health.
   A source leaves only after a completed turn has observed the admitted batch.
   Provider/config/context failures therefore leave every source untouched;
   otherwise one runtime failure can terminally discard an arbitrary batch of
   unrelated Board, Schedule, Task, or completion-authority facts. *)
type batch_disposition =
  | Batch_ack_completed of
      { connector_attention_outcome : connector_attention_outcome }
  | Batch_no_action

let batch_disposition_of_cycle_outcome
      (cycle_outcome : Keeper_heartbeat_loop_cycle.cycle_outcome option)
  : batch_disposition
  =
  match cycle_outcome with
  | Some (Cycle.Completed completion) ->
    Batch_ack_completed
      { connector_attention_outcome =
          connector_attention_outcome_of_route completion.continuation_route
      }
  | Some
      ( Cycle.Failed _
      | Cycle.Checkpointed _
      | Cycle.Input_required _
      | Cycle.Cancelled _
      | Cycle.Skipped _ )
  | None ->
    Batch_no_action
;;

type connector_attention_settlement =
  | Settle_resolved
  | Settle_ignored
  | Settle_pending_in_queue

let connector_attention_settlement_of_disposition = function
  | Batch_ack_completed { connector_attention_outcome = Attention_resolved } ->
    Settle_resolved
  | Batch_ack_completed { connector_attention_outcome = Attention_ignored } ->
    Settle_ignored
  (* The entry stays pending, so the turn that finally drains it owns the
     terminal event. Settling here would retire a row that is still live. *)
  | Batch_no_action -> Settle_pending_in_queue
;;


(* Pure: post-turn status event derived from the registry turn-failure
   counter. Extracted from the loop body so the crashed-cycle ->
   [Turn_failed] mapping is unit-testable. *)
let turn_status_event ~turn_fail_count : Keeper_state_machine.event =
  if turn_fail_count > 0
  then Keeper_state_machine.Turn_failed { consecutive = turn_fail_count }
  else Keeper_state_machine.Turn_succeeded
;;

(* Whether the event queue still holds any pending entry. Read errors are
   logged and answered [false]: the cycle then sleeps the cadence and the
   next intake reports the same error through its own path. *)
let pending_stimulus_remains ~ctx ~keeper_name =
  match
    Keeper_registry_event_queue.peek_when_result
      ~base_path:ctx.config.base_path
      keeper_name
      ~now:(Time_compat.now ())
      ~ready:(fun (_ : Keeper_event_queue.stimulus) -> true)
  with
  | Ok (Some _) -> true
  | Ok None -> false
  | Error detail ->
    Log.Keeper.warn
      ~keeper_name
      "event queue peek after acked cycle failed; sleeping the cadence: %s"
      detail;
    false
;;

(* Autoboot warmup is a dispatch delay, not an extra heartbeat cadence. The
   first cycle runs before warmup and skips intake; sleeping the full cadence
   here used to leave restored durable work (and the bootstrap stimulus) idle
   for up to [heartbeat.interval_sec] after every server restart. *)
let next_keepalive_sleep_duration_sec
      ~proactive_warmup_sec
      ~proactive_warmup_elapsed
      ~keepalive_started_ts
      ~now_ts
      ~cadence_sec
  =
  let cadence_sec = Float.max 0.0 cadence_sec in
  if proactive_warmup_sec <= 0 || proactive_warmup_elapsed
  then cadence_sec
  else (
    let elapsed_sec = Float.max 0.0 (now_ts -. keepalive_started_ts) in
    let warmup_remaining_sec = float_of_int proactive_warmup_sec -. elapsed_sec in
    Float.max 0.0 (Float.min cadence_sec warmup_remaining_sec))
;;

let run_keepalive_unified_turn
      ~(ctx : _ context)
      ~(meta_after_triage : keeper_meta)
      ~pending_board_events
      ~(stop : bool Atomic.t)
      ~(proactive_warmup_elapsed : bool)
      ~(reactive_wake : bool)
      ~(shared_context : Agent_core.Context.t)
      ~(deferred_runtime_lane : Keeper_turn_driver.deferred_runtime_lane option)
      ~(on_deferred_runtime_consumed : unit -> unit)
      ~(record_deferred_runtime_lane :
          Keeper_turn_driver.deferred_runtime_lane -> unit)
  : keepalive_turn_outcome
  =
  if not proactive_warmup_elapsed
  then
    { meta = meta_after_triage
    ; cycle_status = Turn_cycle_completed
    ; stimuli_acked = false
    }
  else
    match
      Keeper_owner_registry.run_autonomous_if_idle
        ~base_path:ctx.config.base_path
        ~keeper_name:meta_after_triage.name
        (fun () ->
           Keeper_turn_dispatch_authority.run (fun admission_token ->
    let consumed_stimuli = ref [] in
    let pending_selection
      : Keeper_event_queue_state.pending_selection option ref
      =
      ref None
    in
    (* RFC-0377: [pending_selection] above stays the single primary entry
       (transient-board-withdrawal reporting and pre-dispatch validation are
       unchanged by batching). [consumed_selections] is the full admitted
       batch — [[]], a singleton mirroring [pending_selection], or the
       primary plus every same-conversation Connector_attention companion.
       Turn completion/failure disposition acks or defers every entry in
       this list, not just the primary, so a companion is never left
       durably stuck once its turn has already run. *)
    let consumed_selections
      : Keeper_event_queue_state.pending_selection list ref
      =
      ref []
    in
    let cycle_outcome_ref = ref None in
    let selection_acked = ref false in
    let stimuli_acked = ref false in
    let event_queue_failed = ref false in
    let record_event_queue_failure message =
      event_queue_failed := true;
      match !cycle_outcome_ref with
      | Some (Cycle.Failed _) ->
        (* The failed turn already recorded its failure counter. The queue
           error remains explicit in the log and durable pending state. *)
        ()
      | Some
          ( Cycle.Completed _
          | Cycle.Checkpointed _
          | Cycle.Input_required _
          | Cycle.Cancelled _
          | Cycle.Skipped _
          )
      | None ->
        record_crashed_cycle_failure
          ~base_path:ctx.config.base_path
          ~keeper_name:meta_after_triage.name
          (Event_queue_cycle_failed message)
    in
    try
      (match
         Keeper_board_attention_worker.settle_one_completed
           ~base_path:ctx.config.base_path
           ~keeper_name:meta_after_triage.name
       with
       | Error detail ->
         Log.Keeper.error
           ~keeper_name:meta_after_triage.name
           "Board attention completion remains pending; it did not block this Keeper turn: %s"
           detail
       | Ok Keeper_board_attention_worker.No_completed_partition ->
         ()
       | Ok
           (Keeper_board_attention_worker.Partition_settled
              { candidate_id; continuation_wake = _ }) ->
         Log.Keeper.info
           "Board attention completed judgment settled on owner lane keeper=%s candidate=%s"
           meta_after_triage.name
           candidate_id);
      let event_intake =
        heartbeat_event_intake
          ~ctx
          ~meta_after_triage
          ~pending_board_events
      in
      consumed_stimuli := event_intake.consumed_stimuli;
      pending_selection := event_intake.pending_selection;
      consumed_selections := event_intake.consumed_selections;
      let selected_source_authority () =
        match
          Keeper_meta_store.read_effective_meta
            ctx.config
            meta_after_triage.name
        with
        | Error message ->
          Error ("keeper meta read failed before dispatch: " ^ message)
        | Ok None -> Error "keeper meta disappeared before dispatch"
        | Ok (Some current) when current.paused ->
          Error "keeper paused before dispatch"
        | Ok (Some _) ->
          (* Batch case: validate every admitted selection, not only the
             primary, so a companion whose durable entry changed out from
             under this turn is caught before dispatch instead of only at
             ack time. Falls back to the pre-batch single [pending_selection]
             when nothing was consumed as a batch (e.g. the transient-board
             withdrawal case, which never populates [consumed_selections]). *)
          let selections_to_validate =
            match !consumed_selections with
            | [] -> Option.to_list !pending_selection
            | (_ :: _) as selections -> selections
          in
          List.fold_left
            (fun result selection ->
               match result with
               | Error _ as error -> error
               | Ok () ->
                 Keeper_registry_event_queue.validate_pending_selection_result
                   ~base_path:ctx.config.base_path
                   meta_after_triage.name
                   ~selection)
            (Ok ())
            selections_to_validate
      in
      (match
         Keeper_turn_dispatch_authority.install
           admission_token
           selected_source_authority
       with
       | Ok () -> ()
       | Error message -> failwith message);
      (match event_intake.event_queue_intake_error with
       | None -> ()
       | Some error
         when
           Stimulus_intake.event_queue_intake_error_counts_as_cycle_failure
             error ->
         record_event_queue_failure
           (Stimulus_intake.event_queue_intake_error_to_string error)
       | Some _ -> ());
      let pending_board_events = event_intake.pending_board_events in
      let obs =
        Keeper_world_observation.observe
          ~pending_board_events:(Some pending_board_events)
          ~config:ctx.config
          ~meta:meta_after_triage
      in
      let scheduling =
        decide_keepalive_scheduling
          ~event_queue_triggers:event_intake.event_queue_triggers
          ~stop
          ~meta:meta_after_triage
          obs
      in
      let turn_decision = scheduling.turn_decision in
      (* Manual reconcile blocker check removed — keepers no longer get
         stuck behind sticky blockers. Failed turns record evidence via
         Keeper_registry; recovery is autonomous (next turn's observation)
         or operator-driven (board/keeper_chat), not blocker-driven. *)
      let should_run_turn =
        should_run_turn_after_event_intake
          ~scheduled:scheduling.should_run_turn
          ~consumed_stimulus_count:event_intake.consumed_stimulus_count
          ~event_queue_intake_error:event_intake.event_queue_intake_error
      in
      let verdict_strs =
        match event_intake.event_queue_intake_error with
        | None -> scheduling.verdict_reasons
        | Some error ->
          Stimulus_intake.event_queue_intake_error_reason_label error
          :: scheduling.verdict_reasons
      in
      let channel_str = scheduling.channel in
      if not should_run_turn
      then (
        (* #10008 fm3: emit per-reason skip counter so operators can
           see why proactive scheduler never fires for a given keeper.
           two Keepers stayed at [proactive_count_total=0,
           last_proactive_ts=0.0] for 45+ min despite
           proactive_enabled=true — the info log alone buried the
           reason across many lines.  Labelled counter lets Grafana
           split [keeper_paused] vs [reactive_disabled] vs
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
        Keeper_registry.record_skip_reasons
          ~base_path:ctx.config.base_path
          meta_after_triage.name
          ~reasons:verdict_strs;
        Keeper_registry.touch_last_turn_ts
          ~base_path:ctx.config.base_path
          meta_after_triage.name;
        let paused_info =
          if meta_after_triage.paused
          then (
            let paused_since_sec =
              match
                Workspace_resilience.Time.parse_iso8601_opt meta_after_triage.updated_at
              with
              | Some ts -> int_of_float (max 0.0 (Time_compat.now () -. ts))
              | None -> -1
            in
            Printf.sprintf " paused_since=%ds" paused_since_sec)
          else ""
        in
        let log_not_scheduled =
          match turn_decision.verdict with
          | Keeper_world_observation.Skip _ -> Log.Keeper.debug
          | Keeper_world_observation.Run _ -> Log.Keeper.info
        in
        log_not_scheduled
          "keepalive turn not scheduled for %s: should_run=%b channel=%s reasons=[%s] \
           idle=%ds since_last=%s%s"
          meta_after_triage.name
          should_run_turn
          channel_str
          (String.concat "," verdict_strs)
          obs.idle_seconds
          (Keeper_keepalive_signal.format_since_last_scheduled_autonomous
             turn_decision.since_last_scheduled_autonomous)
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
        Keeper_tool_policy.keeper_model_tool_names ()
      in
      let tool_diversity_summary =
        let stats = Keeper_tool_diversity.stats_of_registry_entries tool_usage_entries in
        Keeper_tool_diversity.compute_diversity ~available_tools stats
      in
      Keeper_tool_diversity.record_underused_tool_metrics
        ~keeper_name:meta_after_triage.name
        tool_diversity_summary;
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
           ~turn_verdict:turn_decision.verdict
           ~wall_clock:audit_wall_clock
           ?tool_diversity_entropy
           ());
      Keeper_decision_audit.flush_if_needed
        ~base_path:ctx.config.base_path
        ~keeper_name:meta_after_triage.name;
      let meta_after_cycle =
        if Atomic.get stop
        then meta_after_triage
        else if should_run_turn
        then (
          (* fd/disk pressure is pre-checked
             by [classify_turn_intake_admission] in [run_heartbeat_loop] BEFORE
             stimulus intake, so this branch is reached only when a turn is
             admitted. The four prior inline pressure gates here were removed: they
             ran AFTER intake had already consumed the stimulus, forcing a
             consume/requeue churn loop, and logged only at DEBUG (a silent skip). *)
          record_replay_owned_turn_started_reactions
            ~ctx
            ~keeper_name:meta_after_triage.name
            !consumed_stimuli;
          let event_bus = Event_bus_slots.get_keeper () in
          (* Preserve the typed resolution as input to the originating
             Keeper's external-effect Gate. It is not an AGENT_CORE approval. *)
          let hitl_resolution =
            match
              List.find_map
                (fun (stim : Keeper_event_queue.stimulus) ->
                  match stim.Keeper_event_queue.payload with
                  | Keeper_event_queue.Hitl_resolved resolution -> Some resolution
                  | _ -> None)
                !consumed_stimuli
            with
            | Some resolution -> Some resolution
            | None ->
              (* #28809: a ready resolution may be queued behind the stimulus
                 that woke this turn (e.g. a redelivered workspace message
                 whose own earlier turn deferred on this very approval).
                 Project the durable resolution into this turn instead of
                 waiting for its queue position; the untouched queue entry is
                 retired as a spent grant by [reconcile_spent_selection]
                 without costing a turn. *)
              (match
                 Stimulus_intake.ready_hitl_resolution_peek
                   ~base_path:ctx.config.base_path
                   ~keeper_name:meta_after_triage.name
               with
               | None -> None
               | Some resolution ->
                 Log.Keeper.info
                   "hitl resolution projected from pending queue approval=%s \
                    decision=%s (keeper=%s)"
                   resolution.Keeper_event_queue.approval_id
                   (Keeper_event_queue.hitl_resolution_decision_to_string
                      resolution.Keeper_event_queue.decision)
                   meta_after_triage.name;
                 Some resolution)
          in
          (* The event intake is the exact turn input. Keep its attribution in
             the existing wake record even when the cadence, rather than a
             direct wake signal, discovered it. An empty [Woken] still means a
             reactive wake with no selected event. *)
          let wake : Keeper_registry.wake_reason =
            match !consumed_stimuli, reactive_wake with
            | _ :: _, _ ->
              Keeper_registry.Woken
                (List.map
                   (fun (stim : Keeper_event_queue.stimulus) ->
                      stim.Keeper_event_queue.payload)
                   !consumed_stimuli)
            | [], true -> Keeper_registry.Woken []
            | [], false -> Keeper_registry.Proactive_tick
          in
          let run_fresh_cycle () =
            run_keeper_cycle
              ~admission_token
              ?deferred_runtime_lane
              ~on_deferred_runtime_consumed
              ?event_bus
              ?hitl_resolution
              ~ctx
              ~meta_after_triage
              ~stop
              ~obs
              ~turn_decision
              ~shared_context
              ~wake
              ()
          in
          let run_cycle () = run_fresh_cycle () in
          let cycle_outcome = run_cycle () in
          Option.iter
            record_deferred_runtime_lane
            (Cycle.deferred_runtime_lane cycle_outcome);
          cycle_outcome_ref := Some cycle_outcome;
          Cycle.meta cycle_outcome)
        else meta_after_triage
      in
      let record_terminal_selection_result ~label = function
        | Error message ->
          record_event_queue_failure message;
          false
        | Ok
            ( Keeper_registry_event_queue.Acked _
            | Keeper_registry_event_queue.Already_acked _ ) ->
          selection_acked := true;
          true
        | Ok
            (Keeper_registry_event_queue.Ack_committed_followup_failed
               { stage; detail = followup_detail; _ }) ->
          selection_acked := true;
          let stage =
            match stage with
            | `Checkpoint -> "checkpoint"
            | `Wal_compaction -> "wal_compaction"
            | `Projection -> "projection"
          in
          record_event_queue_failure
            (Printf.sprintf
               "%s receipt committed but %s follow-up \
                failed: %s"
               label
               stage
               followup_detail);
          true
      in
      let terminalize_completed_selection ~selection =
        Keeper_registry_event_queue.terminalize_pending_turn_completed_result
          ~base_path:ctx.config.base_path
          meta_after_triage.name
          ~applied_at:(Time_compat.now ())
          ~selection
        |> record_terminal_selection_result ~label:"turn completion"
      in
      (match !cycle_outcome_ref with
       | Some (Cycle.Failed _)
       | Some
           ( Cycle.Completed _
           | Cycle.Checkpointed _
           | Cycle.Input_required _
           | Cycle.Cancelled _
           | Cycle.Skipped _
           )
       | None ->
         ());
      (* RFC-0377: every entry admitted into this turn (the primary plus any
         Connector_attention batch companions) shares the turn's outcome. A
         turn completion acks all of them; a turn failure applies the same
         quarantine/defer/preserve disposition to all of them, so a
         companion is never silently left un-acked while the primary is. *)
      (match !consumed_selections with
       | [] -> ()
       | (_ :: _) as selections ->
           let settle_connector_attention settlement =
             let event_ids =
               connector_attention_event_ids_of_stimuli !consumed_stimuli
             in
             match settlement with
             | Settle_resolved ->
               mark_connector_attention_resolved_after_delivery
                 ~base_path:ctx.config.base_path
                 ~keeper_name:meta_after_triage.name
                 event_ids
             | Settle_ignored ->
               mark_connector_attention_ignored_after_turn
                 ~base_path:ctx.config.base_path
                 ~keeper_name:meta_after_triage.name
                 event_ids
             | Settle_pending_in_queue -> ()
           in
           let remove_completed_selections ~settlement =
             let all_acked =
               List.fold_left
                 (fun all_acked selection ->
                    let acked = terminalize_completed_selection ~selection in
                    all_acked && acked)
                 true
                 selections
             in
             stimuli_acked := all_acked;
             (* A failed queue ack leaves the entry live, so the row it carries
                is still someone's to settle. *)
             if all_acked then settle_connector_attention settlement
           in
           let disposition = batch_disposition_of_cycle_outcome !cycle_outcome_ref in
           let settlement =
             connector_attention_settlement_of_disposition disposition
           in
           match disposition with
           | Batch_ack_completed _ -> remove_completed_selections ~settlement
           | Batch_no_action -> ());
      { meta = meta_after_cycle
      ; cycle_status =
          if !event_queue_failed then Turn_cycle_crashed else Turn_cycle_completed
      ; stimuli_acked = !stimuli_acked
      }
    with
    | exn when Keeper_registry_types.is_operator_interrupt exn ->
      handle_cycle_exception
        ~base_path:ctx.config.base_path
        ~meta:meta_after_triage
        exn
    | Eio.Cancel.Cancelled _ as e ->
      let backtrace = Printexc.get_raw_backtrace () in
      Printexc.raise_with_backtrace e backtrace
    | Keeper_registry.Keeper_fiber_crash as e ->
      let backtrace = Printexc.get_raw_backtrace () in
      Printexc.raise_with_backtrace e backtrace
    | exn ->
      (* T6 audit: keep the fiber alive, but surface the crash as a
         turn failure so the caller does not dispatch
         [Turn_succeeded] for a cycle that never completed. *)
      handle_cycle_exception
        ~base_path:ctx.config.base_path
        ~meta:meta_after_triage
        exn))
    with
  | Ok (`Ran outcome) -> outcome
  | Ok (`Busy ((Keeper_owner.Turn_busy (Some in_flight)) as block)) ->
    Log.Keeper.info
      ~keeper_name:meta_after_triage.name
      "keeper owner busy before stimulus intake: %s"
      (Keeper_owner.autonomous_block_to_string
         (Keeper_owner.Turn_busy (Some in_flight)));
    { meta = meta_after_triage
    ; cycle_status = Turn_cycle_busy block
    ; stimuli_acked = false
    }
  | Ok (`Busy block) ->
    { meta = meta_after_triage
    ; cycle_status = Turn_cycle_busy block
    ; stimuli_acked = false
    }
  | Error
      (Keeper_owner_registry.Command_rejected Keeper_owner.Owner_stopping) ->
    { meta = meta_after_triage
    ; cycle_status = Turn_cycle_completed
    ; stimuli_acked = false
    }
  | Error error ->
    Log.Keeper.error
      ~keeper_name:meta_after_triage.name
      "keeper owner rejected autonomous turn: %s"
      (Keeper_owner_registry.command_error_to_string error);
    { meta = meta_after_triage
    ; cycle_status = Turn_cycle_crashed
    ; stimuli_acked = false
    }
;;

let refresh_work_as_heartbeat = Keeper_heartbeat_loop_refresh_work.refresh_work_as_heartbeat

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
                      that every successful compare_and_set returns [Woken]
                      and recurs directly into dispatch without another
                      policy decision or sleep. *)

let run_heartbeat_loop
      ~proactive_warmup_sec
      (ctx : _ context)
      (m : keeper_meta)
      (stop : bool Atomic.t)
      ~(wakeup : bool Atomic.t)
      ~(cadence_sleeping : bool Atomic.t)
  : unit
  =
  let keepalive_started_ts = Time_compat.now () in
  let snapshot_interval_sec () =
    Runtime_params.get Runtime_settings.keeper_snapshot_sec
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
      }
  in
  let timing_cursor = ref 0 in
  let timing_filled = ref 0 in
  let work_as_hb () = Runtime_params.get Runtime_settings.keeper_work_as_hb_enabled in
  (* Persistent AGENT_CORE Context.t — created once per keeper lifecycle.
     AGENT_CORE Context.t is a mutable cross-turn state container for values
     written directly into the shared context. This preserves shared
     metadata across turns, but per-turn context_injector-local timing
     and tool-call counters are recreated inside run_turn and therefore
     do not accumulate for the full keeper lifecycle. *)
  let shared_context = Agent_core.Context.create () in
  let deferred_runtime_lane_ref =
    match
      Deferred_runtime_store.load
        ~base_path:ctx.config.base_path
        ~keeper_name:m.name
    with
    | Ok restored ->
      Option.iter
        (fun (hint : Keeper_turn_driver.deferred_runtime_lane) ->
           Log.Keeper.info
             ~keeper_name:m.name
             "%s: restored durable frozen runtime lane suffix failed_runtime=%s next_runtime=%s remaining=%d"
             m.name
             hint.failed_runtime_id
             hint.next_runtime_id
             (List.length hint.later_runtime_ids))
        restored;
      ref restored
    | Error error ->
      let detail = Deferred_runtime_store.error_to_string error in
      Keeper_registry.set_failure_reason
        ~base_path:ctx.config.base_path
        m.name
        (Some (Keeper_registry.Exception detail));
      Log.Keeper.error
        ~keeper_name:m.name
        "%s: refusing autonomous turns because durable deferred runtime authority is unreadable: %s"
        m.name
        detail;
      raise Keeper_registry.Keeper_fiber_crash
  in
  (* Mtime-based change detection for keeper meta disk reads.
     Avoids re-parsing the JSON file on every heartbeat cycle when
     no operator has modified it.  Initialized to 0.0 so the first
     cycle always reads. *)
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
      let owner_meta =
        match
          Keeper_owner_registry.get
            ~base_path:ctx.config.base_path
            ~keeper_name:m.name
        with
        | Ok owner -> (Keeper_owner.projection owner).meta
        | Error error ->
          Log.Keeper.error
            "%s: heartbeat owner projection unavailable: %s"
            m.name
            (Keeper_owner_registry.lookup_error_to_string error);
          None
      in
      let meta_current =
        effective_keepalive_meta
          ~base_path:ctx.config.base_path
          ~fallback:m
          ~disk_meta_opt:owner_meta
      in
      (* A live lane evaluates every configured heartbeat tick. Busy/idle
         labels, observer count, and prior activity never suppress the cycle;
         an explicit wake atomically cuts the sleep for this Keeper only. *)
      let meta_current =
        (* Phase 1: sync presence and emit heartbeat metric *)
        let meta_current =
          sync_keeper_presence
            ~ctx
            ~meta_current
            ~consecutive_failures
        in
        if !consecutive_failures > 0
        then
          Keeper_registry.set_failure_reason
            ~base_path:ctx.config.base_path
            m.name
            (Some (Keeper_registry.Heartbeat_consecutive_failures !consecutive_failures));
        meta_current
      in
        let t_presence_end = Time_compat.now () in
        let now_ts = t_presence_end in
        let t_snapshot_start = now_ts in
        maybe_write_heartbeat_snapshot
          ~ctx
          ~meta_current
          ~now_ts
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
        (* Lifecycle state is evaluated before durable stimulus intake. Resource
           pressure remains observable but cannot pre-empt every Keeper lane;
           concrete I/O boundaries report their own failures explicitly. *)
        let lifecycle_state =
          Keeper_lifecycle_admission.state
            ~paused:meta_current.paused
            ~latched_reason:meta_current.latched_reason
        in
        let intake_admission =
          classify_turn_intake_admission
            ~lifecycle:
              (Keeper_lifecycle_admission.admit_autonomous lifecycle_state)
        in
        let admitted_turn =
          match intake_admission with
          | Intake_admitted -> true
          | Intake_lifecycle_blocked _ -> false
        in
        let lifecycle_blocked =
          match intake_admission with
          | Intake_lifecycle_blocked _ -> true
          | Intake_admitted -> false
        in
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
           (* [autonomous_denial] carries one variant, an ordinary pause, which
              keeps the lane parked so an explicit resume stays local. The loop
              therefore never stops itself here. *)
           Keeper_registry.touch_last_turn_ts
             ~base_path:ctx.config.base_path
             meta_current.name
         );
        let pending_board_events, meta_after_triage =
          if admitted_turn
          then
            collect_keepalive_board_events
              ~ctx
              ~meta_current
              ~proactive_warmup_elapsed
          else [], meta_current
        in
        let t_board_end = Time_compat.now () in
        let t_turn_start = t_board_end in
        let turn_outcome =
          if not admitted_turn
          then
            { meta = meta_current
            ; cycle_status = Turn_cycle_completed
            ; stimuli_acked = false
            }
          else (
            (* Cycle 43: KeeperHeartbeat.tla TurnComplete bracket — the
               [turn_running] flag toggles around the dispatch and the
               pre/post guards mirror the spec's [turn_state] transition
               "running" -> "idle". *)
            turn_running := true;
            (* [Woken] => this cycle was triggered by an external broadcast, not
               the keeper's own cadence. The distinction is recorded as the
               turn's wake reason. *)
            let reactive_wake =
              match !last_wake_source with
              | Keeper_keepalive_signal.Woken -> true
              | Keeper_keepalive_signal.Timeout | Keeper_keepalive_signal.Stopped ->
                false
            in
            let deferred_runtime_lane = !deferred_runtime_lane_ref in
            let deferred_runtime_lane_consumed = ref false in
            let replacement_deferred_runtime_lane_recorded = ref false in
            let on_deferred_runtime_consumed () =
              Option.iter
                (fun expected ->
                   if
                     consume_deferred_runtime_lane_hint
                       deferred_runtime_lane_ref
                       expected
                   then deferred_runtime_lane_consumed := true)
                deferred_runtime_lane
            in
            let record_deferred_runtime_lane hint =
              replacement_deferred_runtime_lane_recorded := true;
              deferred_runtime_lane_ref := Some hint;
              match
                Deferred_runtime_store.save
                  ~base_path:ctx.config.base_path
                  ~keeper_name:m.name
                  hint
              with
              | Ok () -> ()
              | Error error ->
                let detail = Deferred_runtime_store.error_to_string error in
                Keeper_registry.set_failure_reason
                  ~base_path:ctx.config.base_path
                  m.name
                  (Some (Keeper_registry.Exception detail));
                Log.Keeper.error
                  ~keeper_name:m.name
                  "%s: deferred runtime suffix remains process-local because durable publication failed: %s"
                  m.name
                  detail
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
                ~deferred_runtime_lane
                ~on_deferred_runtime_consumed
                ~record_deferred_runtime_lane
            in
            (* Consumption is committed only after the cycle has a typed
               outcome. A process crash after dispatch but before this point
               leaves the durable suffix in place, so restart retries the
               successor instead of resurrecting the already-failed prefix. A
               failure that freezes a smaller tail replaces the file above. *)
            (if
              !deferred_runtime_lane_consumed
              && not !replacement_deferred_runtime_lane_recorded
            then (
              match
                Deferred_runtime_store.clear
                  ~base_path:ctx.config.base_path
                  ~keeper_name:m.name
              with
              | Ok () -> ()
              | Error error ->
                (* Keep process memory aligned with the still-present durable
                   file. Retrying the successor is safer than silently falling
                   back to the failed lane prefix. *)
                deferred_runtime_lane_ref := deferred_runtime_lane;
                let detail = Deferred_runtime_store.error_to_string error in
                Keeper_registry.set_failure_reason
                  ~base_path:ctx.config.base_path
                  m.name
                  (Some (Keeper_registry.Exception detail));
                Log.Keeper.error
                  ~keeper_name:m.name
                  "%s: durable deferred runtime suffix consumption did not commit: %s"
                  m.name
                  detail));
            Keeper_keepalive_signal.pre_turn_complete_heartbeat ~turn_running;
            turn_running := false;
            Keeper_keepalive_signal.post_turn_complete_heartbeat ~turn_running;
            r)
        in
        let meta_after_proactive = turn_outcome.meta in
        (match decide_keepalive_cycle_action turn_outcome.cycle_status with
         | Defer_autonomous_work block ->
            Keeper_registry.record_skip_reasons
              ~base_path:ctx.config.base_path
              m.name
              ~reasons:
                [ "keeper_owner_"
                  ^ Keeper_owner.autonomous_block_kind block
                ];
            Log.Keeper.info
              ~keeper_name:m.name
              "Keeper Owner deferred autonomous work: %s; this keepalive cycle \
               records no turn status, crash, or work-health refresh"
              (Keeper_owner.autonomous_block_to_string block)
         | Skip_interrupted_turn ->
           Log.Keeper.info
             ~keeper_name:m.name
             "%s: operator-interrupted cycle records no turn status or work-health refresh"
             m.name
         | Record_turn_status _ when lifecycle_blocked -> ()
         | Record_turn_status work_heartbeat_action ->
             (* The registry tracks failure count as observation. A
                lifecycle-blocked cycle did not run a turn and must not emit a
                false [Turn_succeeded]. *)
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
                  ~turn_fail_count);
             if turn_fail_count > 0
             then
               Keeper_registry.set_failure_reason
                 ~base_path:ctx.config.base_path
                 m.name
                 (Some (Keeper_registry.Turn_consecutive_failures turn_fail_count));
             (* Phase 1: work-as-heartbeat — renew point (b).
                After turn, call Workspace.heartbeat to prove workspace I/O health.
                On success: reset consecutive_failures.
                T6 audit: a crashed cycle proves nothing about health — do not
                reset consecutive_failures for it. *)
             (match work_heartbeat_action with
              | Refresh_work_heartbeat ->
               refresh_work_as_heartbeat
                 ~ctx
                 ~meta_after_proactive
                 ~proactive_warmup_elapsed
                 ~work_as_hb
                 ~consecutive_failures
              | Preserve_work_heartbeat ->
               Log.Keeper.info
                 "%s: skipping work-as-heartbeat refresh after crashed keepalive cycle"
                 m.name));
        let t_turn_end = Time_compat.now () in
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
          ~t_turn_end;
        (* Carry the inter-cycle sleep result into the next iteration so the
           turn evaluator can distinguish a broadcast wakeup ([Woken]) from this
           keeper's configured cadence ([Timeout]).

           A cycle that acked its stimulus batch and left more entries pending
           does not sleep the cadence: the queue is the wake signal, and the
           next cycle dispatches as [Woken]. A checkpointed, failed, or busy
           cycle keeps the cadence so a turn that made no progress is not
           re-run back to back. *)
        last_wake_source :=
          (if turn_outcome.stimuli_acked
              && pending_stimulus_remains ~ctx ~keeper_name:m.name
           then Keeper_keepalive_signal.Woken
           else
             Keeper_keepalive_signal.interruptible_sleep
               ~cadence_sleeping
               ~clock:ctx.clock
               ~stop
               ~wakeup
               (fun () ->
                 next_keepalive_sleep_duration_sec
                   ~proactive_warmup_sec
                   ~proactive_warmup_elapsed
                   ~keepalive_started_ts
                   ~now_ts:(Time_compat.now ())
                   ~cadence_sec:
                     (float_of_int
                        (Keeper_heartbeat_snapshot.keepalive_interval_sec ()))));
      if Atomic.get stop then () else loop ())
  in
  loop ()
;;

module For_testing = struct
  let consume_deferred_runtime_lane_hint = consume_deferred_runtime_lane_hint
  let next_keepalive_sleep_duration_sec = next_keepalive_sleep_duration_sec
end
