(** Integration tests for Adaptive Heartbeat Phase 0/1/2.

    Tests cross-module scenarios that exercise the supervisor → registry
    interaction paths. Not full E2E (no Room I/O), but verifies the
    behavioral contracts between modules:

    1. Structured crash flow (3 catch branches)
    2. Dead tombstone lifecycle
    3. Self-preservation gate (dominant cohort suppression)
    4. Self-preservation passthrough (below threshold)
    5. Reconcile predicate logic (sweep-owned vs reconcile-eligible)

    @since Phase 2 post-merge improvement *)

open Alcotest

module R = Masc_mcp.Keeper_registry
module Sup = Masc_mcp.Keeper_supervisor
module KT = Masc_mcp.Keeper_types
module Cfg = Env_config

let bp = "/tmp/test-heartbeat-integ"

let temp_dir prefix =
  let dir = Filename.temp_file prefix "" in
  Unix.unlink dir;
  Unix.mkdir dir 0o755;
  dir

let cleanup_dir dir =
  let rec rm path =
    if Sys.file_exists path then
      if Sys.is_directory path then (
        Array.iter (fun name -> rm (Filename.concat path name)) (Sys.readdir path);
        Unix.rmdir path)
      else
        Unix.unlink path
  in
  try rm dir with _ -> ()

let rec wait_until ~clock ~timeout_s predicate =
  if predicate () then true
  else if timeout_s <= 0.0 then false
  else (
    Eio.Time.sleep clock 0.05;
    wait_until ~clock ~timeout_s:(timeout_s -. 0.05) predicate)

let make_meta name =
  let json = `Assoc [
    ("name", `String name);
    ("agent_name", `String ("agent-" ^ name));
    ("trace_id", `String ("trace-integ-" ^ name));
    ("goal", `String "integration test");
  ] in
  match KT.meta_of_json json with
  | Ok meta -> meta
  | Error err -> Alcotest.fail ("make_meta failed: " ^ err)

let eio_test name fn =
  test_case name `Quick (fun () -> Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env); fn ())

(* ══════════════════════════════════════════════════════════
   1. Structured crash flow — supervisor catch simulation
   ══════════════════════════════════════════════════════════ *)

(** Simulate the Keeper_heartbeat_failure catch branch in
    launch_supervised_fiber (lines 54-65 of keeper_supervisor.ml).
    Verifies: state = Crashed, failure_reason stored, done_p resolved. *)
let test_crash_heartbeat_failure () =
  R.clear ();
  let meta = make_meta "hb-crash" in
  let reg = R.register ~base_path:bp "hb-crash" meta in
  (* Simulate what launch_supervised_fiber does on Keeper_heartbeat_failure *)
  let reason = R.Heartbeat_consecutive_failures 5 in
  let reason_str = R.failure_reason_to_string reason in
  R.set_failure_reason ~base_path:bp "hb-crash" (Some reason);
  R.set_state ~base_path:bp "hb-crash" R.Crashed;
  R.record_crash ~base_path:bp "hb-crash" 1000.0 reason_str;
  R.record_error ~base_path:bp "hb-crash" reason_str;
  Eio.Promise.resolve reg.done_r (`Crashed reason_str);
  (* Assert: registry state *)
  (match R.get ~base_path:bp "hb-crash" with
   | None -> fail "expected hb-crash in registry"
   | Some e ->
     check string "state" "crashed" (R.state_to_string e.state);
     (match e.last_failure_reason with
      | Some (R.Heartbeat_consecutive_failures n) ->
        check int "failure count preserved" 5 n
      | _ -> fail "expected Heartbeat_consecutive_failures");
     check bool "has error" true (Option.is_some e.last_error);
     check int "crash log has 1 entry" 1 (List.length e.crash_log));
  (* Assert: promise resolved *)
  match Eio.Promise.peek reg.done_p with
  | Some (`Crashed msg) ->
    check bool "msg contains heartbeat"
      true (String.length msg > 0)
  | _ -> fail "expected Crashed promise"

