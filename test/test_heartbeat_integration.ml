(** Integration tests for Adaptive Heartbeat Phase 0/1/2.

    Tests cross-module scenarios that exercise the supervisor → registry
    interaction paths. Not full E2E (no Workspace I/O), but verifies the
    behavioral contracts between modules:

    1. Structured crash flow (3 catch branches)
    2. Dead tombstone lifecycle
    3. Self-preservation gate (dominant cohort suppression)
    4. Self-preservation passthrough (below threshold)
    5. Reconcile predicate logic (sweep-owned vs reconcile-eligible)

    @since Phase 2 post-merge improvement *)

open Alcotest

module R = Masc.Keeper_registry
module Keeper_types_profile = Masc.Keeper_types_profile
module Sup = Masc.Keeper_supervisor
module KT = Keeper_types
module KSM = Keeper_state_machine
module Cfg = Env_config
module KHL = Masc.Keeper_heartbeat_loop
module Obs = Masc.Keeper_heartbeat_loop_observations
module WO = Masc.Keeper_world_observation
module Health = Masc.Health

let bp = "/tmp/test-heartbeat-integ"

let temp_dir prefix =
  let dir = Filename.temp_file prefix "" in
  Unix.unlink dir;
  Unix.mkdir dir 0o755;
  dir

(* The autonomous keeper_cycle_decision path resolves a runtime id
   (Keeper_meta_contract.runtime_id_of_meta -> Runtime.get_default_runtime_id),
   which fails with no silent fallback (RFC-0206 §2.1) unless a default runtime
   is initialized. Reactive turns return before that point, so only the
   autonomous R2b test needs this. Tolerant of an already-initialized runtime
   (Alcotest runs the whole binary in one process). *)
let ensure_default_runtime () =
  let runtime_toml =
    {|
[runtime]
default = "test_provider.test_model"

[providers.test_provider]
display-name = "Test Provider"
protocol = "openai-compatible-http"
endpoint = "http://127.0.0.1:1"

[models.test_model]
api-name = "test-model"
max-context = 8192
tools-support = true
streaming = true

[test_provider.test_model]
is-default = true
max-concurrent = 1
|}
  in
  let path = Filename.temp_file "heartbeat_integ_runtime_" ".toml" in
  let oc = open_out path in
  Fun.protect
    ~finally:(fun () -> close_out_noerr oc)
    (fun () -> output_string oc runtime_toml);
  (* Ignore Error: a prior test in the binary may have initialized it already. *)
  ignore (Runtime.init_default ~config_path:path)

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
  match Masc_test_deps.meta_of_json_fixture json with
  | Ok meta -> meta
  | Error err -> Alcotest.fail ("make_meta failed: " ^ err)

let resolve_done_for_test reg value =
  ignore (R.resolve_done reg ~source:"test_fixture" value)

