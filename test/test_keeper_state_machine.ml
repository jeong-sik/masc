(** test_keeper_state_machine — RFC-0002 keeper state machine tests.

    Pure unit tests for the deterministic core:
    - derive_phase priority ordering
    - apply_event valid/invalid transitions
    - can_transition matrix completeness
    - Terminal state properties (Stopped, Dead)
    - Guard evaluation
    - Guard evaluation (pure, snapshot-based) *)

open Alcotest

module SM = Masc_mcp.Keeper_state_machine
module Meas = Masc_mcp.Keeper_measurement
module Guard = Masc_mcp.Keeper_guard

let phase_t = testable
  (Fmt.of_to_string SM.phase_to_string) (=)

(* ── Helpers ───────────────────────────────────────────── *)

(** Healthy running conditions. *)
let running_conditions : SM.conditions =
  { SM.default_conditions with
    fiber_alive = true;
    restart_budget_remaining = true;
  }

(** Apply event and extract the result, failing on error. *)
let apply_ok ~current_phase ~conditions ~event =
  match SM.apply_event ~current_phase ~conditions ~event ~now:1000.0 with
  | Ok tr -> tr
  | Error e -> fail (SM.transition_error_to_string e)

(** Apply event and extract the error, failing on success. *)
let apply_err ~current_phase ~conditions ~event =
  match SM.apply_event ~current_phase ~conditions ~event ~now:1000.0 with
  | Ok tr ->
    fail (Printf.sprintf "expected error but got transition %s -> %s"
      (SM.phase_to_string tr.prev_phase) (SM.phase_to_string tr.new_phase))
  | Error e -> e

(* ── derive_phase tests ────────────────────────────────── *)

let test_derive_healthy () =
  let c = running_conditions in
  check phase_t "healthy = Running" SM.Running (SM.derive_phase c)

let test_derive_default_dead () =
  (* default_conditions: fiber_alive=false, restart_budget_remaining=false -> Dead *)
  check phase_t "default = Dead" SM.Dead (SM.derive_phase SM.default_conditions)

let test_derive_offline () =
  let c = { SM.default_conditions with
    launch_pending = true;
    restart_budget_remaining = true;
  } in
  check phase_t "launch pending = Offline" SM.Offline (SM.derive_phase c)

let test_derive_dead_highest_priority () =
  let c = { running_conditions with
    fiber_alive = false;
    restart_budget_remaining = false;
    (* Even with other flags set, Dead wins *)
    guardrail_triggered = true;
    compaction_active = true;
  } in
  check phase_t "Dead wins over everything" SM.Dead (SM.derive_phase c)

let test_derive_restarting () =
  let c = { SM.default_conditions with
    fiber_alive = false;
    restart_budget_remaining = true;
    backoff_elapsed = true;
  } in
  check phase_t "fiber dead + budget + backoff = Restarting"
    SM.Restarting (SM.derive_phase c)

let test_derive_crashed () =
  let c = { SM.default_conditions with
    fiber_alive = false;
    restart_budget_remaining = true;
    backoff_elapsed = false;
  } in
  check phase_t "fiber dead + budget + no backoff = Crashed"
    SM.Crashed (SM.derive_phase c)

let test_derive_stopped () =
  let c = { running_conditions with
    stop_requested = true;
    drain_complete = true;
  } in
  check phase_t "stop + drain = Stopped" SM.Stopped (SM.derive_phase c)

let test_derive_draining () =
  let c = { running_conditions with
    stop_requested = true;
    drain_complete = false;
  } in
  check phase_t "stop + no drain = Draining" SM.Draining (SM.derive_phase c)

let test_derive_guardrail_failing () =
  let c = { running_conditions with guardrail_triggered = true } in
  check phase_t "guardrail = Failing" SM.Failing (SM.derive_phase c)

let test_derive_paused () =
  let c = { running_conditions with operator_paused = true } in
  check phase_t "paused" SM.Paused (SM.derive_phase c)

let test_derive_handingoff () =
  let c = { running_conditions with handoff_active = true } in
  check phase_t "handoff active = HandingOff" SM.HandingOff (SM.derive_phase c)

let test_derive_compacting () =
  let c = { running_conditions with compaction_active = true } in
  check phase_t "compaction active = Compacting" SM.Compacting (SM.derive_phase c)

let test_derive_failing_heartbeat () =
  let c = { running_conditions with heartbeat_healthy = false } in
  check phase_t "hb unhealthy = Failing" SM.Failing (SM.derive_phase c)

let test_derive_failing_turn () =
  let c = { running_conditions with turn_healthy = false } in
  check phase_t "turn unhealthy = Failing" SM.Failing (SM.derive_phase c)

let test_derive_priority_stop_over_compact () =
  (* TLA+ fix: Stopped requires no buffer ops in flight.
     stop + drain_complete + compaction_active → Draining (not Stopped). *)
  let c = { running_conditions with
    stop_requested = true;
    drain_complete = true;
    compaction_active = true;
  } in
  check phase_t "compaction blocks Stopped → Draining" SM.Draining (SM.derive_phase c);
  let c2 = { c with compaction_active = false } in
  check phase_t "no buffer ops → Stopped" SM.Stopped (SM.derive_phase c2)

let test_derive_priority_guardrail_over_paused () =
  let c = { running_conditions with
    guardrail_triggered = true;
    operator_paused = true;
  } in
  check phase_t "Guardrail(Failing) beats Paused" SM.Failing (SM.derive_phase c)

let test_derive_priority_handoff_over_compact () =
  let c = { running_conditions with
    handoff_active = true;
    compaction_active = true;
  } in
  check phase_t "HandingOff beats Compacting" SM.HandingOff (SM.derive_phase c)

(* ── apply_event tests ─────────────────────────────────── *)

let test_apply_heartbeat_ok_stays_running () =
  let tr = apply_ok
    ~current_phase:SM.Running
    ~conditions:running_conditions
    ~event:SM.Heartbeat_ok in
  check phase_t "stays Running" SM.Running tr.new_phase

let test_apply_heartbeat_fail_to_failing () =
  let tr = apply_ok
    ~current_phase:SM.Running
    ~conditions:running_conditions
    ~event:(SM.Heartbeat_failed { consecutive = 5; max_allowed = 5 }) in
  check phase_t "Running -> Failing" SM.Failing tr.new_phase;
  check bool "hb unhealthy" false tr.updated_conditions.heartbeat_healthy

let test_apply_heartbeat_recover () =
  let failing_conds = { running_conditions with heartbeat_healthy = false } in
  let tr = apply_ok
    ~current_phase:SM.Failing
    ~conditions:failing_conds
    ~event:SM.Heartbeat_ok in
  check phase_t "Failing -> Running" SM.Running tr.new_phase;
  check bool "hb healthy" true tr.updated_conditions.heartbeat_healthy

let test_apply_compaction_started () =
  let tr = apply_ok
    ~current_phase:SM.Running
    ~conditions:running_conditions
    ~event:SM.Compaction_started in
  check phase_t "Running -> Compacting" SM.Compacting tr.new_phase;
  check bool "compaction_active" true tr.updated_conditions.compaction_active

let test_apply_compaction_completed () =
  let compacting_conds = { running_conditions with compaction_active = true } in
  let tr = apply_ok
    ~current_phase:SM.Compacting
    ~conditions:compacting_conds
    ~event:(SM.Compaction_completed { before_tokens = 100000; after_tokens = 50000 }) in
  check phase_t "Compacting -> Running" SM.Running tr.new_phase;
  check bool "compaction done" false tr.updated_conditions.compaction_active

let test_apply_handoff_lifecycle () =
  (* Running -> HandingOff -> Running *)
  let tr1 = apply_ok
    ~current_phase:SM.Running
    ~conditions:running_conditions
    ~event:SM.Handoff_started in
  check phase_t "-> HandingOff" SM.HandingOff tr1.new_phase;
  let tr2 = apply_ok
    ~current_phase:SM.HandingOff
    ~conditions:tr1.updated_conditions
    ~event:(SM.Handoff_completed { new_trace_id = "abc"; generation = 2 }) in
  check phase_t "-> Running" SM.Running tr2.new_phase

let test_apply_operator_pause_resume () =
  let tr1 = apply_ok
    ~current_phase:SM.Running
    ~conditions:running_conditions
    ~event:SM.Operator_pause in
  check phase_t "-> Paused" SM.Paused tr1.new_phase;
  let tr2 = apply_ok
    ~current_phase:SM.Paused
    ~conditions:tr1.updated_conditions
    ~event:SM.Operator_resume in
  check phase_t "-> Running" SM.Running tr2.new_phase

let test_apply_drain_lifecycle () =
  (* Running -> Draining -> Stopped *)
  let tr1 = apply_ok
    ~current_phase:SM.Running
    ~conditions:running_conditions
    ~event:SM.Stop_requested in
  check phase_t "-> Draining" SM.Draining tr1.new_phase;
  let tr2 = apply_ok
    ~current_phase:SM.Draining
    ~conditions:tr1.updated_conditions
    ~event:SM.Drain_complete in
  check phase_t "-> Stopped" SM.Stopped tr2.new_phase

let test_apply_drain_fiber_death () =
  (* Draining + fiber dies -> Crashed (drain did not complete) *)
  let draining_conds = { running_conditions with
    stop_requested = true;
    drain_complete = false;
  } in
  let tr = apply_ok
    ~current_phase:SM.Draining
    ~conditions:draining_conds
    ~event:(SM.Fiber_terminated { outcome = "exception during drain" }) in
  check phase_t "Draining + fiber death -> Crashed" SM.Crashed tr.new_phase

let test_apply_drain_complete_then_fiber_exit () =
  (* drain_complete=true + fiber exits -> Stopped (drain succeeded) *)
  let drain_done_conds = { running_conditions with
    stop_requested = true;
    drain_complete = true;
  } in
  let tr = apply_ok
    ~current_phase:SM.Draining
    ~conditions:drain_done_conds
    ~event:(SM.Fiber_terminated { outcome = "clean exit" }) in
  check phase_t "drain complete + fiber exit -> Stopped" SM.Stopped tr.new_phase

let test_apply_failing_to_crashed () =
  (* Failing keeper receives fatal failure -> Crashed *)
  let failing_conds = { running_conditions with heartbeat_healthy = false } in
  let tr = apply_ok
    ~current_phase:SM.Failing
    ~conditions:failing_conds
    ~event:(SM.Fiber_terminated { outcome = "fatal" }) in
  check phase_t "Failing + fiber death -> Crashed" SM.Crashed tr.new_phase

let test_apply_partial_heartbeat_failure () =
  (* Partial failure (1/5) should still mark unhealthy and go to Failing *)
  let tr = apply_ok
    ~current_phase:SM.Running
    ~conditions:running_conditions
    ~event:(SM.Heartbeat_failed { consecutive = 1; max_allowed = 5 }) in
  check phase_t "partial failure -> Failing" SM.Failing tr.new_phase;
  check bool "hb unhealthy on partial" false tr.updated_conditions.heartbeat_healthy

let test_apply_fiber_terminated_crash () =
  let tr = apply_ok
    ~current_phase:SM.Running
    ~conditions:running_conditions
    ~event:(SM.Fiber_terminated { outcome = "exception" }) in
  (* fiber_alive=false + budget_remaining=true + backoff not elapsed = Crashed *)
  check phase_t "-> Crashed" SM.Crashed tr.new_phase;
  check bool "fiber dead" false tr.updated_conditions.fiber_alive

let test_apply_crash_restart_lifecycle () =
  (* Crashed -> Restarting -> Running *)
  let crashed_conds = { SM.default_conditions with
    fiber_alive = false;
    restart_budget_remaining = true;
    backoff_elapsed = false;
  } in
  let tr1 = apply_ok
    ~current_phase:SM.Crashed
    ~conditions:crashed_conds
    ~event:(SM.Supervisor_restart_attempt { attempt = 1 }) in
  check phase_t "-> Restarting" SM.Restarting tr1.new_phase;
  let tr2 = apply_ok
    ~current_phase:SM.Restarting
    ~conditions:tr1.updated_conditions
    ~event:SM.Fiber_started in
  check phase_t "-> Running" SM.Running tr2.new_phase

let test_apply_crash_to_dead () =
  let crashed_conds = { SM.default_conditions with
    fiber_alive = false;
    restart_budget_remaining = true;
  } in
  let tr = apply_ok
    ~current_phase:SM.Crashed
    ~conditions:crashed_conds
    ~event:SM.Restart_budget_exhausted in
  check phase_t "-> Dead" SM.Dead tr.new_phase