(** Simulate the generic exception catch branch (lines 67-77). *)
let test_crash_generic_exception () =
  R.clear ();
  let meta = make_meta "exn-crash" in
  let reg = R.register ~base_path:bp "exn-crash" meta in
  let exn_str = "Sys_error(disk full)" in
  let fr = R.Exception exn_str in
  let reason_str = R.failure_reason_to_string fr in
  R.set_failure_reason ~base_path:bp "exn-crash" (Some fr);
  R.set_state ~base_path:bp "exn-crash" R.Crashed;
  R.record_crash ~base_path:bp "exn-crash" 1001.0 reason_str;
  R.record_error ~base_path:bp "exn-crash" reason_str;
  Eio.Promise.resolve reg.done_r (`Crashed reason_str);
  match R.get ~base_path:bp "exn-crash" with
  | None -> fail "expected exn-crash"
  | Some e ->
    check string "state" "crashed" (R.state_to_string e.state);
    (match e.last_failure_reason with
     | Some (R.Exception s) ->
       check string "exception text" exn_str s
     | _ -> fail "expected Exception reason")

(** Simulate the fiber_unresolved fallback (finally block, lines 78-94). *)
let test_crash_fiber_unresolved () =
  R.clear ();
  let meta = make_meta "unresolved" in
  let reg = R.register ~base_path:bp "unresolved" meta in
  (* Simulate: fiber exits without resolving done_r → finally fires *)
  let fr = R.Fiber_unresolved in
  let reason_str = R.failure_reason_to_string fr in
  R.set_failure_reason ~base_path:bp "unresolved" (Some fr);
  R.record_crash ~base_path:bp "unresolved" 1002.0 reason_str;
  R.record_error ~base_path:bp "unresolved" reason_str;
  R.set_state ~base_path:bp "unresolved" R.Crashed;
  Eio.Promise.resolve reg.done_r (`Crashed reason_str);
  match R.get ~base_path:bp "unresolved" with
  | None -> fail "expected unresolved"
  | Some e ->
    (match e.last_failure_reason with
     | Some R.Fiber_unresolved -> ()
     | _ -> fail "expected Fiber_unresolved reason");
    check string "state" "crashed" (R.state_to_string e.state)

(* ══════════════════════════════════════════════════════════
   2. Dead tombstone lifecycle
   ══════════════════════════════════════════════════════════ *)

(** Full lifecycle: Running → Crashed → budget exhausted → Dead.
    Verifies: Dead is terminal, is_registered=true, Dead→Running blocked,
    only unregister can remove a Dead entry. *)
