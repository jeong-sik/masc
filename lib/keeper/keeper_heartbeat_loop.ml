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

type heartbeat_event_intake = Stimulus_intake.heartbeat_event_intake = {
  pending_board_events : Keeper_world_observation.pending_board_event list;
  consumed_stimulus_count : int;
  consumed_stimuli : Keeper_event_queue.stimulus list;
  event_queue_triggers : Keeper_world_observation.event_queue_trigger list;
}

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
let run_keeper_cycle = Keeper_heartbeat_loop_cycle.run_keeper_cycle

(* T6 audit: outcome of one keepalive cycle evaluation.

   [cycle_crashed = true] means the catch-all in
   [run_keepalive_unified_turn] swallowed an exception to keep the
   keeper fiber alive. The failure has already been recorded via
   [Keeper_registry.increment_turn_failures] (the same counter the
   unified-turn failure path in [Keeper_unified_turn_failure] uses),
   so the caller reads a non-zero [turn_fail_count] and dispatches
   [Turn_failed] instead of [Turn_succeeded]. A crashed cycle must
   also NOT refresh the work-as-heartbeat lease. *)
type keepalive_turn_outcome = {
  meta : keeper_meta;
  cycle_crashed : bool;
}

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
    let consumed_stimuli_turn_completed = ref false in
    try
      let event_intake =
        heartbeat_event_intake ~ctx ~meta_after_triage ~pending_board_events
      in
      consumed_stimuli := event_intake.consumed_stimuli;
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
            if Health.is_healthy ~agent_name:keeper_name then None
            else Some "unhealthy")
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
          (* fd/disk pressure is pre-checked by the caller's turn-admission gate
             (Keeper_turn_admission_observer.decide_observed in run_heartbeat_loop)
             BEFORE stimulus intake, so this branch is reached only when a turn is
             admitted. The four prior inline pressure gates here were removed: they
             ran AFTER intake had already consumed the stimulus, forcing a
             consume/requeue churn loop, and logged only at DEBUG (a silent skip). *)
          let event_bus = Keeper_event_bus.get () in
          let meta_after_cycle =
            run_keeper_cycle
              ?event_bus
              ~ctx
              ~meta_after_triage
              ~stop
              ~obs
              ~turn_decision
              ~shared_context
              ()
          in
          consumed_stimuli_turn_completed := true;
          meta_after_cycle)
        else meta_after_triage
      in
      (* Event intake dequeues before the admission/pressure gates above.
         Only ack after [run_keeper_cycle] actually returns; otherwise put the
         lease back so a non-exception skip does not drop the stimulus. *)
      if !consumed_stimuli <> []
      then
        if !consumed_stimuli_turn_completed
        then
          Keeper_registry_event_queue.ack_consumed
            ~base_path:ctx.config.base_path
            meta_after_triage.name
            !consumed_stimuli
        else
          Keeper_registry_event_queue.requeue_front
            ~base_path:ctx.config.base_path
            meta_after_triage.name
            !consumed_stimuli;
      { meta = meta_after_cycle; cycle_crashed = false }
    with
    | Eio.Cancel.Cancelled _ as e -> raise e
    | Keeper_registry.Keeper_fiber_crash as e -> raise e
    | exn ->
      Keeper_registry_event_queue.requeue_front
        ~base_path:ctx.config.base_path
        meta_after_triage.name
        !consumed_stimuli;
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
  let shared_context = Agent_sdk.Context.create ~eio:true () in
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
        (* Turn-admission precondition (fd/disk pressure) is evaluated ONCE here,
           BEFORE board collection and stimulus intake. A pressure-blocked keeper
           therefore neither advances the board cursor (collect_keepalive_board_events
           acks board posts with no requeue) nor dequeues+requeues its event-queue
           stimulus every cycle — eliminating the consume/requeue churn and its log
           noise at the source instead of skipping after the work is already done.
           The fleet observer logs one WARN per pressure episode (was four per-turn
           DEBUG gates inside run_keepalive_unified_turn, now removed). last_turn_ts
           is refreshed on the blocked path so the RFC-0250 stale-turn watchdog
           (Keeper_supervisor.assess_stale_run) does not crash-restart a keeper that
           is correctly suspended by a shared circuit breaker rather than stalled. *)
        let turn_admission =
          Keeper_turn_admission_observer.decide_observed
            ~masc_root:(Workspace.masc_root_dir ctx.config)
            ~active_keepers:(Keeper_registry.count_running ())
            ()
        in
        let admitted_turn =
          match turn_admission with
          | Keeper_turn_admission.Admitted -> true
          | Keeper_turn_admission.Blocked _ -> false
        in
        (match turn_admission with
         | Keeper_turn_admission.Admitted -> ()
         | Keeper_turn_admission.Blocked block ->
           Keeper_registry.record_skip_reasons
             ~base_path:ctx.config.base_path
             meta_current.name
             ~reasons:[ Keeper_turn_admission.skip_reason block ];
           Keeper_registry.touch_last_turn_ts
             ~base_path:ctx.config.base_path
             meta_current.name);
        let pending_board_events, meta_after_triage =
          if admitted_turn
          then collect_keepalive_board_events ~ctx ~meta_current ~proactive_warmup_elapsed
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
        (* Turn failure threshold: registry tracks count (via unified_turn,
                 and via [record_crashed_cycle_failure] for swallowed cycle
                 exceptions), keepalive raises to terminate the fiber for
                 supervisor restart. *)
        let turn_fail_count =
          Keeper_registry.get_turn_failures ~base_path:ctx.config.base_path m.name
        in
        (* RFC-0002: dispatch turn status event *)
        Keeper_keepalive_signal.dispatch_keepalive_event
          ~ctx
          ~keeper_name:m.name
          (turn_status_event
             ~turn_fail_count
             ~max_allowed:(Keeper_heartbeat_snapshot.max_consecutive_turn_failures ()));
        if turn_fail_count >= Keeper_heartbeat_snapshot.max_consecutive_turn_failures ()
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
            ~consecutive_failures;
        let t_turn_end = Time_compat.now () in
        let t_recurring_start = t_turn_end in
        (* Recurring task dispatch (#3190) *)
        let _recurring_dispatched =
          dispatch_recurring_keepalive ~ctx ~meta_after_proactive ~now_ts
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