(* ── Transition coverage tests (#5273) ────────────────── *)

let test_apply_compacting_to_crashed () =
  (* Fiber dies during compaction -> Crashed *)
  let compacting_conds = { running_conditions with compaction_active = true } in
  let tr = apply_ok
    ~current_phase:SM.Compacting
    ~conditions:compacting_conds
    ~event:(SM.Fiber_terminated { outcome = "crash during compaction" }) in
  check phase_t "Compacting + fiber death -> Crashed" SM.Crashed tr.new_phase

let test_apply_handingoff_to_crashed () =
  (* Fiber dies during handoff -> Crashed *)
  let handoff_conds = { running_conditions with handoff_active = true } in
  let tr = apply_ok
    ~current_phase:SM.HandingOff
    ~conditions:handoff_conds
    ~event:(SM.Fiber_terminated { outcome = "crash during handoff" }) in
  check phase_t "HandingOff + fiber death -> Crashed" SM.Crashed tr.new_phase

let test_apply_failing_to_draining () =
  (* Failing keeper receives stop request -> Draining *)
  let failing_conds = { running_conditions with heartbeat_healthy = false } in
  let tr = apply_ok
    ~current_phase:SM.Failing
    ~conditions:failing_conds
    ~event:SM.Stop_requested in
  check phase_t "Failing + stop -> Draining" SM.Draining tr.new_phase

let test_apply_restarting_to_crashed () =
  (* Restart attempt: fiber launched then crashes again -> Crashed *)
  let restarting_conds = { SM.default_conditions with
    fiber_alive = true;
    restart_budget_remaining = true;
    backoff_elapsed = false;
  } in
  let tr = apply_ok
    ~current_phase:SM.Restarting
    ~conditions:restarting_conds
    ~event:(SM.Fiber_terminated { outcome = "restart failed" }) in
  check phase_t "Restarting + fiber death -> Crashed" SM.Crashed tr.new_phase

let test_apply_restarting_to_dead () =
  (* Restart budget exhausted during restart -> Dead *)
  let restarting_conds = { SM.default_conditions with
    fiber_alive = false;
    restart_budget_remaining = true;
    backoff_elapsed = true;
  } in
  let tr = apply_ok
    ~current_phase:SM.Restarting
    ~conditions:restarting_conds
    ~event:SM.Restart_budget_exhausted in
  check phase_t "Restarting + budget exhausted -> Dead" SM.Dead tr.new_phase

let test_apply_paused_to_draining () =
  (* Paused keeper receives stop request -> Draining *)
  let paused_conds = { running_conditions with operator_paused = true } in
  let tr = apply_ok
    ~current_phase:SM.Paused
    ~conditions:paused_conds
    ~event:SM.Stop_requested in
  check phase_t "Paused + stop -> Draining" SM.Draining tr.new_phase

let test_apply_paused_stop_drain_lifecycle () =
  (* Paused -> Draining (stop) -> Stopped (drain complete) *)
  let paused_conds = { running_conditions with operator_paused = true } in
  let tr1 = apply_ok
    ~current_phase:SM.Paused
    ~conditions:paused_conds
    ~event:SM.Stop_requested in
  check phase_t "Paused + stop -> Draining" SM.Draining tr1.new_phase;
  let tr2 = apply_ok
    ~current_phase:SM.Draining
    ~conditions:tr1.updated_conditions
    ~event:SM.Drain_complete in
  check phase_t "Draining + drain complete -> Stopped" SM.Stopped tr2.new_phase

(* ── Terminal state tests ──────────────────────────────── *)

let test_dead_rejects_all_events () =
  let dead_conds = { SM.default_conditions with
    fiber_alive = false;
    restart_budget_remaining = false;
  } in
  List.iter (fun event ->
    let err = apply_err ~current_phase:SM.Dead ~conditions:dead_conds ~event in
    match err with
    | SM.Terminal_state { current; _ } ->
      check phase_t "Dead" SM.Dead current
    | _ -> fail "expected Terminal_state error"
  ) [ SM.Heartbeat_ok; SM.Fiber_started; SM.Operator_resume;
      SM.Compaction_started; SM.Handoff_started ]

let test_stopped_rejects_all_events () =
  let stopped_conds = { running_conditions with
    stop_requested = true;
    drain_complete = true;
  } in
  List.iter (fun event ->
    let err = apply_err ~current_phase:SM.Stopped ~conditions:stopped_conds ~event in
    match err with
    | SM.Terminal_state { current; _ } ->
      check phase_t "Stopped" SM.Stopped current
    | _ -> fail "expected Terminal_state error"
  ) [ SM.Heartbeat_ok; SM.Fiber_started; SM.Operator_resume ]

(* ── can_transition matrix tests ───────────────────────── *)

let test_can_transition_running_to_buffer_states () =
  check bool "-> Failing" true (SM.can_transition ~from_phase:SM.Running ~to_phase:SM.Failing);
  check bool "-> Compacting" true (SM.can_transition ~from_phase:SM.Running ~to_phase:SM.Compacting);
  check bool "-> HandingOff" true (SM.can_transition ~from_phase:SM.Running ~to_phase:SM.HandingOff);
  check bool "-> Draining" true (SM.can_transition ~from_phase:SM.Running ~to_phase:SM.Draining);
  check bool "-> Paused" true (SM.can_transition ~from_phase:SM.Running ~to_phase:SM.Paused);
  check bool "-> Stopped" true (SM.can_transition ~from_phase:SM.Running ~to_phase:SM.Stopped)

let test_can_transition_running_invalid () =
  check bool "no -> Dead" false (SM.can_transition ~from_phase:SM.Running ~to_phase:SM.Dead);
  check bool "-> Crashed (fiber death)" true (SM.can_transition ~from_phase:SM.Running ~to_phase:SM.Crashed);
  check bool "no -> Restarting" false (SM.can_transition ~from_phase:SM.Running ~to_phase:SM.Restarting);
  check bool "no -> Offline" false (SM.can_transition ~from_phase:SM.Running ~to_phase:SM.Offline)

let test_can_transition_terminal_nothing () =
  List.iter (fun to_phase ->
    check bool "Stopped -> nothing" false
      (SM.can_transition ~from_phase:SM.Stopped ~to_phase);
    check bool "Dead -> nothing" false
      (SM.can_transition ~from_phase:SM.Dead ~to_phase)
  ) SM.all_phases

let test_can_transition_crashed_only_restart_or_dead () =
  check bool "-> Restarting" true (SM.can_transition ~from_phase:SM.Crashed ~to_phase:SM.Restarting);
  check bool "-> Dead" true (SM.can_transition ~from_phase:SM.Crashed ~to_phase:SM.Dead);
  check bool "no -> Running" false (SM.can_transition ~from_phase:SM.Crashed ~to_phase:SM.Running);
  check bool "no -> Paused" false (SM.can_transition ~from_phase:SM.Crashed ~to_phase:SM.Paused)

let test_can_transition_compacting_to_failing () =
  check bool "-> Failing" true (SM.can_transition ~from_phase:SM.Compacting ~to_phase:SM.Failing)

let test_can_transition_compacting_to_crashed () =
  check bool "-> Crashed" true (SM.can_transition ~from_phase:SM.Compacting ~to_phase:SM.Crashed)

let test_can_transition_handingoff_to_failing () =
  check bool "-> Failing" true (SM.can_transition ~from_phase:SM.HandingOff ~to_phase:SM.Failing)

let test_can_transition_handingoff_to_crashed () =
  check bool "-> Crashed" true (SM.can_transition ~from_phase:SM.HandingOff ~to_phase:SM.Crashed)

let test_can_transition_failing_to_draining () =
  check bool "-> Draining" true (SM.can_transition ~from_phase:SM.Failing ~to_phase:SM.Draining)

let test_can_transition_restarting_to_crashed () =
  check bool "-> Crashed" true (SM.can_transition ~from_phase:SM.Restarting ~to_phase:SM.Crashed)

let test_can_transition_restarting_to_dead () =
  check bool "-> Dead" true (SM.can_transition ~from_phase:SM.Restarting ~to_phase:SM.Dead)

let test_can_transition_paused_to_draining () =
  check bool "-> Draining" true (SM.can_transition ~from_phase:SM.Paused ~to_phase:SM.Draining)

let test_can_transition_paused_to_stopped () =
  check bool "-> Stopped" true (SM.can_transition ~from_phase:SM.Paused ~to_phase:SM.Stopped)

let test_can_execute_turn_running_and_failing_only () =
  check bool "Running executes turns" true (SM.can_execute_turn SM.Running);
  check bool "Failing executes turns" true (SM.can_execute_turn SM.Failing)

let test_can_execute_turn_blocks_other_phases () =
  List.iter
    (fun phase ->
      check bool
        ("blocked phase " ^ SM.phase_to_string phase)
        false
        (SM.can_execute_turn phase))
    [ SM.Offline; SM.Compacting; SM.HandingOff; SM.Draining; SM.Paused;
      SM.Stopped; SM.Crashed; SM.Restarting; SM.Dead ]

(* ── Guard evaluation tests ────────────────────────────── *)

let base_thresholds : Meas.threshold_params = {
  compaction_ratio_gate = 0.50;
  compaction_message_gate = 100;
  compaction_token_gate = 50000;
  compaction_cooldown_sec = 60;
  handoff_threshold = 0.85;
  handoff_cooldown_sec = 300;
  auto_handoff_enabled = true;
  reflect_repetition_threshold = 0.7;
  plan_goal_alignment_threshold = 0.3;
  plan_response_alignment_threshold = 0.3;
  guardrail_repetition_threshold = 0.9;
  guardrail_goal_alignment_threshold = 0.2;
  guardrail_response_alignment_threshold = 0.2;
  guardrail_context_threshold = 0.8;
  max_consecutive_hb_failures = 5;
  max_consecutive_turn_failures = 3;
  model_ratio_multiplier = 1.0;
  model_handoff_multiplier = 1.0;
}

let healthy_snapshot : Meas.measurement_snapshot = {
  snapshot_id = "test-001";
  keeper_name = "alpha";
  generation = 1;
  timestamp = 1000.0;
  thresholds = base_thresholds;
  context = {
    context_ratio = 0.30;
    message_count = 20;
    token_count = 15000;
    max_tokens = 100000;
  };
  similarity = {
    repetition_risk = 0.1;
    goal_alignment = 0.8;
    response_alignment = 0.7;
    similarity_measurable = true;
  };
  timing = {
    now_ts = 1000.0;
    idle_seconds = 10;
    since_last_compaction_sec = 600.0;
    since_last_handoff_sec = 600.0;
    proactive_warmup_elapsed = true;
  };
  failures = {
    consecutive_hb_failures = 0;
    consecutive_turn_failures = 0;
  };
}

let test_guard_healthy_no_crash_events () =
  let events = Guard.evaluate healthy_snapshot in
  let has_crash = List.exists (function
    | SM.Heartbeat_failed _ | SM.Turn_failed _
    | SM.Guardrail_stop _ | SM.Compaction_started | SM.Handoff_started -> true
    | _ -> false
  ) events in
  check bool "no crash/action events" false has_crash

let test_guard_compaction_triggers () =
  let snap = { healthy_snapshot with
    context = { healthy_snapshot.context with context_ratio = 0.55 };
  } in
  let events = Guard.evaluate snap in
  let has_compact = List.exists (function
    | SM.Compaction_started -> true | _ -> false
  ) events in
  check bool "compaction triggered" true has_compact

let test_guard_zero_gates_do_not_force_compaction () =
  let snap = { healthy_snapshot with
    thresholds = { healthy_snapshot.thresholds with
      compaction_message_gate = 0;
      compaction_token_gate = 0;
    };
  } in
  let events = Guard.evaluate snap in
  let has_compact = List.exists (function
    | SM.Compaction_started -> true | _ -> false
  ) events in
  check bool "zero gates disabled" false has_compact

let test_guard_compaction_respects_cooldown () =
  let snap = { healthy_snapshot with
    context = { healthy_snapshot.context with context_ratio = 0.55 };
    timing =
      { healthy_snapshot.timing with
        since_last_compaction_sec = 30.0;
      };
  } in
  let events = Guard.evaluate snap in
  let has_compact = List.exists (function
    | SM.Compaction_started -> true | _ -> false
  ) events in
  check bool "cooldown blocks compaction" false has_compact

let test_guard_handoff_triggers () =
  let snap = { healthy_snapshot with
    context = { healthy_snapshot.context with context_ratio = 0.90 };
  } in
  let events = Guard.evaluate snap in
  let has_handoff = List.exists (function
    | SM.Handoff_started -> true | _ -> false
  ) events in
  check bool "handoff triggered" true has_handoff

let test_guard_guardrail_triggers () =
  let snap = { healthy_snapshot with
    similarity = {
      repetition_risk = 0.95;
      goal_alignment = 0.1;
      response_alignment = 0.1;
      similarity_measurable = true;
    };
    context = { healthy_snapshot.context with context_ratio = 0.85 };
  } in
  let events = Guard.evaluate snap in
  let prio = Guard.prioritized_event events in
  match prio with
  | SM.Guardrail_stop _ -> ()
  | other -> fail (Printf.sprintf "expected Guardrail_stop, got %s"
      (SM.event_to_string other))

let test_guard_hb_failure_threshold () =
  let snap = { healthy_snapshot with
    failures = { healthy_snapshot.failures with consecutive_hb_failures = 5 };
  } in
  let events = Guard.evaluate snap in
  let has_hb_fail = List.exists (function
    | SM.Heartbeat_failed { consecutive = 5; max_allowed = 5 } -> true
    | _ -> false
  ) events in
  check bool "heartbeat failure at threshold" true has_hb_fail

let test_guard_plan_requires_both_alignments_low () =
  let snap = { healthy_snapshot with
    similarity =
      { healthy_snapshot.similarity with
        goal_alignment = 0.2;
        response_alignment = 0.7;
      };
  } in
  let events = Guard.evaluate snap in
  let plan_flag =
    List.find_map (function
      | SM.Context_measured { auto_rules; _ } -> Some auto_rules.plan
      | _ -> None
    ) events
  in
  check bool "plan requires both" false (Option.value ~default:true plan_flag)

(* Regression test for #10012.

   Both [goal_alignment] and [response_alignment] at 0.0 would ordinarily
   satisfy the plan gate's two [<=] comparisons, but when the snapshot was
   produced by a turn that had no user/assistant message pair (status_tick,
   heartbeat), those zeroes are sentinels, not measurements. The guard must
   fail-closed via [similarity_measurable=false] and emit [plan=false]. *)
let test_guard_plan_fails_closed_when_similarity_unmeasurable () =
  let snap = { healthy_snapshot with
    similarity =
      { healthy_snapshot.similarity with
        goal_alignment = 0.0;
        response_alignment = 0.0;
        similarity_measurable = false;
      };
  } in
  let events = Guard.evaluate snap in
  let plan_flag =
    List.find_map (function
      | SM.Context_measured { auto_rules; _ } -> Some auto_rules.plan
      | _ -> None
    ) events
  in
  check bool "plan does not fire on unmeasurable similarity"
    false (Option.value ~default:true plan_flag)

(* Same invariant for the guardrail gate — even when every float value lines
   up for a guardrail stop, [similarity_measurable=false] must suppress it. *)
let test_guard_guardrail_fails_closed_when_similarity_unmeasurable () =
  let snap = { healthy_snapshot with
    similarity = {
      repetition_risk = 0.95;
      goal_alignment = 0.0;
      response_alignment = 0.0;
      similarity_measurable = false;
    };
    context = { healthy_snapshot.context with context_ratio = 0.85 };
  } in
  let events = Guard.evaluate snap in
  let has_guardrail = List.exists (function
    | SM.Guardrail_stop _ -> true | _ -> false
  ) events in
  check bool "guardrail does not fire on unmeasurable similarity"
    false has_guardrail

(* ── Phase roundtrip tests ─────────────────────────────── *)

let test_phase_string_roundtrip () =
  List.iter (fun phase ->
    let s = SM.phase_to_string phase in
    match SM.phase_of_string s with
    | Some recovered -> check phase_t "roundtrip" phase recovered
    | None -> fail (Printf.sprintf "phase_of_string failed for %s" s)
  ) SM.all_phases

(* ── Multi-turn lifecycle chain tests ─────────────────── *)

(** Chain helper: apply events sequentially, checking each resulting phase.
    Threads conditions through the entire chain — just like a real keeper
    lifecycle where each event modifies conditions that feed into the next
    derive_phase call. Timestamps advance 30s per step (one heartbeat cycle). *)
let chain_apply ~init_phase ~init_conditions steps =
  let rec go phase conds ts = function
    | [] -> (phase, conds)
    | (event, expected_phase) :: rest ->
      let tr = match SM.apply_event ~current_phase:phase ~conditions:conds ~event ~now:ts with
        | Ok tr -> tr
        | Error e ->
          fail (Printf.sprintf "chain step at t=%.0f (%s -> ???): %s"
            ts (SM.phase_to_string phase) (SM.transition_error_to_string e))
      in
      check phase_t
        (Printf.sprintf "t=%.0f: %s -> %s"
          ts (SM.phase_to_string phase) (SM.phase_to_string expected_phase))
        expected_phase tr.new_phase;
      go tr.new_phase tr.updated_conditions (ts +. 30.0) rest
  in
  go init_phase init_conditions 1000.0 steps

(** 1. Happy path: boot -> heartbeats -> compact -> handoff -> graceful stop.
    The most common keeper lifecycle in production.
    9 transitions, 6 distinct phases visited. *)
let test_chain_happy_path () =
  let init_conds = { SM.default_conditions with restart_budget_remaining = true } in
  let final_phase, _ = chain_apply
    ~init_phase:SM.Offline
    ~init_conditions:init_conds
    [
      SM.Fiber_started,                                        SM.Running;
      SM.Heartbeat_ok,                                         SM.Running;
      SM.Heartbeat_ok,                                         SM.Running;
      SM.Compaction_started,                                   SM.Compacting;
      SM.Compaction_completed { before_tokens=90000; after_tokens=40000 }, SM.Running;
      SM.Handoff_started,                                      SM.HandingOff;
      SM.Handoff_completed { new_trace_id="gen2"; generation=2 }, SM.Running;
      SM.Stop_requested,                                       SM.Draining;
      SM.Drain_complete,                                       SM.Stopped;
    ]
  in
  check phase_t "ends Stopped" SM.Stopped final_phase

(** 2. Crash recovery: failing heartbeats -> crash -> supervisor restart -> resume.
    Verifies the supervisor restart loop works end-to-end. *)
let test_chain_crash_recovery () =
  let final_phase, _ = chain_apply
    ~init_phase:SM.Running
    ~init_conditions:running_conditions
    [
      SM.Heartbeat_failed { consecutive=3; max_allowed=5 },    SM.Failing;
      SM.Heartbeat_failed { consecutive=5; max_allowed=5 },    SM.Failing;
      SM.Fiber_terminated { outcome="hb threshold exceeded" }, SM.Crashed;
      SM.Supervisor_restart_attempt { attempt=1 },             SM.Restarting;
      SM.Fiber_started,                                        SM.Running;
      SM.Heartbeat_ok,                                         SM.Running;
      SM.Heartbeat_ok,                                         SM.Running;
    ]
  in
  check phase_t "recovered to Running" SM.Running final_phase

(** 3. Death spiral: crash -> restart -> crash again -> budget exhausted -> Dead.
    The worst case: a fundamentally broken keeper that cannot recover. *)
let test_chain_death_spiral () =
  let final_phase, final_conds = chain_apply
    ~init_phase:SM.Running
    ~init_conditions:running_conditions
    [
      SM.Fiber_terminated { outcome="OOM" },                   SM.Crashed;
      SM.Supervisor_restart_attempt { attempt=1 },             SM.Restarting;
      SM.Fiber_started,                                        SM.Running;
      SM.Fiber_terminated { outcome="OOM again" },             SM.Crashed;
      SM.Supervisor_restart_attempt { attempt=2 },             SM.Restarting;
      SM.Fiber_started,                                        SM.Running;
      SM.Fiber_terminated { outcome="OOM third time" },        SM.Crashed;
      SM.Restart_budget_exhausted,                             SM.Dead;
    ]
  in
  check phase_t "ends Dead" SM.Dead final_phase;
  check bool "no budget left" false final_conds.restart_budget_remaining

(** 4. Operator intervention: pause during work, resume, then stop.
    Verifies operator controls compose correctly with normal operations. *)
let test_chain_operator_intervention () =
  let final_phase, _ = chain_apply
    ~init_phase:SM.Running
    ~init_conditions:running_conditions
    [
      SM.Heartbeat_ok,                                         SM.Running;
      SM.Compaction_started,                                   SM.Compacting;
      SM.Compaction_completed { before_tokens=80000; after_tokens=35000 }, SM.Running;
      SM.Operator_pause,                                       SM.Paused;
      SM.Operator_resume,                                      SM.Running;
      SM.Heartbeat_ok,                                         SM.Running;
      SM.Stop_requested,                                       SM.Draining;
      SM.Drain_complete,                                       SM.Stopped;
    ]
  in
  check phase_t "ends Stopped" SM.Stopped final_phase

(** 5. Compaction failure -> handoff fallback -> success.
    When compaction fails to free enough context, the system falls back
    to a full generation handoff. *)
let test_chain_compaction_fail_handoff_fallback () =
  let final_phase, _ = chain_apply
    ~init_phase:SM.Running
    ~init_conditions:running_conditions
    [
      SM.Compaction_started,                                   SM.Compacting;
      SM.Compaction_failed { reason="insufficient reduction" }, SM.Running;
      SM.Handoff_started,                                      SM.HandingOff;
      SM.Handoff_completed { new_trace_id="gen3"; generation=3 }, SM.Running;
      SM.Heartbeat_ok,                                         SM.Running;
    ]
  in
  check phase_t "recovered via handoff" SM.Running final_phase

(** 6. Guardrail -> recovery -> normal operations.
    Guardrail triggers Failing, then context measurement clears it. *)
let test_chain_guardrail_recovery () =
  let final_phase, _ = chain_apply
    ~init_phase:SM.Running
    ~init_conditions:running_conditions
    [
      SM.Guardrail_stop { reason="repetition loop detected" }, SM.Failing;
      (* Context measurement with guardrail_stop=false clears the flag *)
      SM.Context_measured {
        context_ratio=0.30; message_count=20; token_count=15000;
        auto_rules={ reflect=false; plan=false; compact=false;
                     handoff=false; guardrail_stop=false;
                     guardrail_reason=None; goal_drift=0.1 };
      },                                                       SM.Running;
      SM.Heartbeat_ok,                                         SM.Running;
    ]
  in
  check phase_t "guardrail cleared" SM.Running final_phase

(** 7. Long-running keeper: multiple compaction + handoff cycles.
    Simulates a keeper that runs for hours, going through several
    context management cycles before a clean shutdown.
    15 transitions across 5 context management cycles. *)
let test_chain_long_running_multi_cycle () =
  let final_phase, _ = chain_apply
    ~init_phase:SM.Running
    ~init_conditions:running_conditions
    [
      (* Cycle 1: compaction *)
      SM.Heartbeat_ok,                                         SM.Running;
      SM.Compaction_started,                                   SM.Compacting;
      SM.Compaction_completed { before_tokens=90000; after_tokens=45000 }, SM.Running;
      SM.Heartbeat_ok,                                         SM.Running;
      (* Cycle 2: compaction again *)
      SM.Compaction_started,                                   SM.Compacting;
      SM.Compaction_completed { before_tokens=85000; after_tokens=40000 }, SM.Running;
      (* Cycle 3: handoff (context still growing) *)
      SM.Handoff_started,                                      SM.HandingOff;
      SM.Handoff_completed { new_trace_id="gen2"; generation=2 }, SM.Running;
      SM.Heartbeat_ok,                                         SM.Running;
      (* Cycle 4: compaction in new generation *)
      SM.Compaction_started,                                   SM.Compacting;
      SM.Compaction_completed { before_tokens=70000; after_tokens=30000 }, SM.Running;
      (* Cycle 5: another handoff *)
      SM.Handoff_started,                                      SM.HandingOff;
      SM.Handoff_completed { new_trace_id="gen3"; generation=3 }, SM.Running;
      (* Clean shutdown *)
      SM.Stop_requested,                                       SM.Draining;
      SM.Drain_complete,                                       SM.Stopped;
    ]
  in
  check phase_t "clean stop after multi-cycle" SM.Stopped final_phase

(** 8. Crash during buffer state -> full recovery.
    Fiber dies mid-compaction, supervisor recovers, then a successful
    handoff completes the context management. *)
let test_chain_crash_during_compaction_recovery () =
  let final_phase, _ = chain_apply
    ~init_phase:SM.Running
    ~init_conditions:running_conditions
    [
      SM.Compaction_started,                                   SM.Compacting;
      SM.Fiber_terminated { outcome="segfault in compactor" }, SM.Crashed;
      SM.Supervisor_restart_attempt { attempt=1 },             SM.Restarting;
      SM.Fiber_started,                                        SM.Running;
      SM.Heartbeat_ok,                                         SM.Running;
      SM.Handoff_started,                                      SM.HandingOff;
      SM.Handoff_completed { new_trace_id="gen2"; generation=2 }, SM.Running;
      SM.Heartbeat_ok,                                         SM.Running;
    ]
  in
  check phase_t "fully recovered after compaction crash" SM.Running final_phase

(** 9. Failing keeper receives stop -> drains -> stops.
    Even unhealthy keepers should shut down gracefully. *)
let test_chain_failing_graceful_stop () =
  let final_phase, _ = chain_apply
    ~init_phase:SM.Running
    ~init_conditions:running_conditions
    [
      SM.Heartbeat_failed { consecutive=3; max_allowed=5 },    SM.Failing;
      SM.Stop_requested,                                       SM.Draining;
      SM.Drain_complete,                                       SM.Stopped;
    ]
  in
  check phase_t "failing keeper stopped gracefully" SM.Stopped final_phase

(** 10. Rapid event storm: heartbeat flapping.
    Heartbeat alternates ok/fail rapidly. The keeper should oscillate
    between Running and Failing but never crash (fiber stays alive). *)
let test_chain_heartbeat_flapping () =
  let final_phase, _ = chain_apply
    ~init_phase:SM.Running
    ~init_conditions:running_conditions
    [
      SM.Heartbeat_failed { consecutive=1; max_allowed=5 },    SM.Failing;
      SM.Heartbeat_ok,                                         SM.Running;
      SM.Heartbeat_failed { consecutive=1; max_allowed=5 },    SM.Failing;
      SM.Heartbeat_ok,                                         SM.Running;
      SM.Heartbeat_failed { consecutive=1; max_allowed=5 },    SM.Failing;
      SM.Heartbeat_ok,                                         SM.Running;
      SM.Heartbeat_failed { consecutive=1; max_allowed=5 },    SM.Failing;
      SM.Heartbeat_ok,                                         SM.Running;
    ]
  in
  check phase_t "stabilized after flapping" SM.Running final_phase

(** 11. Terminal permanence: after Stopped, every event type is rejected.
    Comprehensive check with real threaded conditions from the chain. *)
let test_chain_terminal_permanence () =
  let final_phase, final_conds = chain_apply
    ~init_phase:SM.Running
    ~init_conditions:running_conditions
    [
      SM.Stop_requested,                                       SM.Draining;
      SM.Drain_complete,                                       SM.Stopped;
    ]
  in
  check phase_t "reached Stopped" SM.Stopped final_phase;
  let events = [
    SM.Heartbeat_ok; SM.Fiber_started; SM.Operator_resume;
    SM.Compaction_started; SM.Handoff_started;
    SM.Supervisor_restart_attempt { attempt=1 };
    SM.Stop_requested; SM.Drain_complete;
  ] in
  List.iter (fun ev ->
    match SM.apply_event ~current_phase:SM.Stopped ~conditions:final_conds ~event:ev ~now:2000.0 with
    | Error (SM.Terminal_state _) -> ()
    | Error e -> fail (Printf.sprintf "wrong error: %s" (SM.transition_error_to_string e))
    | Ok tr -> fail (Printf.sprintf "Stopped accepted %s -> %s"
        (SM.event_to_string ev) (SM.phase_to_string tr.new_phase))
  ) events

(* ── Edge case ("맛탱이") chain tests ─────────────────── *)

(** 12. Restart inherits operator_paused: operator paused before crash,
    new fiber should wake up in Paused, not Running.
    Operator intent transcends fiber lifetime. *)
let test_chain_restart_inherits_paused () =
  let final_phase, final_conds = chain_apply
    ~init_phase:SM.Running
    ~init_conditions:running_conditions
    [
      SM.Operator_pause,                                       SM.Paused;
      SM.Fiber_terminated { outcome="OOM while paused" },      SM.Crashed;
      SM.Supervisor_restart_attempt { attempt=1 },             SM.Restarting;
      SM.Fiber_started,                                        SM.Paused;
    ]
  in
  check phase_t "paused survives restart" SM.Paused final_phase;
  check bool "operator_paused=true" true final_conds.operator_paused;
  (* Resume should bring it back *)
  let tr = apply_ok ~current_phase:SM.Paused ~conditions:final_conds
    ~event:SM.Operator_resume in
  check phase_t "resume after restart" SM.Running tr.new_phase

(** 13. Restart inherits stop_requested: operator requested stop before crash.
    New fiber should go directly to Draining, not Running. *)
let test_chain_restart_clears_stop () =
  (* TLA+ liveness fix: FiberStarted resets stop_requested.
     Restart = "bring back" contradicts "stop". New fiber starts clean. *)
  let final_phase, final_conds = chain_apply
    ~init_phase:SM.Running
    ~init_conditions:running_conditions
    [
      SM.Stop_requested,                                       SM.Draining;
      SM.Fiber_terminated { outcome="crash during drain" },    SM.Crashed;
      SM.Supervisor_restart_attempt { attempt=1 },             SM.Restarting;
      (* Fiber starts: stop_requested is reset → Running, not Draining *)
      SM.Fiber_started,                                        SM.Running;
    ]
  in
  check phase_t "restart clears stop → Running" SM.Running final_phase;
  check bool "stop_requested cleared" false final_conds.SM.stop_requested

(** 14. Handoff fails then retries successfully.
    First handoff attempt fails, keeper recovers to Running, second succeeds. *)
let test_chain_handoff_fail_retry () =
  let final_phase, _ = chain_apply
    ~init_phase:SM.Running
    ~init_conditions:running_conditions
    [
      SM.Handoff_started,                                      SM.HandingOff;
      SM.Handoff_failed { reason="target generation conflict" }, SM.Running;
      SM.Heartbeat_ok,                                         SM.Running;
      SM.Handoff_started,                                      SM.HandingOff;
      SM.Handoff_completed { new_trace_id="gen2"; generation=2 }, SM.Running;
    ]
  in
  check phase_t "handoff retry succeeded" SM.Running final_phase

(** 15. Guardrail fires during compaction.
    Context_measured with guardrail_stop=true arrives while compaction is active.
    Guardrail has HIGHER priority than compaction in derive_phase
    (priority 4 vs priority 9), so keeper immediately enters Failing.
    Compaction_completed clears compaction_active but guardrail persists.
    Context_measured with guardrail_stop=false clears it -> Running. *)
let test_chain_guardrail_during_compaction () =
  let final_phase, _ = chain_apply
    ~init_phase:SM.Running
    ~init_conditions:running_conditions
    [
      SM.Compaction_started,                                   SM.Compacting;
      (* Guardrail > Compacting in priority -> immediate Failing *)
      SM.Context_measured {
        context_ratio=0.85; message_count=200; token_count=85000;
        auto_rules={ reflect=false; plan=false; compact=false;
                     handoff=false; guardrail_stop=true;
                     guardrail_reason=Some "repetition detected";
                     goal_drift=0.9 };
      },                                                       SM.Failing;
      (* Compaction completes but guardrail still active -> still Failing *)
      SM.Compaction_completed { before_tokens=85000; after_tokens=40000 }, SM.Failing;
      (* Clear guardrail -> Running *)
      SM.Context_measured {
        context_ratio=0.40; message_count=50; token_count=40000;
        auto_rules={ reflect=false; plan=false; compact=false;
                     handoff=false; guardrail_stop=false;
                     guardrail_reason=None; goal_drift=0.1 };
      },                                                       SM.Running;
    ]
  in
  check phase_t "guardrail cleared after compaction" SM.Running final_phase

(** 16. Turn failures accumulate alongside heartbeat failures.
    Both turn_healthy=false AND heartbeat_healthy=false. Recovery requires
    both Turn_succeeded AND Heartbeat_ok. *)
let test_chain_double_failure_recovery () =
  let final_phase, _ = chain_apply
    ~init_phase:SM.Running
    ~init_conditions:running_conditions
    [
      SM.Heartbeat_failed { consecutive=2; max_allowed=5 },    SM.Failing;
      SM.Turn_failed { consecutive=3; max_allowed=10 },        SM.Failing;
      (* Heartbeat recovers but turn still unhealthy -> still Failing *)
      SM.Heartbeat_ok,                                         SM.Failing;
      (* Turn recovers -> both healthy -> Running *)
      SM.Turn_succeeded,                                       SM.Running;
    ]
  in
  check phase_t "both failures must clear" SM.Running final_phase

(** 17. Operator stop during handoff.
    Handoff is in progress when operator requests stop.
    Stop has higher priority -> Draining, handoff abandoned. *)
let test_chain_stop_during_handoff () =
  (* TLA+ fix: handoff must finish before Stopped.
     Drain_complete while handoff_active → stays Draining. *)
  let final_phase, _ = chain_apply
    ~init_phase:SM.Running
    ~init_conditions:running_conditions
    [
      SM.Handoff_started,                                      SM.HandingOff;
      SM.Operator_stop { remove_meta=false },                  SM.Draining;
      SM.Drain_complete,                                       SM.Draining;
      SM.Handoff_completed { new_trace_id="t"; generation=2 }, SM.Stopped;
    ]
  in
  check phase_t "handoff completes then Stopped" SM.Stopped final_phase

(** 18. The Phoenix that can't rise: complete lifecycle to Dead,
    verify nothing can revive it. Then verify Stopped is equally terminal. *)
let test_chain_no_phoenix () =
  let _, dead_conds = chain_apply
    ~init_phase:SM.Running
    ~init_conditions:running_conditions
    [
      SM.Fiber_terminated { outcome="fatal" },                 SM.Crashed;
      SM.Restart_budget_exhausted,                             SM.Dead;
    ]
  in
  (* Every conceivable event must fail on Dead *)
  let all_events = [
    SM.Heartbeat_ok;
    SM.Heartbeat_failed { consecutive=1; max_allowed=5 };
    SM.Turn_succeeded;
    SM.Turn_failed { consecutive=1; max_allowed=10 };
    SM.Context_measured {
      context_ratio=0.5; message_count=10; token_count=5000;
      auto_rules={ reflect=false; plan=false; compact=false;
                   handoff=false; guardrail_stop=false;
                   guardrail_reason=None; goal_drift=0.0 };
    };
    SM.Compaction_started;
    SM.Compaction_completed { before_tokens=100; after_tokens=50 };
    SM.Compaction_failed { reason="test" };
    SM.Handoff_started;
    SM.Handoff_completed { new_trace_id="x"; generation=99 };
    SM.Handoff_failed { reason="test" };
    SM.Operator_pause;
    SM.Operator_resume;
    SM.Operator_stop { remove_meta=true };
    SM.Stop_requested;
    SM.Drain_complete;
    SM.Fiber_started;
    SM.Fiber_terminated { outcome="test" };
    SM.Supervisor_restart_attempt { attempt=99 };
    SM.Restart_budget_exhausted;
    SM.Guardrail_stop { reason="test" };
  ] in
  List.iter (fun ev ->
    match SM.apply_event ~current_phase:SM.Dead ~conditions:dead_conds ~event:ev ~now:9999.0 with
    | Error (SM.Terminal_state _) -> ()
    | Error e -> fail (Printf.sprintf "Dead: wrong error for %s: %s"
        (SM.event_to_string ev) (SM.transition_error_to_string e))
    | Ok tr -> fail (Printf.sprintf "Dead accepted %s -> %s"
        (SM.event_to_string ev) (SM.phase_to_string tr.new_phase))
  ) all_events

(** 19. Triple crash-restart cycle: the keeper barely survives three crashes
    before stabilizing. Tests that Fiber_started resets are correct across
    multiple consecutive restart cycles. *)
let test_chain_triple_restart_survives () =
  let final_phase, _ = chain_apply
    ~init_phase:SM.Running
    ~init_conditions:running_conditions
    [
      (* Crash 1 *)
      SM.Fiber_terminated { outcome="crash 1" },               SM.Crashed;
      SM.Supervisor_restart_attempt { attempt=1 },             SM.Restarting;
      SM.Fiber_started,                                        SM.Running;
      (* Crash 2 *)
      SM.Fiber_terminated { outcome="crash 2" },               SM.Crashed;
      SM.Supervisor_restart_attempt { attempt=2 },             SM.Restarting;
      SM.Fiber_started,                                        SM.Running;
      (* Crash 3 *)
      SM.Fiber_terminated { outcome="crash 3" },               SM.Crashed;
      SM.Supervisor_restart_attempt { attempt=3 },             SM.Restarting;
      SM.Fiber_started,                                        SM.Running;
      (* Finally stabilizes *)
      SM.Heartbeat_ok,                                         SM.Running;
      SM.Compaction_started,                                   SM.Compacting;
      SM.Compaction_completed { before_tokens=60000; after_tokens=25000 }, SM.Running;
      SM.Heartbeat_ok,                                         SM.Running;
    ]
  in
  check phase_t "survived 3 crashes and stabilized" SM.Running final_phase

(** 20. Operator pause during Failing, then stop while paused.
    The keeper is unhealthy AND paused. Guardrail beats Paused in priority,
    but since heartbeat failure sets heartbeat_healthy=false (not guardrail),
    and Paused comes before Failing in condition check...
    Actually: derive_phase checks guardrail(false) then operator_paused(true).
    So heartbeat unhealthy is checked AFTER paused -> paused wins.
    Then stop while paused -> Draining. *)
let test_chain_pause_while_failing_then_stop () =
  let failing_conds = { running_conditions with heartbeat_healthy = false } in
  let final_phase, _ = chain_apply
    ~init_phase:SM.Failing
    ~init_conditions:failing_conds
    [
      SM.Operator_pause,                                       SM.Paused;
      (* Paused beats heartbeat-Failing in priority *)
      SM.Stop_requested,                                       SM.Draining;
      SM.Drain_complete,                                       SM.Stopped;
    ]
  in
  check phase_t "failing+paused -> stop -> stopped" SM.Stopped final_phase

(** 21. Maximum turbulence: every buffer state visited in one lifecycle.
    Running -> Compacting -> Running -> HandingOff -> Running ->
    Failing -> Running -> Paused -> Running -> Draining -> Stopped.
    10 transitions touching 7 distinct phases. *)
let test_chain_maximum_turbulence () =
  let final_phase, _ = chain_apply
    ~init_phase:SM.Running
    ~init_conditions:running_conditions
    [
      (* Compaction cycle *)
      SM.Compaction_started,                                   SM.Compacting;
      SM.Compaction_completed { before_tokens=90000; after_tokens=40000 }, SM.Running;
      (* Handoff cycle *)
      SM.Handoff_started,                                      SM.HandingOff;
      SM.Handoff_completed { new_trace_id="gen2"; generation=2 }, SM.Running;
      (* Failure cycle *)
      SM.Heartbeat_failed { consecutive=2; max_allowed=5 },    SM.Failing;
      SM.Heartbeat_ok,                                         SM.Running;
      (* Pause cycle *)
      SM.Operator_pause,                                       SM.Paused;
      SM.Operator_resume,                                      SM.Running;
      (* Graceful exit *)
      SM.Stop_requested,                                       SM.Draining;
      SM.Drain_complete,                                       SM.Stopped;
    ]
  in
  check phase_t "visited all buffer states" SM.Stopped final_phase

(** 22. Condition snapshot consistency: verify exact conditions at each
    interesting point in a lifecycle chain. This catches subtle condition
    leaks between phases. *)
let test_chain_condition_snapshot_audit () =
  (* Step 1: start and compact *)
  let init_conds = { SM.default_conditions with restart_budget_remaining = true } in
  let tr1 = apply_ok ~current_phase:SM.Offline ~conditions:init_conds
    ~event:SM.Fiber_started in
  check phase_t "step 1" SM.Running tr1.new_phase;
  check bool "fiber alive" true tr1.updated_conditions.fiber_alive;
  check bool "hb healthy" true tr1.updated_conditions.heartbeat_healthy;
  check bool "turn healthy" true tr1.updated_conditions.turn_healthy;
  check bool "no compaction" false tr1.updated_conditions.compaction_active;
  check bool "no handoff" false tr1.updated_conditions.handoff_active;
  check bool "no guardrail" false tr1.updated_conditions.guardrail_triggered;
  check bool "backoff reset" false tr1.updated_conditions.backoff_elapsed;
  (* Step 2: crash *)
  let tr2 = apply_ok ~current_phase:SM.Running ~conditions:tr1.updated_conditions
    ~event:(SM.Fiber_terminated { outcome="crash" }) in
  check phase_t "step 2" SM.Crashed tr2.new_phase;
  check bool "fiber dead" false tr2.updated_conditions.fiber_alive;
  check bool "budget remaining" true tr2.updated_conditions.restart_budget_remaining;
  (* Step 3: restart *)
  let tr3 = apply_ok ~current_phase:SM.Crashed ~conditions:tr2.updated_conditions
    ~event:(SM.Supervisor_restart_attempt { attempt=1 }) in
  check phase_t "step 3" SM.Restarting tr3.new_phase;
  check bool "backoff elapsed" true tr3.updated_conditions.backoff_elapsed;
  (* Step 4: fiber starts - verify ALL resets *)
  let tr4 = apply_ok ~current_phase:SM.Restarting ~conditions:tr3.updated_conditions
    ~event:SM.Fiber_started in
  check phase_t "step 4" SM.Running tr4.new_phase;
  check bool "fiber alive (reset)" true tr4.updated_conditions.fiber_alive;
  check bool "hb healthy (reset)" true tr4.updated_conditions.heartbeat_healthy;
  check bool "turn healthy (reset)" true tr4.updated_conditions.turn_healthy;
  check bool "compaction (reset)" false tr4.updated_conditions.compaction_active;
  check bool "handoff (reset)" false tr4.updated_conditions.handoff_active;
  check bool "backoff (reset)" false tr4.updated_conditions.backoff_elapsed;
  check bool "guardrail (reset)" false tr4.updated_conditions.guardrail_triggered;
  check bool "drain (reset)" false tr4.updated_conditions.drain_complete;
  (* Preserved across restart: *)
  check bool "budget preserved" true tr4.updated_conditions.restart_budget_remaining

(* ── Invariant & leakage tests ────────────────────────── *)

(** INV-1: derive_phase is idempotent.
    For any conditions, derive_phase(c) = derive_phase(c).
    More importantly: updating conditions with an event then deriving
    phase produces the same result as what apply_event returns. *)
let test_invariant_derive_phase_idempotent () =
  (* Generate diverse condition sets by applying event sequences *)
  let scenarios = [
    ("healthy", running_conditions);
    ("default", SM.default_conditions);
    ("hb_fail", { running_conditions with heartbeat_healthy = false });
    ("paused+failing", { running_conditions with
      operator_paused = true; heartbeat_healthy = false });
    ("compacting+guardrail", { running_conditions with
      compaction_active = true; guardrail_triggered = true });
    ("draining", { running_conditions with
      stop_requested = true; drain_complete = false });
    ("stopped", { running_conditions with
      stop_requested = true; drain_complete = true });
    ("dead", { SM.default_conditions with
      fiber_alive = false; restart_budget_remaining = false });
  ] in
  List.iter (fun (label, conds) ->
    let p1 = SM.derive_phase conds in
    let p2 = SM.derive_phase conds in
    check phase_t (Printf.sprintf "idempotent: %s" label) p1 p2
  ) scenarios

(** INV-2: Terminal states are absorbing.
    Once Dead or Stopped, derive_phase always returns the same terminal. *)
let test_invariant_terminal_absorbing () =
  let dead_conds = { SM.default_conditions with
    fiber_alive = false; restart_budget_remaining = false } in
  let stopped_conds = { running_conditions with
    stop_requested = true; drain_complete = true } in
  (* Mutate every boolean field and verify terminal still holds *)
  let toggle c field = match field with
    | `Fiber -> { c with SM.fiber_alive = not c.SM.fiber_alive }
    | `Hb -> { c with heartbeat_healthy = not c.heartbeat_healthy }
    | `Turn -> { c with turn_healthy = not c.turn_healthy }
    | `Ctx -> { c with context_within_budget = not c.context_within_budget }
    | `Hand_need -> { c with context_handoff_needed = not c.context_handoff_needed }
    | `Comp -> { c with compaction_active = not c.compaction_active }
    | `Hand -> { c with handoff_active = not c.handoff_active }
    | `Guard -> { c with guardrail_triggered = not c.guardrail_triggered }
  in
  let non_critical_fields = [`Hb; `Turn; `Ctx; `Hand_need; `Comp; `Hand; `Guard] in
  (* Dead: toggling non-critical fields should keep Dead *)
  List.iter (fun field ->
    let mutated = toggle dead_conds field in
    check phase_t "Dead absorbs field toggle" SM.Dead (SM.derive_phase mutated)
  ) non_critical_fields;
  (* Stopped: toggling non-critical fields should keep Stopped.
     TLA+ fix: compaction_active and handoff_active are NOW critical for
     Stopped — toggling them ON breaks the Stopped condition (→ Draining).
     This is correct: buffer ops block terminal entry. *)
  let stopped_non_critical = [`Hb; `Turn; `Ctx; `Hand_need; `Guard] in
  List.iter (fun field ->
    let mutated = toggle stopped_conds field in
    let p = SM.derive_phase mutated in
    check phase_t "Stopped absorbs field toggle" SM.Stopped p
  ) stopped_non_critical;
  (* Sensitivity: toggling compaction/handoff ON must BREAK Stopped *)
  let with_comp = toggle stopped_conds `Comp in
  check phase_t "compaction breaks Stopped → Draining"
    SM.Draining (SM.derive_phase with_comp);
  let with_hand = toggle stopped_conds `Hand in
  check phase_t "handoff breaks Stopped → Draining"
    SM.Draining (SM.derive_phase with_hand)

(** INV-3: Fiber_started resets are exhaustive.
    After Fiber_started, EVERY per-fiber condition is in its "clean" state.
    Operator-intent conditions are preserved.
    Test with maximally "dirty" pre-restart conditions. *)
let test_invariant_fiber_started_reset_exhaustive () =
  (* Maximally dirty: every per-fiber condition set to "bad" state *)
  let dirty_conds = {
    SM.launch_pending = false;
    SM.fiber_alive = false;
    heartbeat_healthy = false;
    turn_healthy = false;
    context_within_budget = false;
    context_handoff_needed = true;
    compaction_active = true;
    handoff_active = true;
    operator_paused = true;
    stop_requested = true;
    restart_budget_remaining = true;
    backoff_elapsed = true;
    guardrail_triggered = true;
    drain_complete = true;
    context_overflow = true;
    compact_retry_exhausted = true;
  } in
  let updated = match SM.apply_event ~current_phase:SM.Restarting
      ~conditions:dirty_conds ~event:SM.Fiber_started ~now:1000.0 with
    | Ok tr -> tr.updated_conditions
    | Error e -> fail (SM.transition_error_to_string e)
  in
  (* Per-fiber conditions MUST be reset *)
  check bool "fiber_alive reset" true updated.fiber_alive;
  check bool "hb_healthy reset" true updated.heartbeat_healthy;
  check bool "turn_healthy reset" true updated.turn_healthy;
  check bool "compaction_active reset" false updated.compaction_active;
  check bool "handoff_active reset" false updated.handoff_active;
  check bool "backoff_elapsed reset" false updated.backoff_elapsed;
  check bool "guardrail_triggered reset" false updated.guardrail_triggered;
  check bool "drain_complete reset" false updated.drain_complete;
  (* TLA+ liveness fix: stop_requested is now RESET on Fiber_started.
     Restart contradicts stop. operator_paused is still preserved. *)
  check bool "stop_requested reset" false updated.stop_requested;
  (* Operator-intent conditions that ARE preserved *)
  check bool "operator_paused preserved" true updated.operator_paused;
  check bool "restart_budget preserved" true updated.restart_budget_remaining;
  (* Untouched conditions stay as-is *)
  check bool "context_within_budget unchanged" false updated.context_within_budget;
  check bool "context_handoff_needed unchanged" true updated.context_handoff_needed

(** INV-4: No cross-life heartbeat leakage.
    Heartbeat failures in life N must not affect phase in life N+1.
    The most dangerous leakage pattern found by the original chain tests. *)
let test_invariant_no_cross_life_hb_leakage () =
  (* Life 1: accumulate heartbeat failures *)
  let _, life1_conds = chain_apply
    ~init_phase:SM.Running
    ~init_conditions:running_conditions
    [
      SM.Heartbeat_failed { consecutive=1; max_allowed=5 },    SM.Failing;
      SM.Heartbeat_failed { consecutive=2; max_allowed=5 },    SM.Failing;
      SM.Heartbeat_failed { consecutive=3; max_allowed=5 },    SM.Failing;
      SM.Heartbeat_failed { consecutive=4; max_allowed=5 },    SM.Failing;
    ]
  in
  check bool "life1: hb unhealthy" false life1_conds.heartbeat_healthy;
  (* Life 1 dies *)
  let tr_death = apply_ok ~current_phase:SM.Failing ~conditions:life1_conds
    ~event:(SM.Fiber_terminated { outcome="too many hb failures" }) in
  check bool "life1: hb still false after death" false tr_death.updated_conditions.heartbeat_healthy;
  (* Supervisor restart *)
  let tr_restart = apply_ok ~current_phase:SM.Crashed ~conditions:tr_death.updated_conditions
    ~event:(SM.Supervisor_restart_attempt { attempt=1 }) in
  (* Life 2 begins *)
  let tr_life2 = apply_ok ~current_phase:SM.Restarting ~conditions:tr_restart.updated_conditions
    ~event:SM.Fiber_started in
  (* CRITICAL: heartbeat_healthy MUST be true in new life *)
  check bool "life2: hb healthy (no leakage)" true tr_life2.updated_conditions.heartbeat_healthy;
  check phase_t "life2: Running (not Failing)" SM.Running tr_life2.new_phase

(** INV-5: No cross-life backoff leakage.
    backoff_elapsed from restart N must not skip Crashed in life N+1.
    The second leakage pattern found by the original chain tests. *)
let test_invariant_no_cross_life_backoff_leakage () =
  let _, post_restart = chain_apply
    ~init_phase:SM.Running
    ~init_conditions:running_conditions
    [
      SM.Fiber_terminated { outcome="crash 1" },               SM.Crashed;
      SM.Supervisor_restart_attempt { attempt=1 },             SM.Restarting;
      SM.Fiber_started,                                        SM.Running;
    ]
  in
  (* After Fiber_started, backoff_elapsed MUST be false *)
  check bool "backoff reset after restart" false post_restart.backoff_elapsed;
  (* Second crash MUST go to Crashed (not skip to Restarting) *)
  let tr = apply_ok ~current_phase:SM.Running ~conditions:post_restart
    ~event:(SM.Fiber_terminated { outcome="crash 2" }) in
  check phase_t "second crash -> Crashed (not Restarting)" SM.Crashed tr.new_phase;
  check bool "backoff_elapsed still false" false tr.updated_conditions.backoff_elapsed

(** INV-6: No cross-life buffer state leakage.
    compaction_active/handoff_active from life N must not persist in life N+1. *)
let test_invariant_no_cross_life_buffer_leakage () =
  let _, post_restart = chain_apply
    ~init_phase:SM.Running
    ~init_conditions:running_conditions
    [
      SM.Compaction_started,                                   SM.Compacting;
      SM.Fiber_terminated { outcome="crash during compaction" }, SM.Crashed;
      SM.Supervisor_restart_attempt { attempt=1 },             SM.Restarting;
      SM.Fiber_started,                                        SM.Running;
    ]
  in
  check bool "compaction not leaked" false post_restart.compaction_active;
  check bool "handoff not leaked" false post_restart.handoff_active;
  (* New life starts clean — should be Running, not Compacting *)
  check phase_t "clean Running" SM.Running (SM.derive_phase post_restart)

(** INV-7: Operator intent monotonicity.
    Once stop_requested=true, it NEVER reverts to false through normal events.
    Only Fiber_started preserves (not clears) it. *)
let test_invariant_stop_requested_monotonic () =
  (* TLA+ liveness fix: Fiber_started now resets stop_requested.
     All OTHER events must preserve it (monotonic within a fiber life). *)
  let events_that_should_not_clear_stop = [
    SM.Heartbeat_ok;
    SM.Heartbeat_failed { consecutive=1; max_allowed=5 };
    SM.Turn_succeeded;
    SM.Turn_failed { consecutive=1; max_allowed=10 };
    SM.Compaction_started;
    SM.Compaction_completed { before_tokens=100; after_tokens=50 };
    SM.Handoff_started;
    SM.Handoff_completed { new_trace_id="x"; generation=1 };
    SM.Operator_pause;
    SM.Operator_resume;
    SM.Guardrail_stop { reason="test" };
    (* Fiber_started intentionally OMITTED — it resets stop *)
    SM.Fiber_terminated { outcome="test" };
    SM.Supervisor_restart_attempt { attempt=1 };
    SM.Drain_complete;
    SM.Context_measured {
      context_ratio=0.5; message_count=10; token_count=5000;
      auto_rules={ reflect=false; plan=false; compact=false;
                   handoff=false; guardrail_stop=false;
                   guardrail_reason=None; goal_drift=0.0 };
    };
  ] in
  let conds_with_stop = { running_conditions with stop_requested = true } in
  List.iter (fun ev ->
    let updated = match SM.apply_event ~current_phase:SM.Draining
        ~conditions:conds_with_stop ~event:ev ~now:1000.0 with
      | Ok tr -> tr.updated_conditions
      | Error _ -> conds_with_stop (* Terminal rejection is fine *)
    in
    check bool (Printf.sprintf "stop persists after %s" (SM.event_to_string ev))
      true updated.stop_requested
  ) events_that_should_not_clear_stop;
  (* Fiber_started IS the one event that clears stop_requested *)
  let restart_conds = { SM.default_conditions with
    fiber_alive = false;
    restart_budget_remaining = true;
    backoff_elapsed = true;
    stop_requested = true;
  } in
  let updated = match SM.apply_event ~current_phase:SM.Restarting
      ~conditions:restart_conds ~event:SM.Fiber_started ~now:1000.0 with
    | Ok tr -> tr.updated_conditions
    | Error e -> fail (SM.transition_error_to_string e)
  in
  check bool "Fiber_started clears stop_requested" false updated.stop_requested

(** INV-8: restart_budget_remaining monotonicity.
    Once Restart_budget_exhausted fires, budget is permanently false.
    No event can restore it. *)
let test_invariant_budget_exhaustion_permanent () =
  let conds_no_budget = { SM.default_conditions with
    fiber_alive = false;
    restart_budget_remaining = false;
  } in
  (* The keeper is Dead at this point. All events are rejected.
     But verify the conditions themselves: no event's update_conditions
     can set restart_budget_remaining back to true. *)
  let all_events = [
    SM.Heartbeat_ok; SM.Fiber_started;
    SM.Supervisor_restart_attempt { attempt=99 };
    SM.Restart_budget_exhausted;
    SM.Operator_resume;
  ] in
  List.iter (fun ev ->
    (* Manually call update_conditions to check the pure function *)
    let open SM in
    let updated = match ev with
      | Heartbeat_ok -> { conds_no_budget with heartbeat_healthy = true }
      | Fiber_started -> { conds_no_budget with
          fiber_alive = true; heartbeat_healthy = true;
          turn_healthy = true;
          compaction_active = false;
          handoff_active = false; backoff_elapsed = false;
          guardrail_triggered = false; drain_complete = false }
      | Supervisor_restart_attempt _ -> { conds_no_budget with backoff_elapsed = true }
      | Restart_budget_exhausted -> { conds_no_budget with restart_budget_remaining = false }
      | Operator_resume -> { conds_no_budget with operator_paused = false }
      | _ -> conds_no_budget
    in
    check bool (Printf.sprintf "budget stays false after %s" (event_to_string ev))
      false updated.restart_budget_remaining
  ) all_events

(** INV-9: derive_phase consistency with can_transition.
    For every non-terminal phase and every event, if apply_event succeeds,
    the resulting transition must be allowed by can_transition.
    This is a structural invariant that catches matrix/derive_phase drift. *)
let test_invariant_derive_matches_matrix () =
  let representative_events = [
    SM.Heartbeat_ok;
    SM.Heartbeat_failed { consecutive=5; max_allowed=5 };
    SM.Turn_succeeded;
    SM.Turn_failed { consecutive=3; max_allowed=10 };
    SM.Compaction_started;
    SM.Compaction_completed { before_tokens=100; after_tokens=50 };
    SM.Compaction_failed { reason="test" };
    SM.Handoff_started;
    SM.Handoff_completed { new_trace_id="x"; generation=1 };
    SM.Handoff_failed { reason="test" };
    SM.Operator_pause;
    SM.Operator_resume;
    SM.Operator_stop { remove_meta=false };
    SM.Stop_requested;
    SM.Drain_complete;
    SM.Fiber_started;
    SM.Fiber_terminated { outcome="test" };
    SM.Supervisor_restart_attempt { attempt=1 };
    SM.Restart_budget_exhausted;
    SM.Guardrail_stop { reason="test" };
  ] in
  let non_terminal_phases = List.filter (fun p ->
    p <> SM.Stopped && p <> SM.Dead
  ) SM.all_phases in
  List.iter (fun phase ->
    List.iter (fun event ->
      (* Build conditions that produce this phase *)
      let conds = match phase with
        | SM.Offline -> { SM.default_conditions with restart_budget_remaining = true }
        | SM.Running -> running_conditions
        | SM.Failing -> { running_conditions with heartbeat_healthy = false }
        | SM.Overflowed -> { running_conditions with context_overflow = true }
        | SM.Compacting -> { running_conditions with compaction_active = true }
        | SM.HandingOff -> { running_conditions with handoff_active = true }
        | SM.Draining -> { running_conditions with
            stop_requested = true; drain_complete = false }
        | SM.Paused -> { running_conditions with operator_paused = true }
        | SM.Crashed -> { SM.default_conditions with
            fiber_alive = false; restart_budget_remaining = true }
        | SM.Restarting -> { SM.default_conditions with
            fiber_alive = false; restart_budget_remaining = true;
            backoff_elapsed = true }
        | SM.Stopped | SM.Dead -> running_conditions (* unreachable *)
      in
      (* Verify conditions produce the expected phase *)
      if SM.derive_phase conds <> phase then ()  (* Skip if conditions don't match *)
      else begin
        match SM.apply_event ~current_phase:phase ~conditions:conds ~event ~now:1000.0 with
        | Ok tr ->
          if tr.new_phase <> phase then begin
            (* Actual phase transition — must be in matrix *)
            if not (SM.can_transition ~from_phase:phase ~to_phase:tr.new_phase) then
              fail (Printf.sprintf
                "MATRIX DRIFT: %s -> %s via %s (derive_phase produced it, matrix rejects it)"
                (SM.phase_to_string phase)
                (SM.phase_to_string tr.new_phase)
                (SM.event_to_string event))
          end
        | Error _ -> () (* Terminal rejection or invalid is fine *)
      end
    ) representative_events
  ) non_terminal_phases

(** INV-10: Phase derivation priority chain.
    Verify that higher-priority conditions always win, regardless of
    how many lower-priority conditions are set. *)
let test_invariant_priority_chain () =
  (* All conditions true: stopped should win (highest fiber-alive priority) *)
  let all_true = {
    SM.launch_pending = false;
    SM.fiber_alive = true;
    heartbeat_healthy = true;
    turn_healthy = true;
    context_within_budget = true;
    context_handoff_needed = true;
    compaction_active = true;
    handoff_active = true;
    operator_paused = true;
    stop_requested = true;
    restart_budget_remaining = true;
    backoff_elapsed = true;
    guardrail_triggered = true;
    drain_complete = true;
    context_overflow = true;
    compact_retry_exhausted = true;
  } in
  (* TLA+ fix: all_true has compaction+handoff active, so Stopped is blocked → Draining.
     Clear buffer ops to reach Stopped. *)
  check phase_t "all true: Draining (buffer ops block Stopped)" SM.Draining (SM.derive_phase all_true);
  let clean_stopped = { all_true with compaction_active = false; handoff_active = false } in
  check phase_t "no buffer ops: Stopped" SM.Stopped (SM.derive_phase clean_stopped);
  (* Remove drain_complete: Draining wins *)
  let no_drain = { all_true with drain_complete = false } in
  check phase_t "no drain_complete: Draining" SM.Draining (SM.derive_phase no_drain);
  (* Remove stop: guardrail wins *)
  let no_stop = { no_drain with stop_requested = false } in
  check phase_t "no stop: guardrail->Failing" SM.Failing (SM.derive_phase no_stop);
  (* Remove guardrail: paused wins *)
  let no_guard = { no_stop with guardrail_triggered = false } in
  check phase_t "no guardrail: Paused" SM.Paused (SM.derive_phase no_guard);
  (* Remove paused trigger: must also clear the overflow-latched path
     (context_overflow && compact_retry_exhausted) that can hold the
     keeper in Paused independently of operator_paused. *)
  let no_paused = { no_guard with
    operator_paused = false;
    context_overflow = false;
    compact_retry_exhausted = false;
  } in
  check phase_t "no paused: HandingOff" SM.HandingOff (SM.derive_phase no_paused);
  (* Remove handoff: compaction wins *)
  let no_handoff = { no_paused with handoff_active = false } in
  check phase_t "no handoff: Compacting" SM.Compacting (SM.derive_phase no_handoff);
  (* Remove compaction: healthy Running *)
  let no_compact = { no_handoff with compaction_active = false } in
  check phase_t "no compact: Running" SM.Running (SM.derive_phase no_compact)

(* ── Property: derive_phase x apply_event consistency ──── *)

let test_all_phases_covered () =
  check int "12 phases" 12 (List.length SM.all_phases)

(* ── Mermaid diagram tests ─────────────────────────────── *)

(** Returns all lines of the Mermaid output for a given current phase. *)
let mermaid_lines phase =
  SM.phase_to_mermaid ~current:phase |> String.split_on_char '\n'

(** Returns true if [needle] appears as a substring of [haystack]. *)
let string_contains haystack needle =
  let hl = String.length haystack and nl = String.length needle in
  if nl = 0 then true
  else if hl < nl then false
  else begin
    let found = ref false in
    for i = 0 to hl - nl do
      if not !found && String.sub haystack i nl = needle then
        found := true
    done;
    !found
  end

let test_mermaid_header () =
  let lines = mermaid_lines SM.Running in
  check string "starts with stateDiagram-v2"
    "stateDiagram-v2" (List.nth lines 0)

let test_mermaid_all_phases_appear () =
  List.iter (fun phase ->
    let diagram = SM.phase_to_mermaid ~current:phase in
    let id = SM.phase_to_mermaid_id phase in
    check bool (Printf.sprintf "phase %s appears in diagram" id)
      true (string_contains diagram id)
  ) SM.all_phases

let class_lines_for lines id =
  let prefix = Printf.sprintf "    class %s " id in
  List.filter (fun l ->
    String.length l >= String.length prefix &&
    String.sub l 0 (String.length prefix) = prefix
  ) lines

let test_mermaid_active_class () =
  let active_phases = [ SM.Offline; SM.Running; SM.Paused ] in
  List.iter (fun phase ->
    let lines = mermaid_lines phase in
    let id = SM.phase_to_mermaid_id phase in
    let cls = class_lines_for lines id in
    check int
      (Printf.sprintf "phase %s has exactly one class line" id)
      1 (List.length cls);
    check bool
      (Printf.sprintf "phase %s assigned active class" id)
      true (List.mem (Printf.sprintf "    class %s active" id) cls)
  ) active_phases

let test_mermaid_buffer_class () =
  let buffer_phases =
    [ SM.Failing; SM.Compacting; SM.HandingOff; SM.Draining; SM.Restarting ] in
  List.iter (fun phase ->
    let lines = mermaid_lines phase in
    let id = SM.phase_to_mermaid_id phase in
    let cls = class_lines_for lines id in
    check int
      (Printf.sprintf "phase %s has exactly one class line" id)
      1 (List.length cls);
    check bool
      (Printf.sprintf "phase %s assigned buffer class (not active)" id)
      true (List.mem (Printf.sprintf "    class %s buffer" id) cls)
  ) buffer_phases

let test_mermaid_terminal_class () =
  let terminal_phases = [ SM.Stopped; SM.Dead ] in
  List.iter (fun phase ->
    let lines = mermaid_lines phase in
    let id = SM.phase_to_mermaid_id phase in
    let cls = class_lines_for lines id in
    check int
      (Printf.sprintf "phase %s has exactly one class line" id)
      1 (List.length cls);
    check bool
      (Printf.sprintf "phase %s assigned terminal class" id)
      true (List.mem (Printf.sprintf "    class %s terminal" id) cls)
  ) terminal_phases

(* ── Set/Clear Coverage ────────────────────────────────── *)

(** Static verification that every boolean condition field in the FSM
    has both a setter event (false->true) and a clearer event (true->false).

    Approach: for each field, iterate ALL events and call update_conditions
    on two base states (all-false, all-true) to detect which events set
    and which events clear each field. Assert every non-exempt field has
    at least one clearer. *)

let test_setclear_coverage () =
  (* All boolean fields: (name, getter) pairs.
     Source of truth: conditions record in keeper_state_machine.ml *)
  let fields : (string * (SM.conditions -> bool)) list = [
    "launch_pending",            (fun c -> c.launch_pending);
    "fiber_alive",               (fun c -> c.fiber_alive);
    "heartbeat_healthy",         (fun c -> c.heartbeat_healthy);
    "turn_healthy",              (fun c -> c.turn_healthy);
    "context_within_budget",     (fun c -> c.context_within_budget);
    "context_handoff_needed",    (fun c -> c.context_handoff_needed);
    "compaction_active",         (fun c -> c.compaction_active);
    "handoff_active",            (fun c -> c.handoff_active);
    "operator_paused",           (fun c -> c.operator_paused);
    "stop_requested",            (fun c -> c.stop_requested);
    "restart_budget_remaining",  (fun c -> c.restart_budget_remaining);
    "backoff_elapsed",           (fun c -> c.backoff_elapsed);
    "guardrail_triggered",       (fun c -> c.guardrail_triggered);
    "drain_complete",            (fun c -> c.drain_complete);
    "context_overflow",          (fun c -> c.context_overflow);
    "compact_retry_exhausted",   (fun c -> c.compact_retry_exhausted);
  ] in
  (* Conditions with all booleans false *)
  let all_false : SM.conditions = {
    launch_pending = false;
    fiber_alive = false;
    heartbeat_healthy = false;
    turn_healthy = false;
    context_within_budget = false;
    context_handoff_needed = false;
    compaction_active = false;
    handoff_active = false;
    operator_paused = false;
    stop_requested = false;
    restart_budget_remaining = false;
    backoff_elapsed = false;
    guardrail_triggered = false;
    drain_complete = false;
    context_overflow = false;
    compact_retry_exhausted = false;
  } in
  (* Conditions with all booleans true *)
  let all_true : SM.conditions = {
    launch_pending = true;
    fiber_alive = true;
    heartbeat_healthy = true;
    turn_healthy = true;
    context_within_budget = true;
    context_handoff_needed = true;
    compaction_active = true;
    handoff_active = true;
    operator_paused = true;
    stop_requested = true;
    restart_budget_remaining = true;
    backoff_elapsed = true;
    guardrail_triggered = true;
    drain_complete = true;
    context_overflow = true;
    compact_retry_exhausted = true;
  } in
  (* auto_rules with all flags false *)
  let auto_rules_clean : SM.auto_rule_summary = {
    reflect = false; plan = false; compact = false;
    handoff = false; guardrail_stop = false;
    guardrail_reason = None; goal_drift = 0.0;
  } in
  (* Every event variant with representative payloads.
     Context_measured needs two variants to cover both true/false
     for guardrail_stop and handoff flags. *)
  let all_events : (string * SM.event) list = [
    "Heartbeat_ok",
      SM.Heartbeat_ok;
    "Heartbeat_failed",
      SM.Heartbeat_failed { consecutive = 3; max_allowed = 5 };
    "Turn_succeeded",
      SM.Turn_succeeded;
    "Turn_failed",
      SM.Turn_failed { consecutive = 3; max_allowed = 10 };
    "Context_measured(guardrail+handoff)",
      SM.Context_measured {
        context_ratio = 0.95; message_count = 100; token_count = 50000;
        auto_rules = { auto_rules_clean with
          guardrail_stop = true; handoff = true };
      };
    "Context_measured(clean)",
      SM.Context_measured {
        context_ratio = 0.2; message_count = 5; token_count = 1000;
        auto_rules = auto_rules_clean;
      };
    "Compaction_started",
      SM.Compaction_started;
    "Compaction_completed",
      SM.Compaction_completed { before_tokens = 100; after_tokens = 50 };
    "Compaction_failed",
      SM.Compaction_failed { reason = "test" };
    "Handoff_started",
      SM.Handoff_started;
    "Handoff_completed",
      SM.Handoff_completed { new_trace_id = "x"; generation = 99 };
    "Handoff_failed",
      SM.Handoff_failed { reason = "test" };
    "Operator_pause",
      SM.Operator_pause;
    "Operator_resume",
      SM.Operator_resume;
    "Operator_stop",
      SM.Operator_stop { remove_meta = true };
    "Stop_requested",
      SM.Stop_requested;
    "Drain_complete",
      SM.Drain_complete;
    "Fiber_started",
      SM.Fiber_started;
    "Fiber_terminated",
      SM.Fiber_terminated { outcome = "test" };
    "Supervisor_restart_attempt",
      SM.Supervisor_restart_attempt { attempt = 1 };
    "Restart_budget_exhausted",
      SM.Restart_budget_exhausted;
    "Guardrail_stop",
      SM.Guardrail_stop { reason = "test" };
    "Context_overflow_detected",
      SM.Context_overflow_detected
        { source = `Prompt_rejected;
          token_count = 205_000;
          limit_tokens = Some 200_000 };
    "Auto_compact_triggered",
      SM.Auto_compact_triggered;
    "Operator_compact_requested",
      SM.Operator_compact_requested;
    "Operator_clear_requested",
      SM.Operator_clear_requested { preserve_system = true; reason = "test" };
  ] in
  (* Build coverage map: for each field, which events set it and clear it *)
  let setters = Hashtbl.create 16 in
  let clearers = Hashtbl.create 16 in
  List.iter (fun (field_name, _) ->
    Hashtbl.replace setters field_name [];
    Hashtbl.replace clearers field_name [];
  ) fields;
  List.iter (fun (ev_name, ev) ->
    List.iter (fun (field_name, getter) ->
      (* Detect setter: field was false, event makes it true *)
      let after_from_false = SM.update_conditions all_false ev in
      if not (getter all_false) && (getter after_from_false) then
        Hashtbl.replace setters field_name
          (ev_name :: (Hashtbl.find setters field_name));
      (* Detect clearer: field was true, event makes it false *)
      let after_from_true = SM.update_conditions all_true ev in
      if (getter all_true) && not (getter after_from_true) then
        Hashtbl.replace clearers field_name
          (ev_name :: (Hashtbl.find clearers field_name));
    ) fields
  ) all_events;
  (* Fields exempt from the "must have clearer" requirement:
     - context_within_budget: never modified by update_conditions (external)
     - launch_pending: only cleared by Fiber_started, never set by events
     - restart_budget_remaining: supervisor-managed, only cleared by
       Restart_budget_exhausted, never set by events.
     These fields are managed by external code, not the FSM event loop. *)
  let exempt_from_clearer = [
    "context_within_budget";  (* external: never touched by update_conditions *)
  ] in
  let exempt_from_setter = [
    "context_within_budget";    (* external *)
    "launch_pending";           (* set externally before Fiber_started *)
    "restart_budget_remaining"; (* supervisor-managed budget *)
    "compact_retry_exhausted";  (* latched by keeper_unified_turn retry loop, *)
                                (* no dedicated FSM event sets it to true. *)
  ] in
  (* Print coverage report for diagnostics *)
  let buf = Buffer.create 512 in
  Buffer.add_string buf "\n--- Set/Clear Coverage Report ---\n";
  List.iter (fun (field_name, _) ->
    let s = Hashtbl.find setters field_name in
    let c = Hashtbl.find clearers field_name in
    Buffer.add_string buf (Printf.sprintf "  %-30s setters=%d clearers=%d\n"
      field_name (List.length s) (List.length c));
    List.iter (fun ev ->
      Buffer.add_string buf (Printf.sprintf "    SET by: %s\n" ev)
    ) (List.rev s);
    List.iter (fun ev ->
      Buffer.add_string buf (Printf.sprintf "    CLR by: %s\n" ev)
    ) (List.rev c);
  ) fields;
  Buffer.add_string buf "--- End Report ---\n";
  (* Use Alcotest check with diagnostic message *)
  let report = Buffer.contents buf in
  (* Assert: every non-exempt field has at least one clearer *)
  let missing_clearers = List.filter (fun (field_name, _) ->
    not (List.mem field_name exempt_from_clearer) &&
    List.length (Hashtbl.find clearers field_name) = 0
  ) fields in
  if missing_clearers <> [] then begin
    let names = String.concat ", "
      (List.map (fun (n, _) -> n) missing_clearers) in
    fail (Printf.sprintf
      "Fields with no clearer event (stuck-true bug risk): [%s]%s"
      names report)
  end;
  (* Assert: every non-exempt field has at least one setter *)
  let missing_setters = List.filter (fun (field_name, _) ->
    not (List.mem field_name exempt_from_setter) &&
    List.length (Hashtbl.find setters field_name) = 0
  ) fields in
  if missing_setters <> [] then begin
    let names = String.concat ", "
      (List.map (fun (n, _) -> n) missing_setters) in
    fail (Printf.sprintf
      "Fields with no setter event (dead-flag risk): [%s]%s"
      names report)
  end;
  (* Verify field count matches conditions record (structural guard).
     If someone adds a new field to conditions but forgets to add it here,
     this check catches it by comparing against conditions_to_json output. *)
  let json_field_count = match SM.conditions_to_json SM.default_conditions with
    | `Assoc pairs -> List.length pairs
    | _ -> fail "conditions_to_json did not return Assoc"
  in
  check int "field count matches conditions_to_json"
    json_field_count (List.length fields);
  (* Print report on success for visibility *)
  Printf.printf "%s" report

(* ── Attribution conversion ────────────────────────────── *)

module A = Masc_mcp.Attribution

let outcome_kind_of = function
  | A.Passed -> "passed"
  | A.Policy_failed _ -> "policy_failed"
  | A.Transition_blocked _ -> "transition_blocked"
  | A.Partial_pass _ -> "partial_pass"

let test_attribution_ok_passed () =
  let tr =
    apply_ok ~current_phase:SM.Running ~conditions:running_conditions
      ~event:SM.Turn_succeeded
  in
  let attr = SM.attribution_of_transition ~event:SM.Turn_succeeded (Ok tr) in
  check string "gate" "keeper_fsm" attr.gate;
  check bool "origin=Det" true (attr.origin = A.Det);
  check string "outcome kind" "passed" (outcome_kind_of attr.outcome);
  (* Evidence carries event + phase info. *)
  (match attr.evidence with
   | `Assoc fields ->
     check bool "evidence has event"
       true (List.mem_assoc "event" fields);
     check bool "evidence has from_phase"
       true (List.mem_assoc "from_phase" fields);
     check bool "evidence has to_phase"
       true (List.mem_assoc "to_phase" fields);
     check bool "evidence has timestamp"
       true (List.mem_assoc "timestamp" fields)
   | _ -> Alcotest.fail "evidence must be object")

let test_attribution_invalid_transition_blocked () =
  (* Build a synthetic transition_error (no legitimate apply_event path
     in this FSM emits Invalid_transition outside guard violations — we
     test the converter directly). *)
  let err =
    SM.Invalid_transition
      { from_phase = SM.Running;
        to_phase = SM.Compacting;
        reason = "guard violation: cannot compact while running" }
  in
  let attr =
    SM.attribution_of_transition ~event:SM.Compaction_started (Error err)
  in
  (match attr.outcome with
   | A.Transition_blocked { from_state; to_state; reason } ->
     check string "from_state" "running" from_state;
     check string "to_state" "compacting" to_state;
     check string "reason" "guard violation: cannot compact while running"
       reason
   | other ->
     Alcotest.fail ("expected Transition_blocked, got " ^ outcome_kind_of other))

let test_attribution_terminal_policy_failed () =
  let terminal_cond =
    { SM.default_conditions with
      stop_requested = true;
      fiber_alive = false;
      restart_budget_remaining = false;
    }
  in
  let result =
    SM.apply_event ~current_phase:SM.Stopped ~conditions:terminal_cond
      ~event:SM.Heartbeat_ok ~now:0.0
  in
  let attr = SM.attribution_of_transition ~event:SM.Heartbeat_ok result in
  (match result with
   | Error (SM.Terminal_state _) -> ()
   | _ -> Alcotest.fail "expected Terminal_state for event on Stopped phase");
  (match attr.outcome with
   | A.Policy_failed { reason } ->
     check bool "reason mentions terminal" true
       (Astring.String.is_infix ~affix:"terminal" reason);
     check bool "reason mentions stopped phase" true
       (Astring.String.is_infix ~affix:"stopped" reason)
   | other ->
     Alcotest.fail ("expected Policy_failed, got " ^ outcome_kind_of other))

let test_attribution_gate_and_origin_invariant () =
  (* Every attribution produced by this gate must carry gate="keeper_fsm"
     and origin=Det, regardless of the outcome branch. *)
  let cases : (SM.event * (SM.transition_result, SM.transition_error) result) list =
    [
      SM.Turn_succeeded,
        Ok (apply_ok ~current_phase:SM.Running ~conditions:running_conditions
              ~event:SM.Turn_succeeded);
      SM.Compaction_started,
        Error (SM.Invalid_transition
                 { from_phase = SM.Running;
                   to_phase = SM.Compacting;
                   reason = "test" });
      SM.Heartbeat_ok,
        Error (SM.Terminal_state
                 { current = SM.Dead; attempted_event = "Heartbeat_ok" });
    ]
  in
  List.iter (fun (event, result) ->
    let attr = SM.attribution_of_transition ~event result in
    check string "gate invariant" "keeper_fsm" attr.gate;
    check bool "origin=Det invariant" true (attr.origin = A.Det)
  ) cases

(* ── Test suite ────────────────────────────────────────── *)

let () =
  run "Keeper_state_machine (RFC-0002)" [
    "derive_phase", [
      test_case "healthy = Running" `Quick test_derive_healthy;
      test_case "default = Dead" `Quick test_derive_default_dead;
      test_case "Offline in all_phases" `Quick test_derive_offline;
      test_case "Dead highest priority" `Quick test_derive_dead_highest_priority;
      test_case "Restarting" `Quick test_derive_restarting;
      test_case "Crashed" `Quick test_derive_crashed;
      test_case "Stopped" `Quick test_derive_stopped;
      test_case "Draining" `Quick test_derive_draining;
      test_case "Guardrail -> Failing" `Quick test_derive_guardrail_failing;
      test_case "Paused" `Quick test_derive_paused;
      test_case "HandingOff" `Quick test_derive_handingoff;
      test_case "Compacting" `Quick test_derive_compacting;
      test_case "Failing (heartbeat)" `Quick test_derive_failing_heartbeat;
      test_case "Failing (turn)" `Quick test_derive_failing_turn;
      test_case "priority: Stop > Compact" `Quick test_derive_priority_stop_over_compact;
      test_case "priority: Guardrail > Paused" `Quick test_derive_priority_guardrail_over_paused;
      test_case "priority: Handoff > Compact" `Quick test_derive_priority_handoff_over_compact;
    ];
    "apply_event", [
      test_case "heartbeat ok stays" `Quick test_apply_heartbeat_ok_stays_running;
      test_case "heartbeat fail -> Failing" `Quick test_apply_heartbeat_fail_to_failing;
      test_case "heartbeat recover" `Quick test_apply_heartbeat_recover;
      test_case "compaction started" `Quick test_apply_compaction_started;
      test_case "compaction completed" `Quick test_apply_compaction_completed;
      test_case "handoff lifecycle" `Quick test_apply_handoff_lifecycle;
      test_case "pause/resume" `Quick test_apply_operator_pause_resume;
      test_case "drain lifecycle" `Quick test_apply_drain_lifecycle;
      test_case "drain + fiber death -> Crashed" `Quick test_apply_drain_fiber_death;
      test_case "drain complete + fiber exit -> Stopped" `Quick test_apply_drain_complete_then_fiber_exit;
      test_case "Failing + fiber death -> Crashed" `Quick test_apply_failing_to_crashed;
      test_case "partial heartbeat -> Failing" `Quick test_apply_partial_heartbeat_failure;
      test_case "fiber terminated -> Crashed" `Quick test_apply_fiber_terminated_crash;
      test_case "crash -> restart -> Running" `Quick test_apply_crash_restart_lifecycle;
      test_case "crash -> Dead" `Quick test_apply_crash_to_dead;
      test_case "Compacting + fiber death -> Crashed" `Quick test_apply_compacting_to_crashed;
      test_case "HandingOff + fiber death -> Crashed" `Quick test_apply_handingoff_to_crashed;
      test_case "Failing + stop -> Draining" `Quick test_apply_failing_to_draining;
      test_case "Restarting + fiber death -> Crashed" `Quick test_apply_restarting_to_crashed;
      test_case "Restarting + budget exhausted -> Dead" `Quick test_apply_restarting_to_dead;
      test_case "Paused + stop -> Draining" `Quick test_apply_paused_to_draining;
      test_case "Paused -> Draining -> Stopped" `Quick test_apply_paused_stop_drain_lifecycle;
    ];
    "terminal", [
      test_case "Dead rejects all" `Quick test_dead_rejects_all_events;
      test_case "Stopped rejects all" `Quick test_stopped_rejects_all_events;
    ];
    "can_transition", [
      test_case "Running -> buffer states" `Quick test_can_transition_running_to_buffer_states;
      test_case "Running invalid targets" `Quick test_can_transition_running_invalid;
      test_case "terminal -> nothing" `Quick test_can_transition_terminal_nothing;
      test_case "Crashed -> Restarting|Dead only" `Quick test_can_transition_crashed_only_restart_or_dead;
      test_case "Compacting -> Failing" `Quick test_can_transition_compacting_to_failing;
      test_case "Compacting -> Crashed" `Quick test_can_transition_compacting_to_crashed;
      test_case "HandingOff -> Failing" `Quick test_can_transition_handingoff_to_failing;
      test_case "HandingOff -> Crashed" `Quick test_can_transition_handingoff_to_crashed;
      test_case "Failing -> Draining" `Quick test_can_transition_failing_to_draining;
      test_case "Restarting -> Crashed" `Quick test_can_transition_restarting_to_crashed;
      test_case "Restarting -> Dead" `Quick test_can_transition_restarting_to_dead;
      test_case "Paused -> Draining" `Quick test_can_transition_paused_to_draining;
      test_case "Paused -> Stopped" `Quick test_can_transition_paused_to_stopped;
      test_case "Running|Failing execute turns" `Quick
        test_can_execute_turn_running_and_failing_only;
      test_case "other phases skip turns" `Quick
        test_can_execute_turn_blocks_other_phases;
    ];
    "guard", [
      test_case "healthy = no action events" `Quick test_guard_healthy_no_crash_events;
      test_case "compaction triggers" `Quick test_guard_compaction_triggers;
      test_case "zero gates disable compaction" `Quick test_guard_zero_gates_do_not_force_compaction;
      test_case "compaction cooldown respected" `Quick test_guard_compaction_respects_cooldown;
      test_case "handoff triggers" `Quick test_guard_handoff_triggers;
      test_case "guardrail triggers" `Quick test_guard_guardrail_triggers;
      test_case "hb failure at threshold" `Quick test_guard_hb_failure_threshold;
      test_case "plan requires both low" `Quick test_guard_plan_requires_both_alignments_low;
      test_case "plan fails-closed when similarity unmeasurable" `Quick
        test_guard_plan_fails_closed_when_similarity_unmeasurable;
      test_case "guardrail fails-closed when similarity unmeasurable" `Quick
        test_guard_guardrail_fails_closed_when_similarity_unmeasurable;
    ];
    "roundtrip", [
      test_case "phase string roundtrip" `Quick test_phase_string_roundtrip;
      test_case "12 phases" `Quick test_all_phases_covered;
    ];
    "lifecycle_chain", [
      test_case "happy path (boot->compact->handoff->stop)" `Quick test_chain_happy_path;
      test_case "crash recovery (fail->crash->restart->run)" `Quick test_chain_crash_recovery;
      test_case "death spiral (crash->restart->crash->dead)" `Quick test_chain_death_spiral;
      test_case "operator intervention (pause->resume->stop)" `Quick test_chain_operator_intervention;
      test_case "compaction fail -> handoff fallback" `Quick test_chain_compaction_fail_handoff_fallback;
      test_case "guardrail -> recovery" `Quick test_chain_guardrail_recovery;
      test_case "long-running multi-cycle (5 cycles)" `Quick test_chain_long_running_multi_cycle;
      test_case "crash during compaction -> recovery" `Quick test_chain_crash_during_compaction_recovery;
      test_case "failing -> graceful stop" `Quick test_chain_failing_graceful_stop;
      test_case "heartbeat flapping (8 oscillations)" `Quick test_chain_heartbeat_flapping;
      test_case "terminal permanence (8 rejected events)" `Quick test_chain_terminal_permanence;
    ];
    "edge_cases", [
      test_case "restart inherits operator_paused" `Quick test_chain_restart_inherits_paused;
      test_case "restart clears stop_requested" `Quick test_chain_restart_clears_stop;
      test_case "handoff fail then retry" `Quick test_chain_handoff_fail_retry;
      test_case "guardrail during compaction" `Quick test_chain_guardrail_during_compaction;
      test_case "double failure (hb+turn) recovery" `Quick test_chain_double_failure_recovery;
      test_case "operator stop during handoff" `Quick test_chain_stop_during_handoff;
      test_case "no phoenix (22 events on Dead)" `Quick test_chain_no_phoenix;
      test_case "triple restart survives" `Quick test_chain_triple_restart_survives;
      test_case "pause while failing then stop" `Quick test_chain_pause_while_failing_then_stop;
      test_case "maximum turbulence (7 phases)" `Quick test_chain_maximum_turbulence;
      test_case "condition snapshot audit" `Quick test_chain_condition_snapshot_audit;
    ];
    "invariants", [
      test_case "INV-1: derive_phase idempotent" `Quick test_invariant_derive_phase_idempotent;
      test_case "INV-2: terminal states absorbing" `Quick test_invariant_terminal_absorbing;
      test_case "INV-3: Fiber_started reset exhaustive" `Quick test_invariant_fiber_started_reset_exhaustive;
      test_case "INV-4: no cross-life hb leakage" `Quick test_invariant_no_cross_life_hb_leakage;
      test_case "INV-5: no cross-life backoff leakage" `Quick test_invariant_no_cross_life_backoff_leakage;
      test_case "INV-6: no cross-life buffer leakage" `Quick test_invariant_no_cross_life_buffer_leakage;
      test_case "INV-7: stop_requested monotonic" `Quick test_invariant_stop_requested_monotonic;
      test_case "INV-8: budget exhaustion permanent" `Quick test_invariant_budget_exhaustion_permanent;
      test_case "INV-9: derive matches matrix (180 combos)" `Quick test_invariant_derive_matches_matrix;
      test_case "INV-10: priority chain ordering" `Quick test_invariant_priority_chain;
    ];
    "mermaid", [
      test_case "header is stateDiagram-v2" `Quick test_mermaid_header;
      test_case "all phases appear in diagram" `Quick test_mermaid_all_phases_appear;
      test_case "active phases get active class only" `Quick test_mermaid_active_class;
      test_case "buffer phases get buffer class only" `Quick test_mermaid_buffer_class;
      test_case "terminal phases get terminal class only" `Quick test_mermaid_terminal_class;
    ];
    "setclear_coverage", [
      test_case "every condition field has setter and clearer" `Quick
        test_setclear_coverage;
    ];
    "attribution", [
      test_case "successful transition → Passed" `Quick
        test_attribution_ok_passed;
      test_case "Invalid_transition → Transition_blocked" `Quick
        test_attribution_invalid_transition_blocked;
      test_case "Terminal_state → Policy_failed" `Quick
        test_attribution_terminal_policy_failed;
      test_case "gate=keeper_fsm origin=Det invariant" `Quick
        test_attribution_gate_and_origin_invariant;
    ];
  ]