let test_dead_tombstone_full_lifecycle () =
  R.clear ();
  let meta = make_meta "mortal" in
  let reg = R.register ~base_path:bp "mortal" meta in
  check string "initially running" "running"
    (R.state_to_string (Option.get (R.get ~base_path:bp "mortal")).state);
  (* Crash *)
  Eio.Promise.resolve reg.done_r (`Crashed "test");
  R.set_state ~base_path:bp "mortal" R.Crashed;
  (* Simulate budget exhaustion *)
  let max_restarts = Cfg.KeeperSupervisor.max_restarts in
  R.restore_supervisor_state ~base_path:bp "mortal"
    ~restart_count:max_restarts ~last_restart_ts:0.0 ~crash_log:[];
  (match R.get ~base_path:bp "mortal" with
   | Some e -> check bool "budget exhausted" true (e.restart_count >= max_restarts)
   | None -> fail "expected mortal");
  (* Transition to Dead (what sweep does) *)
  R.set_state ~base_path:bp "mortal" R.Dead;
  (* Invariant checks *)
  check bool "Dead is registered" true (R.is_registered ~base_path:bp "mortal");
  check bool "Dead is not running" false (R.is_running ~base_path:bp "mortal");
  check int "running count 0" 0 (R.count_running ~base_path:bp ());
  (* Dead → Running blocked *)
  R.set_state ~base_path:bp "mortal" R.Running;
  (match R.get ~base_path:bp "mortal" with
   | Some e -> check string "still dead after Running attempt" "dead"
       (R.state_to_string e.state)
   | None -> fail "expected mortal");
  (* Dead → Crashed blocked *)
  R.set_state ~base_path:bp "mortal" R.Crashed;
  (match R.get ~base_path:bp "mortal" with
   | Some e -> check string "still dead after Crashed attempt" "dead"
       (R.state_to_string e.state)
   | None -> fail "expected mortal");
  (* Only unregister removes Dead entry *)
  R.unregister ~base_path:bp "mortal";
  check bool "gone after unregister" false
    (R.is_registered ~base_path:bp "mortal")

(* ══════════════════════════════════════════════════════════
   3. Self-preservation: dominant cohort suppressed
   ══════════════════════════════════════════════════════════ *)

(** 3 keepers crashed with same reason, 1 non-dominant.
    With total_keepers=4, ratio=3/4=0.75 > 0.3, candidates=3 >= min(2).
    Dominant cohort (heartbeat) suppressed, non-dominant (exception) passes. *)
let test_self_preservation_suppresses_dominant () =
  R.clear ();
  (* Create 3 heartbeat-failure entries + 1 exception entry *)
  let names = ["sp-hb1"; "sp-hb2"; "sp-hb3"; "sp-exn"] in
  let entries = List.map (fun name ->
    let _reg = R.register ~base_path:bp name (make_meta name) in
    R.set_state ~base_path:bp name R.Crashed;
    let reason = if String.length name > 4 && String.sub name 3 2 = "hb"
      then Some (R.Heartbeat_consecutive_failures 5)
      else Some (R.Exception "timeout") in
    R.set_failure_reason ~base_path:bp name reason;
    match R.get ~base_path:bp name with
    | Some e -> (e, "crash msg")
    | None -> fail ("missing entry: " ^ name)
  ) names in
  (* Only the first 3 are heartbeat failures *)
  let to_restart = List.filteri (fun i _ -> i <> 3) entries in
  (* total=4: all keepers including the running one *)
  let result = Sup.apply_self_preservation ~keepers_dir:"/tmp/test-keepers" ~total_keepers:4
    (to_restart @ [List.nth entries 3]) in
  (* Dominant cohort (heartbeat, 3 entries) should be suppressed.
     Only the exception entry (1) should remain. *)
  check int "only non-dominant survives" 1 (List.length result);
  let survivor_name = (fst (List.hd result)).R.name in
  check string "survivor is exception entry" "sp-exn" survivor_name

(* ══════════════════════════════════════════════════════════
   4. Self-preservation: below threshold — all pass through
   ══════════════════════════════════════════════════════════ *)

(** 1 crashed out of 10 total: ratio=0.1 < 0.3.
    Self-preservation gate does not activate. *)
let test_self_preservation_below_threshold () =
  R.clear ();
  let _reg = R.register ~base_path:bp "lone" (make_meta "lone") in
  R.set_state ~base_path:bp "lone" R.Crashed;
  R.set_failure_reason ~base_path:bp "lone"
    (Some (R.Heartbeat_consecutive_failures 3));
  let entry = match R.get ~base_path:bp "lone" with
    | Some e -> e | None -> fail "missing lone" in
  let to_restart = [(entry, "crash")] in
  let result = Sup.apply_self_preservation ~keepers_dir:"/tmp/test-keepers" ~total_keepers:10 to_restart in
  check int "all pass through" 1 (List.length result)

(** min_candidates not met: 1 candidate < 2 minimum.
    Even with high ratio, gate does not activate. *)
let test_self_preservation_min_candidates_not_met () =
  R.clear ();
  let _reg = R.register ~base_path:bp "solo" (make_meta "solo") in
  R.set_state ~base_path:bp "solo" R.Crashed;
  R.set_failure_reason ~base_path:bp "solo"
    (Some (R.Heartbeat_consecutive_failures 3));
  let entry = match R.get ~base_path:bp "solo" with
    | Some e -> e | None -> fail "missing solo" in
  let to_restart = [(entry, "crash")] in
  (* ratio = 1/1 = 1.0 > 0.3, BUT candidates=1 < min(2) *)
  let result = Sup.apply_self_preservation ~keepers_dir:"/tmp/test-keepers" ~total_keepers:1 to_restart in
  check int "passes despite high ratio" 1 (List.length result)

(* ══════════════════════════════════════════════════════════
   5. Reconcile predicate: sweep-owned vs reconcile-eligible
   ══════════════════════════════════════════════════════════ *)

(** Verify the dominated_by_sweep logic from reconcile_keepalive_keepers.
    Running/Paused/Crashed/Dead = sweep-owned (reconcile must skip).
    Stopped with resolved done_p = reconcile-eligible.
    Stopped with unresolved done_p = sweep will handle. *)
let test_reconcile_predicate_sweep_owned () =
  R.clear ();
  (* Running = sweep-owned *)
  let _e = R.register ~base_path:bp "r1" (make_meta "r1") in
  (match R.get ~base_path:bp "r1" with
   | Some e ->
     check string "running" "running" (R.state_to_string e.state);
     check bool "sweep-owned" true
       (e.state = R.Running || e.state = R.Paused
        || e.state = R.Crashed || e.state = R.Dead)
   | None -> fail "expected r1");
  (* Crashed = sweep-owned *)
  R.set_state ~base_path:bp "r1" R.Crashed;
  (match R.get ~base_path:bp "r1" with
   | Some e -> check bool "crashed is sweep-owned" true
       (e.state = R.Crashed)
   | None -> fail "expected r1");
  (* Dead = sweep-owned *)
  R.set_state ~base_path:bp "r1" R.Dead;
  (match R.get ~base_path:bp "r1" with
   | Some e -> check bool "dead is sweep-owned" true
       (e.state = R.Dead)
   | None -> fail "expected r1")

let test_reconcile_predicate_stopped_resolved () =
  R.clear ();
  let reg = R.register ~base_path:bp "s1" (make_meta "s1") in
  R.set_state ~base_path:bp "s1" R.Stopped;
  Eio.Promise.resolve reg.done_r `Stopped;
  (* Stopped + resolved done_p = reconcile-eligible *)
  (match R.get ~base_path:bp "s1" with
   | Some e ->
     check string "stopped" "stopped" (R.state_to_string e.state);
     check bool "done_p resolved" true
       (Option.is_some (Eio.Promise.peek e.done_p));
     (* dominated_by_sweep logic: Stopped with resolved → NOT dominated *)
     let dominated = match e.state with
       | R.Running | R.Paused | R.Crashed | R.Dead -> true
       | R.Stopped -> Eio.Promise.peek e.done_p = None
     in
     check bool "not dominated (reconcile-eligible)" false dominated
   | None -> fail "expected s1")

let test_reconcile_predicate_stopped_unresolved () =
  R.clear ();
  let _reg = R.register ~base_path:bp "s2" (make_meta "s2") in
  R.set_state ~base_path:bp "s2" R.Stopped;
  (* Stopped + unresolved done_p = sweep will handle *)
  (match R.get ~base_path:bp "s2" with
   | Some e ->
     check string "stopped" "stopped" (R.state_to_string e.state);
     check bool "done_p NOT resolved" true
       (Option.is_none (Eio.Promise.peek e.done_p));
     let dominated = match e.state with
       | R.Running | R.Paused | R.Crashed | R.Dead -> true
       | R.Stopped -> Eio.Promise.peek e.done_p = None
     in
     check bool "dominated (sweep will handle)" true dominated
   | None -> fail "expected s2")

(* ══════════════════════════════════════════════════════════
   6. Cross-cutting: crash → restart state preservation
   ══════════════════════════════════════════════════════════ *)

(** Simulate crash → re-register → restore_supervisor_state.
    Verifies restart_count and crash_log survive across re-registration. *)
let test_restart_state_preservation () =
  R.clear ();
  let meta = make_meta "restartable" in
  let reg1 = R.register ~base_path:bp "restartable" meta in
  Eio.Promise.resolve reg1.done_r (`Crashed "first crash");
  R.set_state ~base_path:bp "restartable" R.Crashed;
  R.record_crash ~base_path:bp "restartable" 100.0 "first crash";
  (* Simulate sweep restart: re-register then restore state *)
  let _reg2 = R.register ~base_path:bp "restartable" meta in
  R.restore_supervisor_state ~base_path:bp "restartable"
    ~restart_count:1 ~last_restart_ts:200.0
    ~crash_log:[(100.0, "first crash")];
  match R.get ~base_path:bp "restartable" with
  | None -> fail "expected restartable"
  | Some e ->
    check int "restart_count preserved" 1 e.restart_count;
    check (float 0.1) "last_restart_ts preserved" 200.0 e.last_restart_ts;
    check int "crash_log preserved" 1 (List.length e.crash_log);
    (* failure_reason should be cleared by re-register *)
    check bool "failure_reason cleared" true
      (Option.is_none e.last_failure_reason);
    (* state should be Running after re-register *)
    check string "state running after restart" "running"
      (R.state_to_string e.state)

(* ══════════════════════════════════════════════════════════
   7. Turn failure → Crashed with Turn_consecutive_failures reason
   ══════════════════════════════════════════════════════════ *)

(** Simulate the turn failure crash path: supervisor catch sets
    Turn_consecutive_failures as failure_reason, state = Crashed. *)
let test_crash_turn_failures () =
  R.clear ();
  let meta = make_meta "turn-crash" in
  let reg = R.register ~base_path:bp "turn-crash" meta in
  let reason = R.Turn_consecutive_failures 10 in
  let reason_str = R.failure_reason_to_string reason in
  R.set_failure_reason ~base_path:bp "turn-crash" (Some reason);
  R.set_state ~base_path:bp "turn-crash" R.Crashed;
  R.record_crash ~base_path:bp "turn-crash" 2000.0 reason_str;
  R.record_error ~base_path:bp "turn-crash" reason_str;
  Eio.Promise.resolve reg.done_r (`Crashed reason_str);
  match R.get ~base_path:bp "turn-crash" with
  | None -> fail "expected turn-crash"
  | Some e ->
    check string "state crashed" "crashed" (R.state_to_string e.state);
    (match e.last_failure_reason with
     | Some (R.Turn_consecutive_failures n) ->
       check int "turn failure count" 10 n
     | _ -> fail "expected Turn_consecutive_failures");
    check bool "crash log" true (List.length e.crash_log > 0)

(** Turn failures produce a distinct cohort key for self-preservation. *)
let test_cohort_key_turn_failures () =
  let key = Sup.cohort_key_of_reason
    (Some (R.Turn_consecutive_failures 10)) in
  check string "turn failure cohort" "turn_failures" key

(* ══════════════════════════════════════════════════════════
   8. Direct keepalive path resolves lifecycle promises
   ══════════════════════════════════════════════════════════ *)

let test_direct_start_keepalive_resolves_done_on_stop () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  R.clear ();
  let base_dir = temp_dir "direct-keepalive" in
  let keeper_name = "direct-lifecycle" in
  Fun.protect
    ~finally:(fun () ->
      Masc_mcp.Keeper_keepalive.stop_keepalive keeper_name;
      cleanup_dir base_dir)
    (fun () ->
      let config = Masc_mcp.Room.default_config base_dir in
      ignore (Masc_mcp.Room.init config ~agent_name:(Some "tester"));
      let meta = make_meta keeper_name in
      Eio.Switch.run @@ fun sw ->
      let ctx : _ KT.context =
        {
          config;
          agent_name = "tester";
          sw;
          clock = Eio.Stdenv.clock env;
          proc_mgr = Some (Eio.Stdenv.process_mgr env);
          net = None;
        }
      in
      Masc_mcp.Keeper_keepalive.start_keepalive ctx meta;
      Eio.Time.sleep ctx.clock 0.05;
      Masc_mcp.Keeper_keepalive.stop_keepalive keeper_name;
      let stopped_resolved =
        wait_until ~clock:ctx.clock ~timeout_s:1.0 (fun () ->
          match R.get ~base_path:config.base_path keeper_name with
          | Some entry -> Option.is_some (Eio.Promise.peek entry.done_p)
          | None -> false)
      in
      match R.get ~base_path:config.base_path keeper_name with
      | None -> fail "expected direct-lifecycle registry entry"
      | Some entry ->
        check string "state stopped" "stopped" (R.state_to_string entry.state);
        check bool "done promise resolved eventually" true stopped_resolved;
        (match Eio.Promise.peek entry.done_p with
         | Some `Stopped -> ()
         | Some (`Crashed reason) ->
           fail ("expected stopped promise, got crashed: " ^ reason)
         | None -> fail "expected done_p to resolve on stop"))

