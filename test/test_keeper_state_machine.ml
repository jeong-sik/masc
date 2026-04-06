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
let test_chain_restart_inherits_stop () =
  let final_phase, _ = chain_apply
    ~init_phase:SM.Running
    ~init_conditions:running_conditions
    [
      SM.Stop_requested,                                       SM.Draining;
      SM.Fiber_terminated { outcome="crash during drain" },    SM.Crashed;
      SM.Supervisor_restart_attempt { attempt=1 },             SM.Restarting;
      (* Fiber starts but stop_requested persists -> Draining *)
      SM.Fiber_started,                                        SM.Draining;
      SM.Drain_complete,                                       SM.Stopped;
    ]
  in
  check phase_t "stop persists through crash-restart" SM.Stopped final_phase

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
  let final_phase, _ = chain_apply
    ~init_phase:SM.Running
    ~init_conditions:running_conditions
    [
      SM.Handoff_started,                                      SM.HandingOff;
      SM.Operator_stop { remove_meta=false },                  SM.Draining;
      SM.Drain_complete,                                       SM.Stopped;
    ]
  in
  check phase_t "stop overrides handoff" SM.Stopped final_phase

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
      test_case "restart inherits stop_requested" `Quick test_chain_restart_inherits_stop;
      test_case "handoff fail then retry" `Quick test_chain_handoff_fail_retry;
      test_case "guardrail during compaction" `Quick test_chain_guardrail_during_compaction;
      test_case "double failure (hb+turn) recovery" `Quick test_chain_double_failure_recovery;
      test_case "operator stop during handoff" `Quick test_chain_stop_during_handoff;
      test_case "no phoenix (21 events on Dead)" `Quick test_chain_no_phoenix;
      test_case "triple restart survives" `Quick test_chain_triple_restart_survives;
      test_case "pause while failing then stop" `Quick test_chain_pause_while_failing_then_stop;
      test_case "maximum turbulence (7 phases)" `Quick test_chain_maximum_turbulence;
      test_case "condition snapshot audit" `Quick test_chain_condition_snapshot_audit;
    ];
  ]
