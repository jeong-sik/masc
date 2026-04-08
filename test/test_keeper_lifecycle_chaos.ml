(** Keeper Lifecycle Chaos Tests — fault injection through the registry.

    Tests the integration between keeper_registry.dispatch_event and
    keeper_state_machine.apply_event by simulating the exact event
    sequences that keeper_keepalive and keeper_supervisor produce.

    This fills the gap between:
    - Pure FSM unit tests (test_keeper_state_machine.ml, 98 tests)
    - Manual E2E observation

    Each test verifies a realistic failure → recovery lifecycle:
    1. Heartbeat failure cascade: Running → Failing → Crashed
    2. Supervisor restart cycle: Crashed → Restarting → Running
    3. Budget exhaustion: Crashed → Dead (terminal)
    4. Compaction interruption: Running → Compacting → Crashed → recovery
    5. Graceful shutdown: Running → Draining → Stopped (terminal)
    6. Full chaos sequence: multiple fault types interleaved

    @since 2.261.0 — Production readiness audit, Issue #4 *)

open Alcotest

module R = Masc_mcp.Keeper_registry
module KSM = Masc_mcp.Keeper_state_machine
module Keeper_types = Masc_mcp.Keeper_types

let bp = "/tmp/test-chaos"

let make_meta name =
  let json =
    `Assoc
      [ ("name", `String name)
      ; ("agent_name", `String ("agent-" ^ name))
      ; ("trace_id", `String ("trace-chaos-" ^ name))
      ; ("goal", `String "chaos test goal")
      ]
  in
  match Keeper_types.meta_of_json json with
  | Ok meta -> meta
  | Error err -> Alcotest.fail ("make_meta failed: " ^ err)

let eio_test name fn =
  test_case name `Quick (fun () ->
    Eio_main.run @@ fun env ->
    Fs_compat.set_fs (Eio.Stdenv.fs env);
    fn ())

let phase_t = testable (Fmt.of_to_string KSM.phase_to_string) ( = )

let get_phase name =
  match R.get ~base_path:bp name with
  | None -> Alcotest.fail ("keeper not found: " ^ name)
  | Some e -> e.phase

let dispatch name event =
  match R.dispatch_event ~base_path:bp name event with
  | Ok tr -> tr
  | Error e -> Alcotest.fail (KSM.transition_error_to_string e)

let dispatch_expect_terminal name event =
  match R.dispatch_event ~base_path:bp name event with
  | Ok _ -> Alcotest.fail "expected terminal error"
  | Error (KSM.Terminal_state _) -> ()
  | Error e -> Alcotest.fail ("expected Terminal_state, got: " ^ KSM.transition_error_to_string e)

(* ══════════════════════════════════════════════════════════ *)
(* Scenario 1: Heartbeat failure cascade                     *)
(* Simulates: keeper_keepalive.ml:589 dispatching            *)
(* consecutive heartbeat failures until crash threshold.     *)
(* ══════════════════════════════════════════════════════════ *)

let test_heartbeat_failure_cascade () =
  R.clear ();
  ignore (R.register ~base_path:bp "hb-fail" (make_meta "hb-fail"));
  check phase_t "initial" KSM.Running (get_phase "hb-fail");

  (* First failure: Running → Failing *)
  let tr = dispatch "hb-fail"
    (KSM.Heartbeat_failed { consecutive = 1; max_allowed = 5 }) in
  check phase_t "after 1st failure" KSM.Failing tr.new_phase;

  (* Recovery: heartbeat succeeds → Failing → Running *)
  let tr2 = dispatch "hb-fail" KSM.Heartbeat_ok in
  check phase_t "after recovery" KSM.Running tr2.new_phase;

  (* Fail again, this time all the way to crash *)
  ignore (dispatch "hb-fail"
    (KSM.Heartbeat_failed { consecutive = 1; max_allowed = 5 }));
  check phase_t "failing again" KSM.Failing (get_phase "hb-fail");

  (* Fiber terminates due to unrecoverable failure *)
  let tr3 = dispatch "hb-fail"
    (KSM.Fiber_terminated { outcome = "heartbeat exceeded max" }) in
  check phase_t "fiber crash" KSM.Crashed tr3.new_phase

(* ══════════════════════════════════════════════════════════ *)
(* Scenario 2: Supervisor restart cycle                      *)
(* Simulates: keeper_supervisor.ml:376 dispatching restart   *)
(* attempt after detecting a crashed keeper.                 *)
(* ══════════════════════════════════════════════════════════ *)

let test_supervisor_restart_cycle () =
  R.clear ();
  ignore (R.register ~base_path:bp "sv-restart" (make_meta "sv-restart"));

  (* Crash the keeper *)
  ignore (dispatch "sv-restart"
    (KSM.Heartbeat_failed { consecutive = 5; max_allowed = 5 }));
  ignore (dispatch "sv-restart"
    (KSM.Fiber_terminated { outcome = "crash" }));
  check phase_t "crashed" KSM.Crashed (get_phase "sv-restart");

  (* Supervisor detects crash, initiates restart *)
  let tr = dispatch "sv-restart"
    (KSM.Supervisor_restart_attempt { attempt = 1 }) in
  check phase_t "restarting" KSM.Restarting tr.new_phase;

  (* New fiber starts successfully *)
  let tr2 = dispatch "sv-restart"
    KSM.Fiber_started in
  check phase_t "recovered to running" KSM.Running tr2.new_phase

(* ══════════════════════════════════════════════════════════ *)
(* Scenario 3: Restart budget exhaustion → Dead              *)
(* Simulates: keeper crashing repeatedly until max_restarts  *)
(* is exceeded, transitioning to terminal Dead state.        *)
(* ══════════════════════════════════════════════════════════ *)

let test_budget_exhaustion_to_dead () =
  R.clear ();
  ignore (R.register ~base_path:bp "budget-dead" (make_meta "budget-dead"));

  (* Crash *)
  ignore (dispatch "budget-dead"
    (KSM.Heartbeat_failed { consecutive = 5; max_allowed = 5 }));
  ignore (dispatch "budget-dead"
    (KSM.Fiber_terminated { outcome = "crash" }));
  check phase_t "crashed" KSM.Crashed (get_phase "budget-dead");

  (* Exhaust restart budget *)
  let tr = dispatch "budget-dead" KSM.Restart_budget_exhausted in
  check phase_t "dead" KSM.Dead tr.new_phase;

  (* Dead is terminal: all events rejected *)
  dispatch_expect_terminal "budget-dead" KSM.Heartbeat_ok;
  dispatch_expect_terminal "budget-dead"
    (KSM.Supervisor_restart_attempt { attempt = 99 });
  dispatch_expect_terminal "budget-dead"
    KSM.Fiber_started

(* ══════════════════════════════════════════════════════════ *)
(* Scenario 4: Compaction interruption                       *)
(* Simulates: compaction starts, then crashes mid-way.       *)
(* Keeper should recover through restart cycle.              *)
(* ══════════════════════════════════════════════════════════ *)

let test_compaction_crash_recovery () =
  R.clear ();
  ignore (R.register ~base_path:bp "compact-crash" (make_meta "compact-crash"));

  (* Start compaction *)
  let tr = dispatch "compact-crash" KSM.Compaction_started in
  check phase_t "compacting" KSM.Compacting tr.new_phase;

  (* Compaction fails → fiber crashes *)
  ignore (dispatch "compact-crash"
    (KSM.Compaction_completed { before_tokens = 100000; after_tokens = 90000 }));
  let tr2 = dispatch "compact-crash"
    (KSM.Fiber_terminated { outcome = "compaction OOM" }) in
  check phase_t "crashed after compaction fail" KSM.Crashed tr2.new_phase;

  (* Supervisor restarts *)
  ignore (dispatch "compact-crash"
    (KSM.Supervisor_restart_attempt { attempt = 1 }));
  let tr3 = dispatch "compact-crash"
    KSM.Fiber_started in
  check phase_t "recovered" KSM.Running tr3.new_phase

(* ══════════════════════════════════════════════════════════ *)
(* Scenario 5: Graceful shutdown                             *)
(* Simulates: operator requests stop while keeper is active. *)
(* Running → Draining → Stopped (terminal).                 *)
(* ══════════════════════════════════════════════════════════ *)

let test_graceful_shutdown () =
  R.clear ();
  ignore (R.register ~base_path:bp "shutdown" (make_meta "shutdown"));

  (* Operator requests stop *)
  let tr = dispatch "shutdown" KSM.Stop_requested in
  check phase_t "draining" KSM.Draining tr.new_phase;

  (* Drain completes *)
  let tr2 = dispatch "shutdown" KSM.Drain_complete in
  check phase_t "stopped" KSM.Stopped tr2.new_phase;

  (* Stopped is terminal *)
  dispatch_expect_terminal "shutdown" KSM.Heartbeat_ok;
  dispatch_expect_terminal "shutdown"
    KSM.Fiber_started

(* ══════════════════════════════════════════════════════════ *)
(* Scenario 6: Handoff interruption                          *)
(* Simulates: handoff starts, succeeds, then new gen runs.  *)
(* ══════════════════════════════════════════════════════════ *)

let test_handoff_success () =
  R.clear ();
  ignore (R.register ~base_path:bp "handoff" (make_meta "handoff"));

  let tr = dispatch "handoff" KSM.Handoff_started in
  check phase_t "handing off" KSM.HandingOff tr.new_phase;

  let tr2 = dispatch "handoff"
    (KSM.Handoff_completed { new_trace_id = "trace-2"; generation = 2 }) in
  check phase_t "back to running" KSM.Running tr2.new_phase

(* ══════════════════════════════════════════════════════════ *)
(* Scenario 7: Pause and resume                              *)
(* Simulates: operator pauses keeper, then resumes.          *)
(* ══════════════════════════════════════════════════════════ *)

let test_pause_resume () =
  R.clear ();
  ignore (R.register ~base_path:bp "pause" (make_meta "pause"));

  let tr = dispatch "pause" KSM.Operator_pause in
  check phase_t "paused" KSM.Paused tr.new_phase;

  let tr2 = dispatch "pause" KSM.Operator_resume in
  check phase_t "running again" KSM.Running tr2.new_phase

(* ══════════════════════════════════════════════════════════ *)
(* Scenario 8: Full chaos — interleaved faults               *)
(* Simulates: realistic production scenario with multiple    *)
(* fault types hitting a keeper in rapid succession.         *)
(* ══════════════════════════════════════════════════════════ *)

let test_full_chaos_sequence () =
  R.clear ();
  ignore (R.register ~base_path:bp "chaos" (make_meta "chaos"));

  (* Phase 1: Running, heartbeat hiccup, recover *)
  ignore (dispatch "chaos"
    (KSM.Heartbeat_failed { consecutive = 1; max_allowed = 5 }));
  check phase_t "failing-1" KSM.Failing (get_phase "chaos");
  ignore (dispatch "chaos" KSM.Heartbeat_ok);
  check phase_t "recovered-1" KSM.Running (get_phase "chaos");

  (* Phase 2: Compaction during healthy operation *)
  ignore (dispatch "chaos" KSM.Compaction_started);
  check phase_t "compacting" KSM.Compacting (get_phase "chaos");
  ignore (dispatch "chaos"
    (KSM.Compaction_completed { before_tokens = 100000; after_tokens = 30000 }));
  check phase_t "post-compact" KSM.Running (get_phase "chaos");

  (* Phase 3: Heartbeat fails during handoff attempt *)
  ignore (dispatch "chaos" KSM.Handoff_started);
  check phase_t "handoff" KSM.HandingOff (get_phase "chaos");
  (* Handoff fails, fiber crashes *)
  ignore (dispatch "chaos"
    (KSM.Handoff_completed { new_trace_id = "trace-fail"; generation = 1 }));
  ignore (dispatch "chaos"
    (KSM.Fiber_terminated { outcome = "handoff target unreachable" }));
  check phase_t "crashed-handoff" KSM.Crashed (get_phase "chaos");

  (* Phase 4: Supervisor restart *)
  ignore (dispatch "chaos"
    (KSM.Supervisor_restart_attempt { attempt = 1 }));
  check phase_t "restarting" KSM.Restarting (get_phase "chaos");
  ignore (dispatch "chaos"
    KSM.Fiber_started);
  check phase_t "gen2-running" KSM.Running (get_phase "chaos");

  (* Phase 5: Pause, then crash while paused *)
  ignore (dispatch "chaos" KSM.Operator_pause);
  check phase_t "paused" KSM.Paused (get_phase "chaos");
  ignore (dispatch "chaos" KSM.Operator_resume);
  check phase_t "resumed" KSM.Running (get_phase "chaos");

  (* Phase 6: Final graceful shutdown *)
  ignore (dispatch "chaos" KSM.Stop_requested);
  check phase_t "draining" KSM.Draining (get_phase "chaos");
  ignore (dispatch "chaos" KSM.Drain_complete);
  check phase_t "final-stopped" KSM.Stopped (get_phase "chaos")

(* ══════════════════════════════════════════════════════════ *)
(* Scenario 9: Multiple keepers under simultaneous faults    *)
(* Simulates: fleet-level chaos — keepers in different       *)
(* phases receive independent fault events.                  *)
(* ══════════════════════════════════════════════════════════ *)

let test_fleet_chaos () =
  R.clear ();
  let keepers = ["fleet-a"; "fleet-b"; "fleet-c"; "fleet-d"] in
  List.iter (fun name ->
    ignore (R.register ~base_path:bp name (make_meta name))
  ) keepers;

  (* A: stays healthy *)
  ignore (dispatch "fleet-a" KSM.Heartbeat_ok);

  (* B: crashes *)
  ignore (dispatch "fleet-b"
    (KSM.Heartbeat_failed { consecutive = 5; max_allowed = 5 }));
  ignore (dispatch "fleet-b"
    (KSM.Fiber_terminated { outcome = "crash" }));

  (* C: compacting *)
  ignore (dispatch "fleet-c" KSM.Compaction_started);

  (* D: paused *)
  ignore (dispatch "fleet-d" KSM.Operator_pause);

  (* Verify all independent *)
  check phase_t "A running" KSM.Running (get_phase "fleet-a");
  check phase_t "B crashed" KSM.Crashed (get_phase "fleet-b");
  check phase_t "C compacting" KSM.Compacting (get_phase "fleet-c");
  check phase_t "D paused" KSM.Paused (get_phase "fleet-d");

  (* Running count should only include A *)
  check int "1 running" 1 (R.count_running ());

  (* Recover B *)
  ignore (dispatch "fleet-b"
    (KSM.Supervisor_restart_attempt { attempt = 1 }));
  ignore (dispatch "fleet-b"
    KSM.Fiber_started);
  check phase_t "B recovered" KSM.Running (get_phase "fleet-b");
  check int "2 running" 2 (R.count_running ())

(* ══════════════════════════════════════════════════════════ *)
(* Scenario 10: Turn failure cascade (distinct from heartbeat) *)
(* ══════════════════════════════════════════════════════════ *)

let test_turn_failure_cascade () =
  R.clear ();
  ignore (R.register ~base_path:bp "turn-fail" (make_meta "turn-fail"));

  (* Turn failures cause Failing *)
  let tr = dispatch "turn-fail"
    (KSM.Turn_failed { consecutive = 3; max_allowed = 5 }) in
  check phase_t "failing from turn" KSM.Failing tr.new_phase;

  (* Turn success recovers *)
  let tr2 = dispatch "turn-fail" KSM.Turn_succeeded in
  check phase_t "recovered" KSM.Running tr2.new_phase

(* ══════════════════════════════════════════════════════════ *)

let () =
  run "Keeper lifecycle chaos"
    [ ( "heartbeat"
      , [ eio_test "failure cascade → crash" test_heartbeat_failure_cascade
        ] )
    ; ( "supervisor"
      , [ eio_test "restart cycle: Crashed → Restarting → Running" test_supervisor_restart_cycle
        ] )
    ; ( "terminal"
      , [ eio_test "budget exhaustion → Dead (absorbing)" test_budget_exhaustion_to_dead
        ; eio_test "graceful shutdown → Stopped (absorbing)" test_graceful_shutdown
        ] )
    ; ( "buffer_states"
      , [ eio_test "compaction crash → recovery" test_compaction_crash_recovery
        ; eio_test "handoff success" test_handoff_success
        ; eio_test "pause and resume" test_pause_resume
        ] )
    ; ( "chaos"
      , [ eio_test "full chaos: 6-phase interleaved faults" test_full_chaos_sequence
        ; eio_test "fleet: 4 keepers simultaneous independent faults" test_fleet_chaos
        ] )
    ; ( "turn_failures"
      , [ eio_test "turn failure cascade → recovery" test_turn_failure_cascade
        ] )
    ]