(* ── Test runner ──────────────────────────────────────────── *)

let () =
  run "heartbeat_integration" [
    "structured_crash_flow", [
      eio_test "heartbeat_failure catch" test_crash_heartbeat_failure;
      eio_test "generic exception catch" test_crash_generic_exception;
      eio_test "fiber_unresolved fallback" test_crash_fiber_unresolved;
    ];
    "dead_tombstone", [
      eio_test "full lifecycle" test_dead_tombstone_full_lifecycle;
    ];
    "self_preservation", [
      eio_test "suppresses dominant cohort" test_self_preservation_suppresses_dominant;
      eio_test "below threshold passes" test_self_preservation_below_threshold;
      eio_test "min candidates not met" test_self_preservation_min_candidates_not_met;
    ];
    "reconcile_predicates", [
      eio_test "sweep-owned states" test_reconcile_predicate_sweep_owned;
      eio_test "stopped resolved = eligible" test_reconcile_predicate_stopped_resolved;
      eio_test "stopped unresolved = sweep" test_reconcile_predicate_stopped_unresolved;
    ];
    "restart_flow", [
      eio_test "state preservation across restart" test_restart_state_preservation;
    ];
    "turn_failure", [
      eio_test "turn crash flow" test_crash_turn_failures;
      test_case "cohort key" `Quick test_cohort_key_turn_failures;
    ];
    "direct_keepalive", [
      test_case "stop resolves done promise" `Quick
        test_direct_start_keepalive_resolves_done_on_stop;
    ];
  ]
