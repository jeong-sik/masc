(** test_keeper_state_machine_pbt — Property-based tests for keeper state machine.

    Two modes:
    - Chaos: random events from all 22 variants. Tests rejection correctness.
    - Guided: phase-aware events only. Tests state transition coverage. *)

module SM = Masc_mcp.Keeper_state_machine
module IC = Masc_mcp.Keeper_invariant_check

(* ── Chaos Generator: all 22 event variants ────────────── *)

let gen_auto_rules : SM.auto_rule_summary QCheck.Gen.t =
  let open QCheck.Gen in
  let* guardrail_stop = bool in
  let* handoff = bool in
  let* compact = bool in
  let* goal_drift = float_range 0.0 1.0 in
  return SM.{
    reflect = false; plan = false; compact; handoff;
    guardrail_stop; guardrail_reason = None; goal_drift;
  }

let gen_event_chaos : SM.event QCheck.Gen.t =
  let open QCheck.Gen in
  oneof [
    return SM.Heartbeat_ok;
    (let* consecutive = int_range 1 10 in
     return (SM.Heartbeat_failed { consecutive; max_allowed = 5 }));
    return SM.Turn_succeeded;
    (let* consecutive = int_range 1 5 in
     return (SM.Turn_failed { consecutive; max_allowed = 3 }));
    return (SM.Manual_reconcile_required { reason = "pbt_test" });
    (let* ratio = float_range 0.0 1.0 in
     let* auto_rules = gen_auto_rules in
     return (SM.Context_measured {
       context_ratio = ratio; message_count = 50;
       token_count = 5000; auto_rules }));
    return SM.Compaction_started;
    (let* before = int_range 1000 100000 in
     let* after = int_range 100 (max 101 before) in
     return (SM.Compaction_completed { before_tokens = before; after_tokens = after }));
    return (SM.Compaction_failed { reason = "pbt_test" });
    return SM.Handoff_started;
    (let* gen = int_range 1 100 in
     return (SM.Handoff_completed { new_trace_id = "pbt_trace"; generation = gen }));
    return (SM.Handoff_failed { reason = "pbt_test" });
    return SM.Operator_pause;
    return SM.Operator_resume;
    return (SM.Operator_stop { remove_meta = false });
    return SM.Stop_requested;
    return SM.Drain_complete;
    return SM.Fiber_started;
    return (SM.Fiber_terminated { outcome = "pbt_test" });
    (let* attempt = int_range 1 5 in
     return (SM.Supervisor_restart_attempt { attempt }));
    return SM.Restart_budget_exhausted;
    return (SM.Guardrail_stop { reason = "pbt_test" });
  ]

(* ── Guided Generator: phase-aware valid events ────────── *)

let valid_events_for_phase (phase : SM.phase) (c : SM.conditions) : SM.event list =
  let base = match phase with
    | SM.Running ->
      [ SM.Heartbeat_ok;
        SM.Heartbeat_failed { consecutive = 1; max_allowed = 5 };
        SM.Turn_succeeded;
        SM.Turn_failed { consecutive = 1; max_allowed = 3 };
        SM.Manual_reconcile_required { reason = "test" };
        SM.Context_measured {
          context_ratio = 0.5; message_count = 50; token_count = 5000;
          auto_rules = { reflect = false; plan = false; compact = false;
                         handoff = false; guardrail_stop = false;
                         guardrail_reason = None; goal_drift = 0.0 }};
        SM.Compaction_started;
        SM.Handoff_started;
        SM.Operator_pause;
        SM.Stop_requested;
        SM.Operator_stop { remove_meta = false };
        SM.Fiber_terminated { outcome = "crash" };
        SM.Guardrail_stop { reason = "test" };
      ]
    | SM.Failing ->
      [ SM.Heartbeat_ok; SM.Turn_succeeded;
        SM.Manual_reconcile_required { reason = "test" };
        SM.Fiber_terminated { outcome = "crash" };
        SM.Stop_requested; SM.Operator_pause;
      ]
    | SM.Compacting ->
      [ SM.Compaction_completed { before_tokens = 100; after_tokens = 50 };
        SM.Compaction_failed { reason = "test" };
        SM.Heartbeat_failed { consecutive = 1; max_allowed = 5 };
        SM.Fiber_terminated { outcome = "crash" };
        SM.Stop_requested;
      ]
    | SM.HandingOff ->
      [ SM.Handoff_completed { new_trace_id = "t"; generation = 1 };
        SM.Handoff_failed { reason = "test" };
        SM.Heartbeat_failed { consecutive = 1; max_allowed = 5 };
        SM.Fiber_terminated { outcome = "crash" };
        SM.Stop_requested;
      ]
    | SM.Draining ->
      [ SM.Drain_complete;
        SM.Fiber_terminated { outcome = "crash" };
      ]
    | SM.Paused ->
      [ SM.Operator_resume;
        SM.Stop_requested; SM.Operator_stop { remove_meta = false };
        SM.Fiber_terminated { outcome = "crash" };
      ]
    | SM.Crashed ->
      [ SM.Supervisor_restart_attempt { attempt = 1 };
        SM.Restart_budget_exhausted;
      ]
    | SM.Restarting ->
      [ SM.Fiber_started;
        SM.Fiber_terminated { outcome = "fail" };
        SM.Restart_budget_exhausted;
      ]
    | SM.Stopped | SM.Dead -> []
    | SM.Offline -> [ SM.Fiber_started ]
  in
  (* Also add Context_measured with guardrail=true when running *)
  let guardrail_events = match phase with
    | SM.Running | SM.Failing ->
      [ SM.Context_measured {
          context_ratio = 0.95; message_count = 200; token_count = 50000;
          auto_rules = { reflect = false; plan = false; compact = false;
                         handoff = false; guardrail_stop = true;
                         guardrail_reason = Some "high_ratio"; goal_drift = 0.8 }} ]
    | _ -> []
  in
  let _ = c in
  base @ guardrail_events

