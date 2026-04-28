(** Keeper Lifecycle Chaos Tests — fault injection through the registry.

    Tests the integration between keeper_registry.dispatch_event and
    keeper_state_machine.apply_event by simulating the exact event
    sequences that keeper_keepalive and keeper_supervisor produce.

    Fills the gap between pure FSM unit tests (98 tests) and manual E2E.

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
  match Masc_test_deps.meta_of_json_fixture json with
  | Ok meta -> meta
  | Error err -> Alcotest.fail ("make_meta failed: " ^ err)

let eio_test name fn =
  test_case name `Quick (fun () ->
    Eio_main.run @@ fun env ->
    Fs_compat.set_fs (Eio.Stdenv.fs env);
    fn ())

let phase_t = testable (Fmt.of_to_string KSM.phase_to_string) ( = )

(** Read-only phase query — no state mutation, unlike dispatching a no-op event. *)
let get_phase name =
  match R.get ~base_path:bp name with
  | None -> Alcotest.fail ("keeper not found: " ^ name)
  | Some e -> e.phase

let dispatch name event =
  match R.dispatch_event ~base_path:bp name event with
  | Ok tr -> tr
  | Error e -> Alcotest.fail (KSM.transition_error_to_string e)

let dispatch_expect_rejected name event =
  match R.dispatch_event ~base_path:bp name event with
  | Ok _ -> Alcotest.fail "expected rejected transition"
  (* R.dispatch_event returns a closed transition_error type:
     rejected terminal keepers yield either Terminal_state or Invalid_transition. *)
  | Error (KSM.Terminal_state _) -> ()
  | Error (KSM.Invalid_transition _) -> ()

let setup name =
  R.clear ();
  ignore (R.register ~base_path:bp name (make_meta name))

(** Drives keeper from Running → Failing → Crashed via heartbeat failure + fiber death. *)
let crash_keeper name =
  let tr = dispatch name (KSM.Heartbeat_failed { consecutive = 5; max_allowed = 5 }) in
  check phase_t "failing" KSM.Failing tr.new_phase;
  let tr = dispatch name (KSM.Fiber_terminated { outcome = "crash" }) in
  check phase_t "crashed" KSM.Crashed tr.new_phase

let restart_keeper name ~attempt =
  let tr = dispatch name (KSM.Supervisor_restart_attempt { attempt }) in
  check phase_t "restarting" KSM.Restarting tr.new_phase;
  let tr = dispatch name KSM.Fiber_started in
  check phase_t "running" KSM.Running tr.new_phase

let test_heartbeat_failure_cascade () =
  setup "hb-fail";
  (* In the FSM, any heartbeat failure makes the keeper unhealthy immediately.
     max_allowed is carried for keepalive/supervisor policy and audit context. *)
  let tr = dispatch "hb-fail"
    (KSM.Heartbeat_failed { consecutive = 1; max_allowed = 5 }) in
  check phase_t "1st failure → failing" KSM.Failing tr.new_phase;

  let tr = dispatch "hb-fail" KSM.Heartbeat_ok in
  check phase_t "recovery → running" KSM.Running tr.new_phase;

  let tr = dispatch "hb-fail"
    (KSM.Heartbeat_failed { consecutive = 1; max_allowed = 5 }) in
  check phase_t "2nd failure → failing" KSM.Failing tr.new_phase;

  let tr = dispatch "hb-fail"
    (KSM.Fiber_terminated { outcome = "heartbeat exceeded max" }) in
  check phase_t "fiber death → crashed" KSM.Crashed tr.new_phase

let test_supervisor_restart_cycle () =
  setup "sv-restart";
  crash_keeper "sv-restart";
  restart_keeper "sv-restart" ~attempt:1

let test_budget_exhaustion_to_dead () =
  setup "budget-dead";
  crash_keeper "budget-dead";

  let tr = dispatch "budget-dead" KSM.Restart_budget_exhausted in
  check phase_t "dead" KSM.Dead tr.new_phase;

  dispatch_expect_rejected "budget-dead" KSM.Heartbeat_ok;
  dispatch_expect_rejected "budget-dead"
    (KSM.Supervisor_restart_attempt { attempt = 99 });
  dispatch_expect_rejected "budget-dead" KSM.Fiber_started

let test_compaction_crash_recovery () =
  setup "compact";

  let tr = dispatch "compact" KSM.Compaction_started in
  check phase_t "compacting" KSM.Compacting tr.new_phase;

  let tr = dispatch "compact"
    (KSM.Compaction_failed { reason = "OOM during compaction" }) in
  check phase_t "fail → running" KSM.Running tr.new_phase;

  let tr = dispatch "compact" KSM.Compaction_started in
  check phase_t "2nd compaction" KSM.Compacting tr.new_phase;
  let tr = dispatch "compact"
    (KSM.Compaction_completed { before_tokens = 100000; after_tokens = 30000 }) in
  check phase_t "2nd compact → running" KSM.Running tr.new_phase;

  let tr = dispatch "compact"
    (KSM.Fiber_terminated { outcome = "cascading OOM" }) in
  check phase_t "fiber death → crashed" KSM.Crashed tr.new_phase;
  restart_keeper "compact" ~attempt:1

let test_graceful_shutdown () =
  setup "shutdown";

  let tr = dispatch "shutdown" KSM.Stop_requested in
  check phase_t "draining" KSM.Draining tr.new_phase;

  let tr = dispatch "shutdown" KSM.Drain_complete in
  check phase_t "stopped" KSM.Stopped tr.new_phase;

  dispatch_expect_rejected "shutdown" KSM.Heartbeat_ok;
  dispatch_expect_rejected "shutdown" KSM.Fiber_started

let test_handoff_success () =
  setup "handoff";

  let tr = dispatch "handoff" KSM.Handoff_started in
  check phase_t "handing off" KSM.HandingOff tr.new_phase;

  let tr = dispatch "handoff"
    (KSM.Handoff_completed { new_trace_id = "trace-2"; generation = 2 }) in
  check phase_t "back to running" KSM.Running tr.new_phase

let test_pause_resume () =
  setup "pause";

  let tr = dispatch "pause" KSM.Operator_pause in
  check phase_t "paused" KSM.Paused tr.new_phase;

  let tr = dispatch "pause" KSM.Operator_resume in
  check phase_t "resumed" KSM.Running tr.new_phase

let test_full_chaos_sequence () =
  setup "chaos";

  let tr = dispatch "chaos"
    (KSM.Heartbeat_failed { consecutive = 1; max_allowed = 5 }) in
  check phase_t "hb fail → failing" KSM.Failing tr.new_phase;
  let tr = dispatch "chaos" KSM.Heartbeat_ok in
  check phase_t "hb ok → running" KSM.Running tr.new_phase;

  let tr = dispatch "chaos" KSM.Compaction_started in
  check phase_t "compacting" KSM.Compacting tr.new_phase;
  let tr = dispatch "chaos"
    (KSM.Compaction_completed { before_tokens = 100000; after_tokens = 30000 }) in
  check phase_t "post-compact → running" KSM.Running tr.new_phase;

  let tr = dispatch "chaos" KSM.Handoff_started in
  check phase_t "handoff" KSM.HandingOff tr.new_phase;
  (* Handoff completes but fiber crashes immediately after *)
  let tr = dispatch "chaos"
    (KSM.Handoff_completed { new_trace_id = "trace-fail"; generation = 1 }) in
  check phase_t "handoff complete → running" KSM.Running tr.new_phase;
  let tr = dispatch "chaos"
    (KSM.Fiber_terminated { outcome = "handoff target unreachable" }) in
  check phase_t "post-handoff crash" KSM.Crashed tr.new_phase;

  restart_keeper "chaos" ~attempt:1;

  let tr = dispatch "chaos" KSM.Operator_pause in
  check phase_t "paused" KSM.Paused tr.new_phase;
  let tr = dispatch "chaos" KSM.Operator_resume in
  check phase_t "resumed" KSM.Running tr.new_phase;

  let tr = dispatch "chaos" KSM.Stop_requested in
  check phase_t "draining" KSM.Draining tr.new_phase;
  let tr = dispatch "chaos" KSM.Drain_complete in
  check phase_t "final stopped" KSM.Stopped tr.new_phase

let test_fleet_chaos () =
  R.clear ();
  let keepers = ["fleet-a"; "fleet-b"; "fleet-c"; "fleet-d"] in
  List.iter (fun name ->
    ignore (R.register ~base_path:bp name (make_meta name))
  ) keepers;

  ignore (dispatch "fleet-a" KSM.Heartbeat_ok);
  crash_keeper "fleet-b";
  ignore (dispatch "fleet-c" KSM.Compaction_started);
  ignore (dispatch "fleet-d" KSM.Operator_pause);

  check phase_t "A running" KSM.Running (get_phase "fleet-a");
  check phase_t "B crashed" KSM.Crashed (get_phase "fleet-b");
  check phase_t "C compacting" KSM.Compacting (get_phase "fleet-c");
  check phase_t "D paused" KSM.Paused (get_phase "fleet-d");
  check int "1 running" 1 (R.count_running ~base_path:bp ());

  restart_keeper "fleet-b" ~attempt:1;
  check int "2 running" 2 (R.count_running ~base_path:bp ())

let test_turn_failure_cascade () =
  setup "turn-fail";

  (* Turn failures follow the same unhealthy-immediately rule as heartbeat failures. *)
  let tr = dispatch "turn-fail"
    (KSM.Turn_failed { consecutive = 3; max_allowed = 5 }) in
  check phase_t "turn fail → failing" KSM.Failing tr.new_phase;

  let tr = dispatch "turn-fail" KSM.Turn_succeeded in
  check phase_t "turn ok → running" KSM.Running tr.new_phase

let () =
  run "Keeper lifecycle chaos"
    [ ( "heartbeat"
      , [ eio_test "failure cascade → crash" test_heartbeat_failure_cascade ] )
    ; ( "supervisor"
      , [ eio_test "restart cycle" test_supervisor_restart_cycle ] )
    ; ( "terminal"
      , [ eio_test "budget exhaustion → Dead" test_budget_exhaustion_to_dead
        ; eio_test "graceful shutdown → Stopped" test_graceful_shutdown ] )
    ; ( "buffer_states"
      , [ eio_test "compaction crash → recovery" test_compaction_crash_recovery
        ; eio_test "handoff success" test_handoff_success
        ; eio_test "pause and resume" test_pause_resume ] )
    ; ( "chaos"
      , [ eio_test "6-phase interleaved faults" test_full_chaos_sequence
        ; eio_test "fleet: 4 keepers independent faults" test_fleet_chaos ] )
    ; ( "turn_failures"
      , [ eio_test "turn failure cascade → recovery" test_turn_failure_cascade ] )
    ]