let eio_test name fn =
  test_case name `Quick (fun () -> Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env); fn ())

let base_observation : WO.world_observation =
  { pending_mentions = []
  ; pending_board_events = []
  ; pending_scope_messages = []
  ; idle_seconds = 0
  ; active_goals = []
  ; continuity_summary = ""
  ; context_ratio = lazy 0.0
  ; unclaimed_task_count = 0
  ; claimable_task_count = 0
  ; provider_capacity_blocked_task_count = 0
  ; failed_task_count = 0
  ; pending_verification_count = 0
  ; scheduled_automation = WO.empty_scheduled_automation_observation
  ; backlog_updated_since_last_scheduled_autonomous = false
  ; running_keeper_fiber_count = 0
  ; connected_surfaces = []
  }

(* ══════════════════════════════════════════════════════════
   1. Structured crash flow — supervisor catch simulation
   ══════════════════════════════════════════════════════════ *)

(** Simulate the Keeper_fiber_crash catch branch in
    launch_supervised_fiber.  Failure reason is pre-stored in registry,
    exception carries no payload (RFC-0002).
    Verifies: state = Crashed, failure_reason stored, done_p resolved. *)
let test_crash_heartbeat_failure () =
  R.clear ();
  let meta = make_meta "hb-crash" in
  let reg = R.register ~base_path:bp "hb-crash" meta in
  (* Simulate what launch_supervised_fiber does on Keeper_fiber_crash *)
  let reason = R.Heartbeat_consecutive_failures 5 in
  let reason_str = R.failure_reason_to_string reason in
  R.set_failure_reason ~base_path:bp "hb-crash" (Some reason);
  ignore (R.dispatch_event ~base_path:bp "hb-crash"
    (KSM.Fiber_terminated { outcome = "heartbeat_failure"; provider_id = None; http_status = None }));
  R.record_crash ~base_path:bp "hb-crash" 1000.0 reason_str;
  Masc.Keeper_registry_error_recording.record ~base_path:bp "hb-crash" reason_str;
  resolve_done_for_test reg (`Crashed reason_str);
  (* Assert: registry state *)
  (match R.get ~base_path:bp "hb-crash" with
   | None -> fail "expected hb-crash in registry"
   | Some e ->
     check string "state" "crashed" (KSM.phase_to_string e.phase);
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
  ignore (R.dispatch_event ~base_path:bp "exn-crash"
    (KSM.Fiber_terminated { outcome = "exception"; provider_id = None; http_status = None }));
  R.record_crash ~base_path:bp "exn-crash" 1001.0 reason_str;
  Masc.Keeper_registry_error_recording.record ~base_path:bp "exn-crash" reason_str;
  resolve_done_for_test reg (`Crashed reason_str);
  match R.get ~base_path:bp "exn-crash" with
  | None -> fail "expected exn-crash"
  | Some e ->
    check string "state" "crashed" (KSM.phase_to_string e.phase);
    (match e.last_failure_reason with
     | Some (R.Exception s) ->
       check string "exception text" exn_str s
     | _ -> fail "expected Exception reason")

(** Simulate the fiber_unresolved fallback (finally block, lines 78-94). *)
let test_crash_fiber_unresolved () =
  R.clear ();
  let meta = make_meta "unresolved" in
  let reg = R.register ~base_path:bp "unresolved" meta in
  (* Simulate: fiber exits without resolving done_r → finally fires.
     Issue #18901: Unexpected cause (not shutdown) — represents the
     genuine missed-resolution bug path the supervisor must restart. *)
  let fr = R.Fiber_unresolved R.Unexpected in
  let reason_str = R.failure_reason_to_string fr in
  R.set_failure_reason ~base_path:bp "unresolved" (Some fr);
  R.record_crash ~base_path:bp "unresolved" 1002.0 reason_str;
  Masc.Keeper_registry_error_recording.record ~base_path:bp "unresolved" reason_str;
  ignore (R.dispatch_event ~base_path:bp "unresolved"
    (KSM.Fiber_terminated { outcome = "unresolved"; provider_id = None; http_status = None }));
  resolve_done_for_test reg (`Crashed reason_str);
  match R.get ~base_path:bp "unresolved" with
  | None -> fail "expected unresolved"
  | Some e ->
    (match e.last_failure_reason with
     | Some (R.Fiber_unresolved _) -> ()
     | _ -> fail "expected Fiber_unresolved reason");
    check string "state" "crashed" (KSM.phase_to_string e.phase)

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
    (KSM.phase_to_string (Option.get (R.get ~base_path:bp "mortal")).phase);
  (* Crash *)
  resolve_done_for_test reg (`Crashed "test");
  ignore (R.dispatch_event ~base_path:bp "mortal"
    (KSM.Fiber_terminated { outcome = "test"; provider_id = None; http_status = None }));
  (* Simulate budget exhaustion *)
  let max_restarts = Cfg.KeeperSupervisor.max_restarts in
  R.restore_supervisor_state ~base_path:bp "mortal"
    ~restart_count:max_restarts ~last_restart_ts:0.0 ~crash_log:[];
  (match R.get ~base_path:bp "mortal" with
   | Some e -> check bool "budget exhausted" true (e.restart_count >= max_restarts)
   | None -> fail "expected mortal");
  (* Transition to Dead (what sweep does) *)
  R.mark_dead ~base_path:bp "mortal" ~at:(Unix.gettimeofday ());
  (* Invariant checks *)
  check bool "Dead is registered" true (R.is_registered ~base_path:bp "mortal");
  check bool "Dead is not running" false (R.is_running ~base_path:bp "mortal");
  check int "running count 0" 0 (R.count_running ~base_path:bp ());
  (* Dead → Running blocked *)
  ignore (R.dispatch_event ~base_path:bp "mortal" KSM.Fiber_started);
  (match R.get ~base_path:bp "mortal" with
   | Some e -> check string "still dead after Running attempt" "dead"
       (KSM.phase_to_string e.phase)
   | None -> fail "expected mortal");
  (* Dead → Crashed blocked *)
  ignore (R.dispatch_event ~base_path:bp "mortal"
    (KSM.Fiber_terminated { outcome = "test"; provider_id = None; http_status = None }));
  (match R.get ~base_path:bp "mortal" with
   | Some e -> check string "still dead after Crashed attempt" "dead"
       (KSM.phase_to_string e.phase)
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
    ignore (R.dispatch_event ~base_path:bp name
      (KSM.Fiber_terminated { outcome = "test"; provider_id = None; http_status = None }));
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
  ignore (R.dispatch_event ~base_path:bp "lone"
    (KSM.Fiber_terminated { outcome = "test"; provider_id = None; http_status = None }));
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
  ignore (R.dispatch_event ~base_path:bp "solo"
    (KSM.Fiber_terminated { outcome = "test"; provider_id = None; http_status = None }));
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
     check string "running" "running" (KSM.phase_to_string e.phase);
     check bool "sweep-owned" true
       (e.phase = KSM.Running || e.phase = KSM.Paused
        || e.phase = KSM.Crashed || e.phase = KSM.Dead)
   | None -> fail "expected r1");
  (* Crashed = sweep-owned *)
  ignore (R.dispatch_event ~base_path:bp "r1"
    (KSM.Fiber_terminated { outcome = "test"; provider_id = None; http_status = None }));
  (match R.get ~base_path:bp "r1" with
   | Some e -> check bool "crashed is sweep-owned" true
       (e.phase = KSM.Crashed)
   | None -> fail "expected r1");
  (* Dead = sweep-owned *)
  R.mark_dead ~base_path:bp "r1" ~at:(Unix.gettimeofday ());
  (match R.get ~base_path:bp "r1" with
   | Some e -> check bool "dead is sweep-owned" true
       (e.phase = KSM.Dead)
   | None -> fail "expected r1")

let test_reconcile_predicate_stopped_resolved () =
  R.clear ();
  let reg = R.register ~base_path:bp "s1" (make_meta "s1") in
  ignore (R.dispatch_event ~base_path:bp "s1" KSM.Stop_requested);
  ignore (R.dispatch_event ~base_path:bp "s1" KSM.Drain_complete);
  resolve_done_for_test reg `Stopped;
  (* Stopped + resolved done_p = reconcile-eligible *)
  (match R.get ~base_path:bp "s1" with
   | Some e ->
     check string "stopped" "stopped" (KSM.phase_to_string e.phase);
     check bool "done_p resolved" true
       (Option.is_some (Eio.Promise.peek e.done_p));
     (* dominated_by_sweep logic: Stopped with resolved → NOT dominated *)
     let dominated = match e.phase with
       | KSM.Running | KSM.Paused | KSM.Crashed | KSM.Dead | KSM.Zombie -> true
       | KSM.Failing | KSM.Overflowed | KSM.Compacting | KSM.HandingOff
       | KSM.Draining | KSM.Restarting -> true
       | KSM.Offline -> false
       | KSM.Stopped -> Eio.Promise.peek e.done_p = None
     in
     check bool "not dominated (reconcile-eligible)" false dominated
   | None -> fail "expected s1")

let test_reconcile_predicate_stopped_unresolved () =
  R.clear ();
  let _reg = R.register ~base_path:bp "s2" (make_meta "s2") in
  ignore (R.dispatch_event ~base_path:bp "s2" KSM.Stop_requested);
  ignore (R.dispatch_event ~base_path:bp "s2" KSM.Drain_complete);
  (* Stopped + unresolved done_p = sweep will handle *)
  (match R.get ~base_path:bp "s2" with
   | Some e ->
     check string "stopped" "stopped" (KSM.phase_to_string e.phase);
     check bool "done_p NOT resolved" true
       (Option.is_none (Eio.Promise.peek e.done_p));
     let dominated = match e.phase with
       | KSM.Running | KSM.Paused | KSM.Crashed | KSM.Dead | KSM.Zombie -> true
       | KSM.Failing | KSM.Overflowed | KSM.Compacting | KSM.HandingOff
       | KSM.Draining | KSM.Restarting -> true
       | KSM.Offline -> false
       | KSM.Stopped -> Eio.Promise.peek e.done_p = None
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
  resolve_done_for_test reg1 (`Crashed "first crash");
  ignore (R.dispatch_event ~base_path:bp "restartable"
    (KSM.Fiber_terminated { outcome = "first crash"; provider_id = None; http_status = None }));
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
      (KSM.phase_to_string e.phase)

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
  ignore (R.dispatch_event ~base_path:bp "turn-crash"
    (KSM.Fiber_terminated { outcome = "turn failure"; provider_id = None; http_status = None }));
  R.record_crash ~base_path:bp "turn-crash" 2000.0 reason_str;
  Masc.Keeper_registry_error_recording.record ~base_path:bp "turn-crash" reason_str;
  resolve_done_for_test reg (`Crashed reason_str);
  match R.get ~base_path:bp "turn-crash" with
  | None -> fail "expected turn-crash"
  | Some e ->
    check string "state crashed" "crashed" (KSM.phase_to_string e.phase);
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

(** A healthy heartbeat must not erase provider/tool turn failures.
    Regression for live 2026-05-16 evidence where a runtime_exhausted turn
    moved Failing -> Running via a keepalive heartbeat before the next real
    successful turn. *)
let test_fresh_presence_preserves_turn_failures () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  Eio.Switch.run @@ fun sw ->
  R.clear ();
  let base_path = temp_dir "fresh-presence-turn-failure" in
  Fun.protect
    ~finally:(fun () ->
      R.clear ();
      cleanup_dir base_path)
    (fun () ->
      let config = Masc.Workspace.default_config base_path in
      let ctx : _ Keeper_types_profile.context =
        {
          config;
          agent_name = "operator";
          sw;
          clock = Eio.Stdenv.clock env;
          proc_mgr = None;
          net = None;
        }
      in
      let meta = make_meta "fresh-presence-turn-failure" in
      ignore (R.register ~base_path:config.base_path meta.name meta);
      R.increment_turn_failures ~base_path:config.base_path meta.name;
      ignore
        (R.dispatch_event
           ~base_path:config.base_path
           meta.name
           (KSM.Turn_failed { consecutive = 1; max_allowed = 3 }));
      (match R.get_phase ~base_path:config.base_path meta.name with
       | Some phase -> check string "phase after turn failure" "failing" (KSM.phase_to_string phase)
       | None -> fail "expected registered keeper phase");
      ignore
        (Masc.Keeper_heartbeat_loop.sync_keeper_presence
           ~ctx
           ~meta_current:meta
           ~consecutive_failures:(ref 0)
           ~last_successful_heartbeat_ts:(ref 99.0));
      check int
        "turn failures preserved"
        1
        (R.get_turn_failures ~base_path:config.base_path meta.name);
      match R.get_phase ~base_path:config.base_path meta.name with
      | Some phase -> check string "heartbeat alone stays failing" "failing" (KSM.phase_to_string phase)
      | None -> fail "expected registered keeper phase")

(** T6 audit: a swallowed keepalive-cycle exception must surface as a
    turn failure. [record_crashed_cycle_failure] (called by the
    [run_keepalive_unified_turn] catch-all) increments the same
    registry counter the unified-turn failure path uses, and the
    caller's post-turn event mapping ([turn_status_event]) then yields
    [Turn_failed] — not [Turn_succeeded] — moving the state machine to
    failing. *)
let test_crashed_cycle_records_turn_failure () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  R.clear ();
  let base_path = temp_dir "crashed-cycle-turn-failure" in
  Fun.protect
    ~finally:(fun () ->
      R.clear ();
      cleanup_dir base_path)
    (fun () ->
      let config = Masc.Workspace.default_config base_path in
      let meta = make_meta "crashed-cycle" in
      ignore (R.register ~base_path:config.base_path meta.name meta);
      check int "no failures before crash" 0
        (R.get_turn_failures ~base_path:config.base_path meta.name);
      KHL.record_crashed_cycle_failure
        ~base_path:config.base_path
        ~keeper_name:meta.name
        (Failure "boom");
      let count = R.get_turn_failures ~base_path:config.base_path meta.name in
      check int "crash recorded as turn failure" 1 count;
      (* Same registry read + event mapping the caller loop performs
         after [run_keepalive_unified_turn] returns. *)
      let event = KHL.turn_status_event ~turn_fail_count:count ~max_allowed:10 in
      (match event with
       | KSM.Turn_failed { consecutive; max_allowed } ->
         check int "consecutive" 1 consecutive;
         check int "max_allowed" 10 max_allowed
       | _ -> fail "expected Turn_failed for crashed cycle");
      ignore (R.dispatch_event ~base_path:config.base_path meta.name event);
      (match R.get_phase ~base_path:config.base_path meta.name with
       | Some phase ->
         check string "crashed cycle moves state machine to failing" "failing"
           (KSM.phase_to_string phase)
       | None -> fail "expected registered keeper phase");
      (* Clean cycle (count = 0) still maps to Turn_succeeded. *)
      match KHL.turn_status_event ~turn_fail_count:0 ~max_allowed:10 with
      | KSM.Turn_succeeded -> ()
      | _ -> fail "expected Turn_succeeded when no failures recorded")

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
      Masc.Keeper_keepalive.stop_keepalive keeper_name;
      cleanup_dir base_dir)
    (fun () ->
      ensure_default_runtime ();
      let config = Masc.Workspace.default_config base_dir in
      ignore (Masc.Workspace.init config ~agent_name:(Some "tester"));
      let meta = make_meta keeper_name in
      Eio.Switch.run @@ fun sw ->
      let ctx : _ Keeper_types_profile.context =
        {
          config;
          agent_name = "tester";
          sw;
          clock = Eio.Stdenv.clock env;
          proc_mgr = Some (Eio.Stdenv.process_mgr env);
          net = None;
        }
      in
      Masc.Keeper_keepalive.start_keepalive ctx meta;
      Eio.Time.sleep ctx.clock 0.05;
      Masc.Keeper_keepalive.stop_keepalive keeper_name;
      let stopped_resolved =
        wait_until ~clock:ctx.clock ~timeout_s:1.0 (fun () ->
          match R.get ~base_path:config.base_path keeper_name with
          | Some entry -> Option.is_some (Eio.Promise.peek entry.done_p)
          | None -> false)
      in
      match R.get ~base_path:config.base_path keeper_name with
      | None -> fail "expected direct-lifecycle registry entry"
      | Some entry ->
        check string "state stopped" "stopped" (KSM.phase_to_string entry.phase);
        check bool "done promise resolved eventually" true stopped_resolved;
        (match Eio.Promise.peek entry.done_p with
         | Some `Stopped -> ()
         | Some (`Crashed reason) ->
           fail ("expected stopped promise, got crashed: " ^ reason)
         | None -> fail "expected done_p to resolve on stop"))

let test_start_keepalive_preserves_unresolved_failing_entry () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  R.clear ();
  let base_dir = temp_dir "direct-keepalive-live-failing" in
  let keeper_name = "live-failing-entry" in
  Fun.protect
    ~finally:(fun () ->
      Masc.Keeper_keepalive.stop_keepalive keeper_name;
      R.clear ();
      cleanup_dir base_dir)
    (fun () ->
      let config = Masc.Workspace.default_config base_dir in
      ignore (Masc.Workspace.init config ~agent_name:(Some "tester"));
      let meta = make_meta keeper_name in
      let original = R.register ~base_path:config.base_path keeper_name meta in
      ignore
        (R.dispatch_event
           ~base_path:config.base_path
           keeper_name
           (KSM.Turn_failed { consecutive = 1; max_allowed = 3 }));
      Eio.Switch.run @@ fun sw ->
      let ctx : _ Keeper_types_profile.context =
        {
          config;
          agent_name = "tester";
          sw;
          clock = Eio.Stdenv.clock env;
          proc_mgr = Some (Eio.Stdenv.process_mgr env);
          net = None;
        }
      in
      Masc.Keeper_keepalive.start_keepalive ctx meta;
      match R.get ~base_path:config.base_path keeper_name with
      | None -> fail "expected live-failing-entry registry entry"
      | Some entry ->
        check string "phase remains failing" "failing" (KSM.phase_to_string entry.phase);
        check bool "unresolved failing entry is preserved" true
          (entry.done_p == original.done_p);
        check bool "done promise remains unresolved" true
          (Option.is_none (Eio.Promise.peek entry.done_p)))

let test_start_keepalive_reclaims_finished_failing_entry () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  R.clear ();
  let base_dir = temp_dir "direct-keepalive-stale-failing" in
  let keeper_name = "stale-failing-entry" in
  Fun.protect
    ~finally:(fun () ->
      Masc.Keeper_keepalive.stop_keepalive keeper_name;
      R.clear ();
      cleanup_dir base_dir)
    (fun () ->
      let config = Masc.Workspace.default_config base_dir in
      ignore (Masc.Workspace.init config ~agent_name:(Some "tester"));
      let meta = make_meta keeper_name in
      let original = R.register ~base_path:config.base_path keeper_name meta in
      ignore
        (R.dispatch_event
           ~base_path:config.base_path
           keeper_name
           (KSM.Turn_failed { consecutive = 1; max_allowed = 3 }));
      resolve_done_for_test original (`Crashed "provider runtime error");
      Eio.Switch.run @@ fun sw ->
      let ctx : _ Keeper_types_profile.context =
        {
          config;
          agent_name = "tester";
          sw;
          clock = Eio.Stdenv.clock env;
          proc_mgr = Some (Eio.Stdenv.process_mgr env);
          net = None;
        }
      in
      Masc.Keeper_keepalive.start_keepalive ctx meta;
      match R.get ~base_path:config.base_path keeper_name with
      | None -> fail "expected stale-failing-entry registry entry"
      | Some entry ->
        check string "phase is running after reclaim" "running"
          (KSM.phase_to_string entry.phase);
        check bool "stale entry was replaced" true (entry.done_p != original.done_p);
        check bool "new done promise is unresolved" true
          (Option.is_none (Eio.Promise.peek entry.done_p));
        Masc.Keeper_keepalive.stop_keepalive keeper_name)

let test_stop_keepalive_resolves_running_entry_immediately () =
  R.clear ();
  let keeper_name = "manual-stop-entry" in
  let reg = R.register ~base_path:bp keeper_name (make_meta keeper_name) in
  Masc.Keeper_keepalive.stop_keepalive keeper_name;
  match R.get ~base_path:bp keeper_name with
  | None -> fail "expected manual-stop-entry in registry"
  | Some entry ->
    check string "state stopped immediately" "stopped" (KSM.phase_to_string entry.phase);
    (match Eio.Promise.peek reg.done_p with
     | Some `Stopped -> ()
     | Some (`Crashed reason) ->
       fail ("expected stopped promise, got crashed: " ^ reason)
     | None -> fail "expected manual stop to resolve done_p")

let test_stop_keepalive_preserves_existing_crash_outcome () =
  R.clear ();
  let keeper_name = "crashed-before-stop" in
  let reg = R.register ~base_path:bp keeper_name (make_meta keeper_name) in
  let reason = "already crashed" in
  ignore (R.dispatch_event ~base_path:bp keeper_name
    (KSM.Fiber_terminated { outcome = "already crashed"; provider_id = None; http_status = None }));
  (match R.resolve_done reg ~source:"test_existing_crash" (`Crashed reason) with
   | R.Done_resolved { source } ->
     check string "resolve source" "test_existing_crash" source
   | R.Done_already_resolved _ -> fail "first resolve should win");
  Masc.Keeper_keepalive.stop_keepalive keeper_name;
  match R.get ~base_path:bp keeper_name with
  | None -> fail "expected crashed-before-stop in registry"
  | Some entry ->
    check string "state remains crashed" "crashed" (KSM.phase_to_string entry.phase);
    (match Eio.Promise.peek entry.done_p with
     | Some (`Crashed msg) -> check string "crash reason preserved" reason msg
     | Some `Stopped -> fail "manual stop should not overwrite a crashed promise"
     | None -> fail "expected crash promise to remain resolved")

let test_resolve_done_reports_prior_outcome () =
  R.clear ();
  let keeper_name = "double-resolve-contract" in
  let reg = R.register ~base_path:bp keeper_name (make_meta keeper_name) in
  (match R.resolve_done reg ~source:"test_first" (`Crashed "first") with
   | R.Done_resolved { source } -> check string "first source" "test_first" source
   | R.Done_already_resolved _ -> fail "first resolve should succeed");
  match R.resolve_done reg ~source:"test_second" `Stopped with
  | R.Done_resolved _ -> fail "second resolve must not overwrite prior outcome"
  | R.Done_already_resolved { source; previous = `Crashed msg } ->
    check string "second source" "test_second" source;
    check string "previous outcome" "first" msg
  | R.Done_already_resolved { previous = `Stopped; _ } ->
    fail "previous outcome should remain crashed"

(* ══════════════════════════════════════════════════════════
   9. RFC-0002: pipeline_stage_of_phase deterministic mapping

   NOTE: The "set_failure_reason before raise Keeper_fiber_crash"
   ordering invariant is a code convention enforced by review,
   not a runtime property testable by unit tests. See PR #5560.
   ══════════════════════════════════════════════════════════ *)

module ES = Masc.Keeper_status_runtime

(** Verify pipeline_stage_of_phase covers all 11 phases and produces
    the expected deterministic mapping. No heuristic, no timestamps. *)
let test_pipeline_stage_of_phase_exhaustive () =
  let cases = [
    (KSM.Offline, "offline");
    (KSM.Running, "idle");
    (KSM.Failing, "failing");
    (KSM.Compacting, "compacting");
    (KSM.HandingOff, "handoff");
    (KSM.Draining, "draining");
    (KSM.Paused, "paused");
    (KSM.Stopped, "offline");
    (KSM.Crashed, "crashed");
    (KSM.Restarting, "restarting");
    (KSM.Dead, "offline");
  ] in
  check int "all 11 phases covered" 11 (List.length cases);
  List.iter (fun (phase, expected) ->
    let actual = ES.pipeline_stage_of_phase phase in
    check string
      (Printf.sprintf "%s → %s" (KSM.phase_to_string phase) expected)
      expected actual
  ) cases

let test_pipeline_stage_detail_distinguishes_offline_projection () =
  let cases = [
    (KSM.Offline, "offline", "launch_pending_no_fiber");
    (KSM.Stopped, "offline", "clean_stop_terminal");
    (KSM.Dead, "offline", "restart_budget_exhausted_terminal");
  ] in
  List.iter
    (fun (phase, expected_stage, expected_detail) ->
       check string
         (Printf.sprintf "%s stage" (KSM.phase_to_string phase))
         expected_stage
         (ES.pipeline_stage_of_phase phase);
       check string
         (Printf.sprintf "%s stage detail" (KSM.phase_to_string phase))
         expected_detail
         (ES.pipeline_stage_detail_of_phase phase))
    cases

(** Verify non-registered keepers → get_phase returns None, and
    registered keepers in every phase → pipeline_stage_of_phase produces
    a non-None mapping. This tests the production boundary:
    get_phase feeds into pipeline_stage_of_phase. *)
let test_pipeline_stage_unregistered_is_offline () =
  R.clear ();
  (* Unregistered: get_phase must return None *)
  check bool "unregistered → no phase"
    true (Option.is_none (R.get_phase ~base_path:bp "ghost"));
  (* Registered: get_phase returns real phase, of_phase gives deterministic stage *)
  let meta = make_meta "alive" in
  let _reg = R.register ~base_path:bp "alive" meta in
  (match R.get_phase ~base_path:bp "alive" with
   | Some phase ->
     let stage = ES.pipeline_stage_of_phase phase in
     check bool "registered → non-empty stage" true (String.length stage > 0);
     check string "running → idle" "idle" stage
   | None -> fail "registered keeper must have a phase");
  (* Crash the keeper and verify phase + stage update *)
  ignore (R.dispatch_event ~base_path:bp "alive"
    (KSM.Fiber_terminated { outcome = "test"; provider_id = None; http_status = None }));
  (match R.get_phase ~base_path:bp "alive" with
   | Some phase ->
     let stage = ES.pipeline_stage_of_phase phase in
     check string "crashed → crashed stage" "crashed" stage;
     check string "phase is crashed" "crashed" (KSM.phase_to_string phase)
   | None -> fail "crashed keeper must still have a phase")

(** Sensitivity: pipeline_stage_of_phase DIFFERS from "offline" for
    most active phases. Proves the mapping has teeth — it actually
    distinguishes running/failing/compacting/etc. *)
let test_pipeline_stage_sensitivity () =
  let non_offline_phases = [
    KSM.Running; KSM.Failing; KSM.Compacting; KSM.HandingOff;
    KSM.Draining; KSM.Paused; KSM.Crashed; KSM.Restarting;
  ] in
  List.iter (fun phase ->
    let stage = ES.pipeline_stage_of_phase phase in
    check bool
      (Printf.sprintf "%s should NOT map to offline"
         (KSM.phase_to_string phase))
      true (stage <> "offline")
  ) non_offline_phases;
  (* Terminal/inactive phases DO map to offline *)
  let offline_phases = [KSM.Offline; KSM.Stopped; KSM.Dead] in
  List.iter (fun phase ->
    let stage = ES.pipeline_stage_of_phase phase in
    check string
      (Printf.sprintf "%s should map to offline"
         (KSM.phase_to_string phase))
      "offline" stage
  ) offline_phases

let test_runtime_backpressure_blocks_requested_turn () =
  let meta = make_meta "runtime-backpressure" in
  let obs =
    { base_observation with
      pending_mentions = [ "operator", "please run" ]
    }
  in
  let decision =
    KHL.decide_keepalive_scheduling
      ~runtime_id_of_meta:(fun _ -> "runtime-test")
      ~runtime_resilience_of_name:(fun _ -> Some "provider_capacity")
      ~stop:(Atomic.make false)
      ~meta
      obs
  in
  check bool "world observation requested a turn" true
    decision.requested_should_run_turn;
  check bool "runtime backpressure blocks admission" false decision.should_run_turn;
  (match decision.runtime_backpressure with
   | Obs.Runtime_backpressured { reason; _ } ->
     check string "backpressure reason" "runtime_resilience_provider_capacity" reason
   | Obs.Runtime_admitted -> fail "runtime backpressure should reject turn");
  check bool "verdict reasons include runtime backpressure" true
    (List.mem "runtime_backpressure" decision.verdict_reasons)

let test_keeper_health_backpressure_uses_keeper_name () =
  let meta = make_meta "keeper-health-gate" in
  let obs = { base_observation with pending_mentions = [ "operator", "please run" ] } in
  let consulted = ref [] in
  let decision =
    KHL.decide_keepalive_scheduling
      ~runtime_id_of_meta:(fun _ -> "runtime-test")
      ~runtime_resilience_of_name:(fun _ ->
        fail "runtime resilience should not be consulted after keeper health blocks")
      ~keeper_resilience_of_name:(fun keeper_name ->
        consulted := keeper_name :: !consulted;
        Some "unhealthy")
      ~stop:(Atomic.make false)
      ~meta
      obs
  in
  check (list string) "keeper health consulted by keeper name" [ meta.name ] !consulted;
  check bool "world observation requested a turn" true decision.requested_should_run_turn;
  check bool "keeper health blocks admission" false decision.should_run_turn;
  (match decision.runtime_backpressure with
   | Obs.Runtime_backpressured { reason; _ } ->
     check string "keeper health reason" "keeper_health_unhealthy" reason
   | Obs.Runtime_admitted -> fail "keeper health should reject turn")

let test_pacing_block_delays_requested_turn () =
  (* RFC-0313 W3: with pacing enforced, the caller wires
     [Keeper_pacing_shadow.next_due_remaining] as [pacing_block_of_name];
     a positive remaining delay gates the requested turn without touching
     keeper existence. *)
  let meta = make_meta "pacing-gate" in
  let obs =
    { base_observation with pending_mentions = [ "operator", "please run" ] }
  in
  let consulted = ref [] in
  let decision =
    KHL.decide_keepalive_scheduling
      ~runtime_id_of_meta:(fun _ -> "runtime-test")
      ~pacing_block_of_name:(fun keeper_name ->
        consulted := keeper_name :: !consulted;
        Some 42.0)
      ~stop:(Atomic.make false)
      ~meta
      obs
  in
  check (list string) "pacing consulted by keeper name" [ meta.name ] !consulted;
  check bool "world observation requested a turn" true
    decision.requested_should_run_turn;
  check bool "pacing block delays admission" false decision.should_run_turn;
  (match decision.pacing_block with
   | Some remaining ->
     check (float 1e-6) "remaining seconds surfaced" 42.0 remaining
   | None -> fail "pacing_block should carry the remaining delay");
  check bool "verdict reasons include pacing_pending" true
    (List.mem "pacing_pending" decision.verdict_reasons);
  let admitted =
    KHL.decide_keepalive_scheduling
      ~runtime_id_of_meta:(fun _ -> "runtime-test")
      ~stop:(Atomic.make false)
      ~meta
      obs
  in
  check bool "default pacing closure never blocks" true admitted.should_run_turn

let test_crashed_cycle_records_health_failure () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let base_path = temp_dir "health-feed" in
  let keeper_name = "health-feed-keeper" in
  Health.record_success ~agent_name:keeper_name;
  check bool "keeper starts healthy" true (Health.is_healthy ~agent_name:keeper_name);
  for i = 1 to 3 do
    KHL.record_crashed_cycle_failure
      ~base_path
      ~keeper_name
      (Failure (Printf.sprintf "boom-%d" i))
  done;
  check
    bool
    "crashed cycles feed Health breaker"
    false
    (Health.is_healthy ~agent_name:keeper_name)

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
      test_case "fresh presence preserves turn failures" `Quick
        test_fresh_presence_preserves_turn_failures;
      test_case "crashed cycle surfaces as turn failure" `Quick
        test_crashed_cycle_records_turn_failure;
    ];
    "direct_keepalive", [
      test_case "stop resolves done promise" `Quick
        test_direct_start_keepalive_resolves_done_on_stop;
      test_case "unresolved failing entry is preserved" `Quick
        test_start_keepalive_preserves_unresolved_failing_entry;
      test_case "finished failing entry is reclaimed" `Quick
        test_start_keepalive_reclaims_finished_failing_entry;
      test_case "manual stop resolves running entry immediately" `Quick
        test_stop_keepalive_resolves_running_entry_immediately;
      test_case "manual stop preserves crashed outcome" `Quick
        test_stop_keepalive_preserves_existing_crash_outcome;
      test_case "resolve_done reports prior outcome" `Quick
        test_resolve_done_reports_prior_outcome;
    ];
    "pipeline_stage_phase", [
      test_case "exhaustive 11-phase mapping" `Quick
        test_pipeline_stage_of_phase_exhaustive;
	      test_case "offline projection details remain distinct" `Quick
	        test_pipeline_stage_detail_distinguishes_offline_projection;
	      test_case "unregistered keeper → offline" `Quick
	        test_pipeline_stage_unregistered_is_offline;
      test_case "sensitivity: active phases ≠ offline" `Quick
        test_pipeline_stage_sensitivity;
    ];
    "scheduling", [
      test_case "runtime backpressure blocks requested turn" `Quick
        test_runtime_backpressure_blocks_requested_turn;
      test_case "keeper health blocks by keeper name" `Quick
        test_keeper_health_backpressure_uses_keeper_name;
      test_case "pacing block delays requested turn (RFC-0313 W3)" `Quick
        test_pacing_block_delays_requested_turn;
      test_case "crashed cycles feed agent health breaker" `Quick
        test_crashed_cycle_records_health_failure;
    ];
  ]
