(** test_keeper_state_machine — RFC-0002 keeper state machine tests.

    Pure unit tests for the deterministic core:
    - derive_phase priority ordering
    - apply_event valid/invalid transitions
    - can_transition matrix completeness
    - Terminal state properties (Stopped, Dead)
    - Backward compatibility (to_legacy)
    - Guard evaluation (pure, snapshot-based) *)

open Alcotest

module SM = Masc_mcp.Keeper_state_machine
module Compat = Masc_mcp.Keeper_state_compat
module Meas = Masc_mcp.Keeper_measurement
module Guard = Masc_mcp.Keeper_guard

let phase_t = testable
  (Fmt.of_to_string SM.phase_to_string) (=)

let legacy_t = testable
  (Fmt.of_to_string Compat.legacy_to_string) (=)

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
  (* Offline is the true initial state: no fiber, no budget concept yet.
     Offline requires all booleans false — including restart_budget_remaining. *)
  (* In practice, Offline is only reachable at the derive_phase fallback.
     Since fiber_alive=false + restart_budget_remaining=false = Dead,
     Offline is currently unreachable via derive_phase alone.
     It requires explicit construction from registry initialization. *)
  (* Verify Offline exists in all_phases *)
  check bool "Offline in all_phases" true
    (List.mem SM.Offline SM.all_phases)

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
  let c = { running_conditions with
    stop_requested = true;
    drain_complete = true;
    compaction_active = true;
  } in
  check phase_t "Stopped beats Compacting" SM.Stopped (SM.derive_phase c)

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

(* ── Backward compat tests ─────────────────────────────── *)

let test_legacy_buffer_states_map_to_running () =
  List.iter (fun phase ->
    check legacy_t "maps to Running" Compat.Running (Compat.to_legacy phase)
  ) [ SM.Failing; SM.Compacting; SM.HandingOff; SM.Draining ]

let test_legacy_restarting_maps_to_crashed () =
  check legacy_t "Restarting -> Crashed" Compat.Crashed (Compat.to_legacy SM.Restarting)

let test_legacy_offline_maps_to_stopped () =
  check legacy_t "Offline -> Stopped" Compat.Stopped (Compat.to_legacy SM.Offline)

let test_legacy_stable_states_identity () =
  check legacy_t "Running" Compat.Running (Compat.to_legacy SM.Running);
  check legacy_t "Paused" Compat.Paused (Compat.to_legacy SM.Paused);
  check legacy_t "Stopped" Compat.Stopped (Compat.to_legacy SM.Stopped);
  check legacy_t "Crashed" Compat.Crashed (Compat.to_legacy SM.Crashed);
  check legacy_t "Dead" Compat.Dead (Compat.to_legacy SM.Dead)

let test_legacy_roundtrip_string () =
  List.iter (fun phase ->
    let legacy = Compat.to_legacy phase in
    let s = Compat.legacy_to_string legacy in
    check bool "non-empty" true (String.length s > 0);
    match Compat.legacy_of_string s with
    | Some recovered -> check legacy_t "roundtrip" legacy recovered
    | None -> fail (Printf.sprintf "legacy_of_string failed for %s" s)
  ) SM.all_phases

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

(* ── Phase roundtrip tests ─────────────────────────────── *)

let test_phase_string_roundtrip () =
  List.iter (fun phase ->
    let s = SM.phase_to_string phase in
    match SM.phase_of_string s with
    | Some recovered -> check phase_t "roundtrip" phase recovered
    | None -> fail (Printf.sprintf "phase_of_string failed for %s" s)
  ) SM.all_phases

(* ── Property: derive_phase x apply_event consistency ──── *)

let test_all_phases_covered () =
  check int "11 phases" 11 (List.length SM.all_phases)

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
    ];
    "backward_compat", [
      test_case "buffer -> Running" `Quick test_legacy_buffer_states_map_to_running;
      test_case "Restarting -> Crashed" `Quick test_legacy_restarting_maps_to_crashed;
      test_case "Offline -> Stopped" `Quick test_legacy_offline_maps_to_stopped;
      test_case "stable identity" `Quick test_legacy_stable_states_identity;
      test_case "string roundtrip" `Quick test_legacy_roundtrip_string;
    ];
    "guard", [
      test_case "healthy = no action events" `Quick test_guard_healthy_no_crash_events;
      test_case "compaction triggers" `Quick test_guard_compaction_triggers;
      test_case "handoff triggers" `Quick test_guard_handoff_triggers;
      test_case "guardrail triggers" `Quick test_guard_guardrail_triggers;
      test_case "hb failure at threshold" `Quick test_guard_hb_failure_threshold;
    ];
    "roundtrip", [
      test_case "phase string roundtrip" `Quick test_phase_string_roundtrip;
      test_case "11 phases" `Quick test_all_phases_covered;
    ];
  ]