let gen_event_guided (phase : SM.phase) (c : SM.conditions) : SM.event QCheck.Gen.t =
  match valid_events_for_phase phase c with
  | [] -> gen_event_chaos  (* fallback for terminal states *)
  | candidates ->
    QCheck.Gen.oneof (List.map QCheck.Gen.return candidates)

(* ── State simulation ──────────────────────────────────── *)

type sim_state = {
  phase : SM.phase;
  conditions : SM.conditions;
  restart_count : int;
}

let init_state : sim_state = {
  phase = SM.Running;
  conditions = { SM.default_conditions with
    fiber_alive = true;
    restart_budget_remaining = true;
  };
  restart_count = 0;
}

let apply_event_sim (state : sim_state) (event : SM.event) : sim_state =
  match SM.apply_event ~current_phase:state.phase
          ~conditions:state.conditions ~event ~now:1000.0 with
  | Ok tr ->
    let restart_count = match event with
      | SM.Supervisor_restart_attempt _ -> state.restart_count + 1
      | _ -> state.restart_count
    in
    { phase = tr.new_phase;
      conditions = tr.updated_conditions;
      restart_count }
  | Error _ ->
    state  (* rejected event: no state change *)

(* ── Property tests ────────────────────────────────────── *)

let check_invariants_sequence events =
  let rec loop prev_state = function
    | [] -> []
    | event :: rest ->
      let new_state = apply_event_sim prev_state event in
      let violations = IC.check_step_invariants
          ~prev_phase:prev_state.phase
          ~prev_conditions:prev_state.conditions
          ~prev_restart_count:prev_state.restart_count
          ~new_phase:new_state.phase
          ~new_conditions:new_state.conditions
          ~new_restart_count:new_state.restart_count
      in
      if violations <> [] then violations
      else loop new_state rest
  in
  loop init_state events

let show_events events =
  String.concat "; " (List.map SM.event_to_string events)

(* ── QCheck tests ──────────────────────────────────────── *)

let gen_event_list_chaos : SM.event list QCheck.Gen.t =
  let open QCheck.Gen in
  let* len = int_range 1 100 in
  list_size (return len) gen_event_chaos

let test_chaos_invariants =
  QCheck.Test.make
    ~count:10000
    ~name:"chaos: safety invariants hold under random event sequences"
    (QCheck.make gen_event_list_chaos)
    (fun events ->
       match check_invariants_sequence events with
       | [] -> true
       | v :: _ ->
         QCheck.Test.fail_reportf
           "Invariant %s violated: %s\nEvents: %s"
           v.IC.property v.IC.detail (show_events events))

let test_guided_invariants =
  QCheck.Test.make
    ~count:10000
    ~name:"guided: safety invariants hold under phase-aware event sequences"
    QCheck.(make (Gen.int_range 10 100))
    (fun seq_len ->
       let rec build_events state n acc =
         if n <= 0 then List.rev acc
         else
           let event = QCheck.Gen.generate1
             (gen_event_guided state.phase state.conditions) in
           let new_state = apply_event_sim state event in
           build_events new_state (n - 1) (event :: acc)
       in
       let events = build_events init_state seq_len [] in
       match check_invariants_sequence events with
       | [] -> true
       | v :: _ ->
         QCheck.Test.fail_reportf
           "Invariant %s violated: %s\nEvents: %s"
           v.IC.property v.IC.detail (show_events events))

(* ── Test runner ───────────────────────────────────────── *)

let () =
  let open Alcotest in
  run "keeper_state_machine_pbt" [
    "chaos", [
      QCheck_alcotest.to_alcotest test_chaos_invariants;
    ];
    "guided", [
      QCheck_alcotest.to_alcotest test_guided_invariants;
    ];
  ]
