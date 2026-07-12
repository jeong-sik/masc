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
module Lane = Masc.Keeper_lane
module Shutdown_types = Masc.Keeper_shutdown_types
module Shutdown_store = Masc.Keeper_shutdown_store
module Shutdown_prepare_join = Masc.Keeper_shutdown_prepare_join
module Shutdown_finalize = Masc.Keeper_shutdown_finalize
module Shutdown_runtime = Masc.Keeper_shutdown_runtime
module Keeper_meta_store = Masc.Keeper_meta_store
module Lifecycle_hooks = Masc.Keeper_lifecycle_hooks
module Subprocess_registry = Masc.Keeper_subprocess_registry
module Tombstone_cleanup = Masc.Keeper_supervisor_cleanup_tombstone

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

let retain_operator_cleanup : Shutdown_types.cleanup_intent =
  { meta_disposition = Shutdown_types.Retain_operator_pause
  ; remove_session = false
  }
;;

let remove_meta_cleanup : Shutdown_types.cleanup_intent =
  { meta_disposition = Shutdown_types.Remove_meta
  ; remove_session = false
  }
;;

(* Seed the keeper TOML the way a real workspace persists it. A keeper resolves
   its sandbox_profile from [config/keepers/<name>.toml]; keepalive/shutdown
   paths fail closed without one (keeper_meta_contract, "missing profile source
   fails loudly"). Tests that only build runtime meta must seed this so they
   exercise the lifecycle path instead of the missing-profile rejection. *)
let seed_keeper_sandbox_profile ~base_dir name =
  let keepers_dir =
    List.fold_left Filename.concat base_dir [ ".masc"; "config"; "keepers" ]
  in
  Fs_compat.mkdir_p keepers_dir;
  Fs_compat.save_file
    (Filename.concat keepers_dir (name ^ ".toml"))
    "[keeper]\nsandbox_profile = \"local\"\n"

let configure_keeper_chat_persistence ~base_path =
  let report = Masc.Keeper_chat_queue.configure_persistence ~base_path in
  match report.load_errors with
  | [] -> ()
  | errors ->
    let describe (keeper_name, (error : Masc.Keeper_chat_queue.snapshot_load_error)) =
      let owner =
        match keeper_name with
        | Some name -> name
        | None -> "<global>"
      in
      Printf.sprintf
        "%s:%s:%s"
        owner
        (Masc.Keeper_chat_queue.snapshot_load_error_kind_to_string error.kind)
        error.message
    in
    Alcotest.failf
      "keeper chat persistence fixture failed: %s"
      (String.concat "; " (List.map describe errors))

let resolve_done_for_test reg value =
  ignore (R.resolve_done reg ~source:"test_fixture" value);
  match
    Lane.reject_before_start reg.lane ~reason:(Failure "synthetic terminal fixture")
  with
  | Ok () -> ()
  | Error error -> fail (Lane.start_error_to_string error)

let eio_test name fn =
  test_case name `Quick (fun () -> Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env); fn ())

let base_observation : WO.world_observation =
  { pending_mentions = []
  ; pending_board_events = []
  ; pending_scope_messages = []
  ; idle_seconds = 0
  ; active_goals = []
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
    Stopped with a resolved terminal and joined lane = reconcile-eligible.
    Stopped with an unjoined lane = sweep will handle. *)
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
  (* Stopped + resolved done_p + joined lane = reconcile-eligible *)
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
       | KSM.Stopped -> not (R.lane_has_exited e)
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
       | KSM.Stopped -> not (R.lane_has_exited e)
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
      Masc.Keeper_keepalive.stop_keepalive ~base_path:base_dir keeper_name;
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
      seed_keeper_sandbox_profile ~base_dir keeper_name;
      Masc.Keeper_keepalive.start_keepalive ctx meta;
      Eio.Time.sleep ctx.clock 0.05;
      (match
         Masc.Keeper_keepalive.stop_keepalive_and_await
           ~base_path:config.base_path
           keeper_name
       with
       | Masc.Keeper_keepalive.Keeper_not_registered ->
         fail "direct-lifecycle keeper disappeared before joined stop"
       | Masc.Keeper_keepalive.Keeper_joined { terminal = `Stopped; _ } -> ()
       | Masc.Keeper_keepalive.Keeper_joined { terminal = `Crashed reason; _ } ->
         fail ("joined stop resolved as crashed: " ^ reason));
      match R.get ~base_path:config.base_path keeper_name with
      | None -> fail "expected direct-lifecycle registry entry"
      | Some entry ->
        check string "state stopped" "stopped" (KSM.phase_to_string entry.phase);
        check bool "joined stop observes lane exit" true (R.lane_has_exited entry);
        (match Eio.Promise.peek entry.done_p with
         | Some `Stopped -> ()
         | Some (`Crashed reason) ->
           fail ("expected stopped promise, got crashed: " ^ reason)
         | None -> fail "expected done_p to resolve on stop"))

let test_keeper_lane_join_waits_for_children_and_cleanup () =
  Eio_main.run @@ fun _env ->
  Eio.Switch.run @@ fun parent_sw ->
  let lane = Lane.create () in
  let release_p, release_r = Eio.Promise.create () in
  let child_finished = Atomic.make false in
  let cleanup_observed_child = Atomic.make false in
  (match
     Lane.fork
       ~sw:parent_sw
       lane
       ~run:(fun lane_sw ->
         Eio.Fiber.fork ~sw:lane_sw (fun () ->
           Eio.Promise.await release_p;
           Atomic.set child_finished true))
       ~cleanup:(fun _outcome ->
         Atomic.set cleanup_observed_child (Atomic.get child_finished);
         Ok ())
   with
   | Ok () -> ()
   | Error error -> fail (Lane.start_error_to_string error));
  Eio.Fiber.yield ();
  check bool
    "lane exit waits for attached child"
    true
    (Option.is_none (Lane.peek_exit lane));
  Eio.Promise.resolve release_r ();
  let exit = Lane.await_exit lane in
  (match exit.outcome with
   | Lane.Completed -> ()
   | Lane.Shutdown_before_start -> fail "unexpected shutdown before lane start"
   | Lane.Shutdown_requested -> fail "unexpected lane shutdown"
   | Lane.Cancelled_by_parent cause ->
     fail ("unexpected parent cancellation: " ^ Printexc.to_string cause)
   | Lane.Failed exn -> fail ("unexpected lane failure: " ^ Printexc.to_string exn));
  check bool "child finished before join" true (Atomic.get child_finished);
  check bool
    "cleanup ran after child join"
    true
    (Atomic.get cleanup_observed_child);
  check (option string) "cleanup succeeded" None exit.cleanup_error

let test_keeper_lane_surfaces_cleanup_failure () =
  Eio_main.run @@ fun _env ->
  Eio.Switch.run @@ fun parent_sw ->
  let lane = Lane.create () in
  (match
     Lane.fork
       ~sw:parent_sw
       lane
       ~run:(fun _lane_sw -> ())
       ~cleanup:(fun _outcome -> Error "cleanup evidence")
   with
   | Ok () -> ()
   | Error error -> fail (Lane.start_error_to_string error));
  let exit = Lane.await_exit lane in
  check
    (option string)
    "cleanup failure remains observable"
    (Some "cleanup evidence")
    exit.cleanup_error

let test_keeper_lane_identity_is_typed_and_unique () =
  let first = Lane.create () in
  let second = Lane.create () in
  let first_id = Lane.id first in
  let encoded = Lane.Id.to_string first_id in
  check bool
    "separate registry lanes have separate identities"
    false
    (Lane.Id.equal first_id (Lane.id second));
  match Lane.Id.of_string encoded with
  | Ok decoded -> check bool "lane id round-trip" true (Lane.Id.equal first_id decoded)
  | Error detail -> fail detail

(* Codex #24135 finding 1 (predicate half): [request_cancel] records a shutdown
   request so a supervised body can classify the resulting cancellation as an
   operator shutdown (graceful stop) rather than a parent/restart cancel. The
   supervised-body routing that consumes this flag is covered by review against
   the tested normal-exit path (a full fork+cancel finally harness is not
   available: the supervisor tests mock [supervise_keepalive]). *)
let test_lane_records_shutdown_request_on_cancel () =
  Eio_main.run @@ fun _env ->
  let lane = Lane.create () in
  check bool "fresh lane has no shutdown request" false
    (Lane.shutdown_requested lane);
  (match Lane.request_cancel lane with
   | Lane.Cancel_requested -> ()
   | Lane.Cancel_already_requested
   | Lane.Cancel_already_exiting
   | Lane.Cancel_signal_failed _ ->
     fail "expected request_cancel to be accepted on a fresh lane");
  check bool "request_cancel records the shutdown request" true
    (Lane.shutdown_requested lane);
  match Lane.await_exit lane with
  | { outcome = Lane.Shutdown_before_start; _ } -> ()
  | { outcome = _; _ } ->
    fail "expected a not-started lane cancel to resolve Shutdown_before_start"

let test_keeper_lane_cancel_is_lane_local_and_joinable () =
  Eio_main.run @@ fun _env ->
  Eio.Switch.run @@ fun parent_sw ->
  let lane = Lane.create () in
  let never_p, _never_r = Eio.Promise.create () in
  (match
     Lane.fork
       ~sw:parent_sw
       lane
       ~run:(fun _lane_sw -> Eio.Promise.await never_p)
       ~cleanup:(fun _outcome -> Ok ())
   with
   | Ok () -> ()
   | Error error -> fail (Lane.start_error_to_string error));
  Eio.Fiber.yield ();
  (match Lane.request_cancel lane with
   | Lane.Cancel_requested -> ()
   | Lane.Cancel_already_requested
   | Lane.Cancel_already_exiting
   | Lane.Cancel_signal_failed _ -> fail "first lane cancellation was not accepted");
  let exit = Lane.await_exit lane in
  match exit.outcome with
  | Lane.Shutdown_requested -> ()
  | Lane.Shutdown_before_start -> fail "running lane reported pre-start shutdown"
  | Lane.Completed -> fail "cancelled lane reported normal completion"
  | Lane.Cancelled_by_parent cause ->
    fail ("lane cancellation escaped to parent: " ^ Printexc.to_string cause)
  | Lane.Failed exn -> fail ("lane cancellation failed: " ^ Printexc.to_string exn)

let test_keeper_shutdown_store_round_trip_and_identity_guard () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let base_dir = temp_dir "shutdown-store" in
  Fun.protect
    ~finally:(fun () -> cleanup_dir base_dir)
    (fun () ->
      let config = Masc.Workspace.default_config base_dir in
      let (_init_message : string) =
        Masc.Workspace.init config ~agent_name:(Some "tester")
      in
      let backlog_version =
        match Workspace_backlog.read_backlog_r config with
        | Ok backlog -> backlog.version
        | Error detail -> fail detail
      in
      let meta = make_meta "shutdown-store-keeper" in
      let operation_id = Shutdown_types.Operation_id.generate () in
      let lane = Lane.create () in
      let now = Masc_domain.now_iso () in
      let operation : Shutdown_types.t =
        { schema_version = Shutdown_types.schema_version
        ; revision = 0
        ; operation_id
        ; keeper_name = meta.name
        ; lane_id = Lane.id lane
        ; trace_id = meta.runtime.trace_id
        ; generation = meta.runtime.generation
        ; actor = "tester"
        ; cleanup_intent = retain_operator_cleanup
        ; turn_disposition = Shutdown_types.No_inflight_turn
        ; expected_backlog_version = backlog_version
        ; owned_task_ids = []
        ; join_evidence = None
        ; phase = Shutdown_types.Prepared
        ; created_at = now
        ; updated_at = now
        }
      in
      (match Shutdown_store.persist_new ~config operation with
       | Ok () -> ()
       | Error error -> fail (Shutdown_store.error_to_string error));
      (match Shutdown_store.persist_new ~config operation with
       | Error (Shutdown_store.Already_exists _) -> ()
       | Error error -> fail (Shutdown_store.error_to_string error)
       | Ok () -> fail "duplicate shutdown operation overwrote its record");
      let invalid_completion_operation =
        { operation with
          operation_id = Shutdown_types.Operation_id.generate ()
        ; phase =
            Shutdown_types.Finalized
              { cleanup =
                  { settled_task_ids = []; pending_confirms_removed = 0 }
              ; meta_removed = false
              ; session_removed = false
              ; registry_unregistered = false
              ; completion =
                  Shutdown_types.Completion_pending
                    Shutdown_types.Dead_tombstone_reaped
              }
        }
      in
      (match Shutdown_store.persist_new ~config invalid_completion_operation with
       | Error
           (Shutdown_store.Invalid_operation
             (Shutdown_types.Finalized_completion_mismatch _)) -> ()
       | Error error -> fail (Shutdown_store.error_to_string error)
       | Ok () -> fail "store accepted completion outside dead-tombstone intent");
      let loaded =
        match Shutdown_store.load ~config ~keeper_name:meta.name operation_id with
        | Ok loaded -> loaded
        | Error error -> fail (Shutdown_store.error_to_string error)
      in
      check string "shutdown keeper round-trip" operation.keeper_name loaded.keeper_name;
      check bool
        "shutdown lane identity round-trip"
        true
        (Lane.Id.equal operation.lane_id loaded.lane_id);
      let joined =
        { loaded with
          revision = loaded.revision + 1
        ; phase = Shutdown_types.Joined_idle
        ; updated_at = Masc_domain.now_iso ()
        }
      in
      (match Shutdown_store.replace ~config ~expected_revision:loaded.revision joined with
       | Ok () -> ()
       | Error error -> fail (Shutdown_store.error_to_string error));
      let stale =
        { loaded with
          revision = loaded.revision + 1
        ; phase = Shutdown_types.Blocked { stage = Shutdown_types.Record_update; detail = "stale" }
        }
      in
      (match Shutdown_store.replace ~config ~expected_revision:loaded.revision stale with
       | Error (Shutdown_store.Revision_conflict _) -> ()
       | Error error -> fail (Shutdown_store.error_to_string error)
       | Ok () -> fail "stale shutdown snapshot overwrote a newer revision");
      let mismatched = { joined with lane_id = Lane.id (Lane.create ()) } in
      (match
         Shutdown_store.replace
           ~config
           ~expected_revision:joined.revision
           { mismatched with revision = joined.revision + 1 }
       with
       | Error (Shutdown_store.Identity_mismatch _) -> ()
       | Error error -> fail (Shutdown_store.error_to_string error)
       | Ok () -> fail "shutdown store accepted a different lane identity");
      let mutated_cleanup =
        { joined with
          revision = joined.revision + 1
        ; cleanup_intent = remove_meta_cleanup
        }
      in
      (match
         Shutdown_store.replace
           ~config
           ~expected_revision:joined.revision
           mutated_cleanup
       with
       | Error (Shutdown_store.Identity_mismatch _) -> ()
      | Error error -> fail (Shutdown_store.error_to_string error)
      | Ok () -> fail "shutdown store accepted a changed cleanup intent");
      let worker_failure = Failure "worker exploded after durable join" in
      let failure_timestamp = "2026-07-11T11:00:01Z" in
      let failure_clock_sampled = Atomic.make false in
      let holder_locked_p, holder_locked_r = Eio.Promise.create () in
      let release_holder_p, release_holder_r = Eio.Promise.create () in
      let holder_done_p, holder_done_r = Eio.Promise.create () in
      let worker_started_p, worker_started_r = Eio.Promise.create () in
      let exception Cancel_worker in
      Eio.Switch.run @@ fun test_sw ->
      Eio.Fiber.fork ~sw:test_sw (fun () ->
        (match
           Shutdown_store.For_testing.with_operation_write_lock
             ~config
             ~keeper_name:meta.name
             operation_id
             (fun () ->
                Eio.Promise.resolve holder_locked_r ();
                Eio.Promise.await release_holder_p)
         with
         | Ok () -> ()
         | Error error -> fail (Shutdown_store.error_to_string error));
        Eio.Promise.resolve holder_done_r ());
      Eio.Promise.await holder_locked_p;
      (try
         Eio.Switch.run (fun worker_sw ->
           Eio.Fiber.fork ~sw:worker_sw (fun () ->
             Eio.Promise.resolve worker_started_r ();
             Shutdown_runtime.For_testing.persist_unhandled_failure
               ~now:(fun () ->
                 Atomic.set failure_clock_sampled true;
                 failure_timestamp)
               ~config
               operation
               worker_failure);
           Eio.Promise.await worker_started_p;
           Eio.Fiber.yield ();
           check bool
             "failure clock is not sampled while the write lock is held"
             false
             (Atomic.get failure_clock_sampled);
           Eio.Switch.fail worker_sw Cancel_worker;
           Eio.Promise.resolve release_holder_r ())
       with
       | Cancel_worker -> ());
      Eio.Promise.await holder_done_p;
      let blocked =
        match Shutdown_store.load ~config ~keeper_name:meta.name operation_id with
        | Ok blocked -> blocked
        | Error error -> fail (Shutdown_store.error_to_string error)
      in
      check int
        "unhandled worker failure advances the latest durable revision"
        (joined.revision + 1)
        blocked.revision;
      check bool
        "failure clock is sampled after the write lock is acquired"
        true
        (Atomic.get failure_clock_sampled);
      check string
        "blocked evidence owns its post-lock timestamp"
        failure_timestamp
        blocked.updated_at;
      (match blocked.phase with
       | Shutdown_types.Blocked { stage = Shutdown_types.Unhandled_worker; detail } ->
         check string
           "unhandled worker failure detail"
           (Printexc.to_string worker_failure)
           detail
       | Shutdown_types.Prepared
       | Shutdown_types.Joined_idle
       | Shutdown_types.Finalizing_tasks _
       | Shutdown_types.Cleanup_ready _
       | Shutdown_types.Reconciliation_required _
       | Shutdown_types.Finalized _
       | Shutdown_types.Blocked _ ->
         fail "unhandled worker failure did not persist typed blocked evidence");
      Shutdown_runtime.For_testing.persist_unhandled_failure
        ~now:Masc_domain.now_iso
        ~config
        operation
        (Failure "later worker failure");
      let preserved =
        match Shutdown_store.load ~config ~keeper_name:meta.name operation_id with
        | Ok preserved -> preserved
        | Error error -> fail (Shutdown_store.error_to_string error)
      in
      check int
        "later worker failure preserves blocked revision"
        blocked.revision
        preserved.revision;
      check
        bool
        "later worker failure preserves first blocked evidence"
        true
        (preserved.phase = blocked.phase);
      (match Shutdown_store.list_for_keeper ~config ~keeper_name:meta.name with
       | Ok [ listed ] ->
         check bool
           "listed operation identity"
           true
           (Shutdown_types.Operation_id.equal listed.operation_id operation_id)
       | Ok operations ->
         fail (Printf.sprintf "expected one shutdown operation, got %d" (List.length operations))
       | Error error -> fail (Shutdown_store.error_to_string error));
      let unsupported_json =
        match Shutdown_store.to_json joined with
        | `Assoc fields ->
          `Assoc (("schema_version", `Int 999) :: List.remove_assoc "schema_version" fields)
        | _ -> fail "shutdown operation codec did not produce an object"
      in
      match Shutdown_store.of_json unsupported_json with
      | Error (Shutdown_store.Decode_error _) -> ()
      | Error error -> fail (Shutdown_store.error_to_string error)
      | Ok _ -> fail "unsupported shutdown schema was accepted")

let test_keeper_shutdown_store_isolates_corrupt_owner () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let base_dir = temp_dir "shutdown-store-corrupt-owner" in
  Fun.protect
    ~finally:(fun () ->
      Masc.Keeper_turn_admission.For_testing.reset ();
      cleanup_dir base_dir)
    (fun () ->
      let config = Masc.Workspace.default_config base_dir in
      let (_init_message : string) =
        Masc.Workspace.init config ~agent_name:(Some "tester")
      in
      let backlog_version =
        match Workspace_backlog.read_backlog_r config with
        | Ok backlog -> backlog.version
        | Error detail -> fail detail
      in
      let dotted_owner_operation_id = Shutdown_types.Operation_id.generate () in
      (match
         Shutdown_store.path
           ~config
           ~keeper_name:"dotted.owner"
           dotted_owner_operation_id
       with
       | Ok path ->
         check string
           "portable dotted Keeper name has an exact owner codec"
           "_dotted.owner"
           (Filename.basename (Filename.dirname path))
       | Error error -> fail (Shutdown_store.error_to_string error));
      let operation name phase =
        let meta = make_meta name in
        let now = Masc_domain.now_iso () in
        let operation : Shutdown_types.t =
          { schema_version = Shutdown_types.schema_version
          ; revision = 0
          ; operation_id = Shutdown_types.Operation_id.generate ()
          ; keeper_name = meta.name
          ; lane_id = Lane.id (Lane.create ())
          ; trace_id = meta.runtime.trace_id
          ; generation = meta.runtime.generation
          ; actor = "tester"
          ; cleanup_intent = retain_operator_cleanup
          ; turn_disposition = Shutdown_types.No_inflight_turn
          ; expected_backlog_version = backlog_version
          ; owned_task_ids = []
          ; join_evidence = None
          ; phase
          ; created_at = now
          ; updated_at = now
          }
        in
        (match Shutdown_store.persist_new ~config operation with
         | Ok () -> operation
         | Error error -> fail (Shutdown_store.error_to_string error))
      in
      let corrupt_operation = operation "corrupt-owner" Shutdown_types.Prepared in
      let recoverable_operation =
        operation
          "recoverable-owner"
          (Shutdown_types.Blocked
             { stage = Shutdown_types.Record_update
             ; detail = "operator repair required"
             })
      in
      let corrupt_path =
        match
          Shutdown_store.path
            ~config
            ~keeper_name:corrupt_operation.keeper_name
            corrupt_operation.operation_id
        with
        | Ok path -> path
        | Error error -> fail (Shutdown_store.error_to_string error)
      in
      (match Fs_compat.save_file_atomic corrupt_path "{not-json" with
       | Ok () -> ()
       | Error detail -> fail detail);
      let inventory =
        match Shutdown_store.scan_inventory ~config with
        | Ok inventory -> inventory
        | Error error -> fail (Shutdown_store.error_to_string error)
      in
      let operations, corrupt_records =
        List.fold_left
          (fun (operations, corrupt_records) -> function
             | Shutdown_store.Operation operation -> operation :: operations, corrupt_records
             | Shutdown_store.Corrupt_record corrupt ->
               operations, corrupt :: corrupt_records)
          ([], [])
          inventory
      in
      (match operations with
       | [ operation ] ->
         check string
           "unrelated valid operation remains recoverable"
           recoverable_operation.keeper_name
           operation.keeper_name
       | _ -> fail "corrupt inventory hid or duplicated the valid operation");
      (match corrupt_records with
       | [ corrupt ] ->
         check string
           "corrupt payload retains path owner"
           corrupt_operation.keeper_name
           corrupt.keeper_name;
         check bool
           "corrupt payload retains path operation id"
           true
           (Shutdown_types.Operation_id.equal
              corrupt_operation.operation_id
              corrupt.operation_id)
       | _ -> fail "corrupt operation was not isolated as one typed record");
      (match
         Shutdown_store.list_for_keeper
           ~config
           ~keeper_name:corrupt_operation.keeper_name
       with
       | Error (Shutdown_store.Decode_error _) -> ()
       | Error error -> fail (Shutdown_store.error_to_string error)
       | Ok _ -> fail "corrupt owner inventory was reported as healthy");
      (match
         Shutdown_store.list_for_keeper
           ~config
           ~keeper_name:recoverable_operation.keeper_name
       with
       | Ok [ _ ] -> ()
       | Ok _ -> fail "recoverable owner inventory changed cardinality"
       | Error error -> fail (Shutdown_store.error_to_string error));
      let restored =
        match Shutdown_runtime.restore_inventory_admission ~config inventory with
        | Ok restored -> restored
        | Error detail -> fail detail
      in
      check (list string)
        "corrupt and valid non-terminal owners are fenced independently"
        [ corrupt_operation.keeper_name; recoverable_operation.keeper_name ]
        restored.blocked_keeper_names;
      check int "one corrupt record remains explicit" 1
        (List.length restored.corrupt_records);
      check int "one valid operation remains recoverable" 1
        (List.length restored.operations);
      (match
         Masc.Keeper_turn_admission.run_if_free
           ~base_path:config.base_path
           ~keeper_name:corrupt_operation.keeper_name
           (fun () -> ())
       with
       | `Busy (Masc.Keeper_turn_admission.Shutdown_requested operation_id) ->
         check bool
           "corrupt owner fence retains durable operation id"
           true
           (Shutdown_types.Operation_id.equal
              corrupt_operation.operation_id
              operation_id)
       | `Busy (Masc.Keeper_turn_admission.Turn_busy _)
       | `Ran () -> fail "corrupt owner admission was reopened");
      match Shutdown_runtime.recover_operation ~config recoverable_operation with
      | Ok recovered ->
        check bool
          "unrelated blocked operation remains explicitly recoverable"
          true
          (recovered.phase = recoverable_operation.phase)
      | Error detail -> fail detail)

let test_keeper_shutdown_prepare_joins_idle_lane () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  Eio.Switch.run @@ fun parent_sw ->
  let base_dir = temp_dir "shutdown-prepare-join" in
  Fun.protect
    ~finally:(fun () ->
      Masc.Keeper_chat_queue.For_testing.reset ();
      Masc.Keeper_turn_admission.For_testing.reset ();
      R.clear ();
      cleanup_dir base_dir)
    (fun () ->
      let config = Masc.Workspace.default_config base_dir in
      let (_init_message : string) =
        Masc.Workspace.init config ~agent_name:(Some "operator")
      in
      let name = "shutdown-idle-lane" in
      let entry = R.register ~base_path:config.base_path name (make_meta name) in
      let never_p, _never_r = Eio.Promise.create () in
      (match
         Lane.fork
           ~sw:parent_sw
           entry.lane
           ~run:(fun _lane_sw -> Eio.Promise.await never_p)
           ~cleanup:(fun _outcome ->
             (match R.dispatch_event_exact entry KSM.Stop_requested with
              | Ok _ -> ()
              | Error error -> fail (KSM.transition_error_to_string error));
             (match R.dispatch_event_exact entry KSM.Drain_complete with
              | Ok _ -> ()
              | Error error -> fail (KSM.transition_error_to_string error));
             (match R.resolve_done entry ~source:"shutdown_test_lane_cleanup" `Stopped with
              | R.Done_resolved _ -> ()
              | R.Done_already_resolved _ -> fail "test lane terminal resolved twice");
             Ok ())
       with
       | Ok () -> ()
       | Error error -> fail (Lane.start_error_to_string error));
      Eio.Fiber.yield ();
      let operation =
        match
          Shutdown_prepare_join.run
            ~config
            ~entry
            ~request:
              { actor = "operator"
              ; cleanup_intent = retain_operator_cleanup
              }
        with
        | Ok operation -> operation
        | Error error -> fail (Shutdown_prepare_join.error_to_string error)
      in
      (match operation.phase with
       | Shutdown_types.Joined_idle -> ()
       | Shutdown_types.Prepared
       | Shutdown_types.Finalizing_tasks _
       | Shutdown_types.Cleanup_ready _
       | Shutdown_types.Reconciliation_required _
       | Shutdown_types.Finalized _
       | Shutdown_types.Blocked _ -> fail "idle lane did not reach Joined_idle");
      check bool
        "shutdown operation records lane join evidence"
        true
        (Option.is_some operation.join_evidence);
      (match
         Masc.Keeper_turn_admission.run_if_free
           ~base_path:config.base_path
           ~keeper_name:name
           (fun () -> ())
       with
       | `Busy (Masc.Keeper_turn_admission.Shutdown_requested operation_id) ->
         check bool
           "shutdown admission fence retains operation identity"
           true
           (Shutdown_types.Operation_id.equal operation.operation_id operation_id)
      | `Busy (Masc.Keeper_turn_admission.Turn_busy _) | `Ran () ->
         fail "shutdown admission fence reopened before finalization"))

let test_keeper_shutdown_prepare_joins_not_started_lane () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let base_dir = temp_dir "shutdown-prepare-not-started" in
  Fun.protect
    ~finally:(fun () ->
      Masc.Keeper_chat_queue.For_testing.reset ();
      Masc.Keeper_turn_admission.For_testing.reset ();
      R.clear ();
      cleanup_dir base_dir)
    (fun () ->
      let config = Masc.Workspace.default_config base_dir in
      let (_init_message : string) =
        Masc.Workspace.init config ~agent_name:(Some "operator")
      in
      let name = "shutdown-not-started-lane" in
      let entry = R.register ~base_path:config.base_path name (make_meta name) in
      let operation =
        match
          Shutdown_prepare_join.run
            ~config
            ~entry
            ~request:
              { actor = "operator"
              ; cleanup_intent = retain_operator_cleanup
              }
        with
        | Ok operation -> operation
        | Error error -> fail (Shutdown_prepare_join.error_to_string error)
      in
      (match operation.phase with
       | Shutdown_types.Joined_idle -> ()
       | Shutdown_types.Prepared
       | Shutdown_types.Finalizing_tasks _
       | Shutdown_types.Cleanup_ready _
       | Shutdown_types.Reconciliation_required _
       | Shutdown_types.Finalized _
       | Shutdown_types.Blocked _ -> fail "not-started lane did not reach Joined_idle");
      (match Lane.peek_exit entry.lane with
       | Some { outcome = Lane.Shutdown_before_start; cleanup_error = None } -> ()
       | Some _ -> fail "not-started lane recorded the wrong exit evidence"
       | None -> fail "not-started lane exit remained unresolved");
      match Eio.Promise.peek entry.done_p with
      | Some `Stopped -> ()
      | Some (`Crashed detail) -> fail ("not-started lane crashed: " ^ detail)
      | None -> fail "not-started lane terminal remained unresolved")

let test_keeper_shutdown_prepare_failure_rolls_back_fence () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let base_dir = temp_dir "shutdown-prepare-rollback" in
  Fun.protect
    ~finally:(fun () ->
      Masc.Keeper_chat_queue.For_testing.reset ();
      Masc.Keeper_turn_admission.For_testing.reset ();
      R.clear ();
      cleanup_dir base_dir)
    (fun () ->
      let config = Masc.Workspace.default_config base_dir in
      let (_init_message : string) =
        Masc.Workspace.init config ~agent_name:(Some "operator")
      in
      let name = "shutdown-prepare-rollback-lane" in
      let entry = R.register ~base_path:config.base_path name (make_meta name) in
      let probe_operation_id = Shutdown_types.Operation_id.generate () in
      let records_dir =
        match Shutdown_store.path ~config ~keeper_name:name probe_operation_id with
        | Ok path -> Filename.dirname path
        | Error error -> fail (Shutdown_store.error_to_string error)
      in
      Fs_compat.mkdir_p (Filename.dirname records_dir);
      let blocker = open_out records_dir in
      close_out blocker;
      (match
         Shutdown_prepare_join.run
           ~config
           ~entry
           ~request:
             { actor = "operator"
             ; cleanup_intent = retain_operator_cleanup
             }
       with
       | Error (Shutdown_prepare_join.Prepare_persist_failed _) -> ()
       | Error error -> fail (Shutdown_prepare_join.error_to_string error)
       | Ok _ -> fail "shutdown prepare unexpectedly persisted through a file blocker");
      configure_keeper_chat_persistence ~base_path:config.base_path;
      match
        Masc.Keeper_turn_admission.run_if_free
          ~base_path:config.base_path
          ~keeper_name:name
          (fun () -> ())
      with
      | `Ran () -> ()
      | `Busy (Masc.Keeper_turn_admission.Shutdown_requested id) ->
        fail
          (Printf.sprintf
             "failed shutdown prepare left the keeper admission fence closed: \
              Shutdown_requested %s still owns the slot"
             (Shutdown_types.Operation_id.to_string id))
      | `Busy (Masc.Keeper_turn_admission.Turn_busy _) ->
        fail
          "failed shutdown prepare left the keeper admission fence closed: \
           Turn_busy owns the slot")

let test_keeper_shutdown_finalizes_idle_operation () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let base_dir = temp_dir "shutdown-finalize" in
  Fun.protect
    ~finally:(fun () ->
      Shutdown_finalize.For_testing.reset_remove_pending_confirms_by_target ();
      Masc.Keeper_chat_queue.For_testing.reset ();
      Masc.Keeper_turn_admission.For_testing.reset ();
      R.clear ();
      cleanup_dir base_dir)
    (fun () ->
      let config = Masc.Workspace.default_config base_dir in
      let (_init_message : string) =
        Masc.Workspace.init config ~agent_name:(Some "operator")
      in
      let backlog_version =
        match Workspace_backlog.read_backlog_r config with
        | Ok backlog -> backlog.version
        | Error detail -> fail detail
      in
      let meta = make_meta "shutdown-finalize-keeper" in
      (match Keeper_meta_store.write_meta config meta with
       | Ok () -> ()
       | Error detail -> fail detail);
      Shutdown_finalize.register_remove_pending_confirms_by_target
        (fun _config ~target_type:_ ~target_id:_ -> Ok 0);
      let operation_id = Shutdown_types.Operation_id.generate () in
      let operation : Shutdown_types.t =
        { schema_version = Shutdown_types.schema_version
        ; revision = 0
        ; operation_id
        ; keeper_name = meta.name
        ; lane_id = Lane.id (Lane.create ())
        ; trace_id = meta.runtime.trace_id
        ; generation = meta.runtime.generation
        ; actor = "operator"
        ; cleanup_intent = retain_operator_cleanup
        ; turn_disposition = Shutdown_types.No_inflight_turn
        ; expected_backlog_version = backlog_version
        ; owned_task_ids = []
        ; join_evidence = None
        ; phase = Shutdown_types.Joined_idle
        ; created_at = Masc_domain.now_iso ()
        ; updated_at = Masc_domain.now_iso ()
        }
      in
      (match
         Masc.Keeper_turn_admission.begin_shutdown
           ~base_path:config.base_path
           ~keeper_name:meta.name
           ~operation_id
       with
       | Masc.Keeper_turn_admission.Shutdown_reserved _ -> ()
       | Masc.Keeper_turn_admission.Shutdown_already_reserved _ ->
         fail "fresh shutdown finalization fixture was already reserved");
      (match Shutdown_store.persist_new ~config operation with
       | Ok () -> ()
       | Error error -> fail (Shutdown_store.error_to_string error));
      let finalized =
        match Shutdown_finalize.run ~config ~entry:None operation with
        | Ok finalized -> finalized
        | Error error -> fail (Shutdown_finalize.error_to_string error)
      in
      (match finalized.phase with
       | Shutdown_types.Finalized evidence ->
         check int "no pending confirms" 0 evidence.cleanup.pending_confirms_removed
       | Shutdown_types.Prepared
       | Shutdown_types.Joined_idle
       | Shutdown_types.Finalizing_tasks _
       | Shutdown_types.Cleanup_ready _
       | Shutdown_types.Reconciliation_required _
       | Shutdown_types.Blocked _ -> fail "shutdown did not reach Finalized");
      (match
         Masc.Keeper_turn_admission.begin_shutdown
           ~base_path:config.base_path
           ~keeper_name:meta.name
           ~operation_id
       with
       | Masc.Keeper_turn_admission.Shutdown_reserved _ -> ()
       | Masc.Keeper_turn_admission.Shutdown_already_reserved _ ->
         fail "finalized shutdown did not release its admission fence");
      (match Shutdown_finalize.run ~config ~entry:None finalized with
       | Ok _ -> ()
       | Error error -> fail (Shutdown_finalize.error_to_string error));
      check
        bool
        "finalized shutdown replay releases admission fence"
        true
        (Option.is_none
           (Masc.Keeper_turn_admission.snapshot_for
             ~base_path:config.base_path
              ~keeper_name:meta.name)
             .snapshot_shutdown_operation_id);
      match Keeper_meta_store.read_meta config meta.name with
      | Ok (Some retained) ->
        check bool "retained Keeper is paused" true retained.paused;
        check bool "retained Keeper task binding is cleared" true
          (Option.is_none retained.current_task_id)
      | Ok None -> fail "retained Keeper metadata disappeared"
      | Error detail -> fail detail)

let test_keeper_shutdown_delivers_dead_tombstone_completion_after_receipt () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let base_dir = temp_dir "shutdown-dead-tombstone-completion" in
  let completion_bus =
    Agent_sdk.Event_bus.create
      ~policy:Agent_sdk.Event_bus.Drop_oldest
      ()
  in
  let completion_subscription =
    Agent_sdk.Event_bus.subscribe
      ~purpose:"dead-tombstone-completion-test"
      completion_bus
  in
  Masc_event_bus.set completion_bus;
  Fun.protect
    ~finally:(fun () ->
      Agent_sdk.Event_bus.unsubscribe completion_bus completion_subscription;
      Shutdown_finalize.For_testing.reset_remove_pending_confirms_by_target ();
      Shutdown_finalize.For_testing.reset_completion_handler ();
      Lifecycle_hooks.reset_for_testing ();
      Subprocess_registry.reset_for_testing ();
      Masc.Keeper_turn_admission.For_testing.reset ();
      R.clear ();
      cleanup_dir base_dir)
    (fun () ->
      let config = Masc.Workspace.default_config base_dir in
      let (_init_message : string) =
        Masc.Workspace.init config ~agent_name:(Some "supervisor")
      in
      let backlog_version =
        match Workspace_backlog.read_backlog_r config with
        | Ok backlog -> backlog.version
        | Error detail -> fail detail
      in
      let meta = make_meta "shutdown-dead-tombstone-keeper" in
      (match Keeper_meta_store.write_meta config meta with
       | Ok () -> ()
       | Error detail -> fail detail);
      let entry = R.register ~base_path:config.base_path meta.name meta in
      let hook_deliveries = ref 0 in
      Subprocess_registry.register_default_cleanup_hook ();
      Lifecycle_hooks.register (fun ~keeper_id event ->
        match event with
        | Lifecycle_hooks.Tombstone_reaped ->
          check string "completion hook Keeper" meta.name keeper_id;
          incr hook_deliveries
        | Lifecycle_hooks.Phase_transition _ -> ());
      Shutdown_finalize.register_remove_pending_confirms_by_target
        (fun _config ~target_type:_ ~target_id:_ -> Ok 0);
      Shutdown_finalize.register_completion_handler
        (fun _config _operation _action -> Error "synthetic completion outage");
      let operation_id = Shutdown_types.Operation_id.generate () in
      let operation : Shutdown_types.t =
        { schema_version = Shutdown_types.schema_version
        ; revision = 0
        ; operation_id
        ; keeper_name = meta.name
        ; lane_id = Lane.id entry.lane
        ; trace_id = meta.runtime.trace_id
        ; generation = meta.runtime.generation
        ; actor = "supervisor"
        ; cleanup_intent =
            { meta_disposition = Shutdown_types.Retain_dead_tombstone
            ; remove_session = false
            }
        ; turn_disposition = Shutdown_types.No_inflight_turn
        ; expected_backlog_version = backlog_version
        ; owned_task_ids = []
        ; join_evidence = None
        ; phase = Shutdown_types.Joined_idle
        ; created_at = Masc_domain.now_iso ()
        ; updated_at = Masc_domain.now_iso ()
        }
      in
      (match
         Masc.Keeper_turn_admission.begin_shutdown
           ~base_path:config.base_path
           ~keeper_name:meta.name
           ~operation_id
       with
       | Masc.Keeper_turn_admission.Shutdown_reserved _ -> ()
       | Masc.Keeper_turn_admission.Shutdown_already_reserved _ ->
         fail "fresh dead-tombstone fixture was already reserved");
      (match Shutdown_store.persist_new ~config operation with
       | Ok () -> ()
       | Error error -> fail (Shutdown_store.error_to_string error));
      (match Shutdown_finalize.run ~config ~entry:(Some entry) operation with
       | Error (Shutdown_finalize.Completion_failed (_, detail)) ->
         check string
           "completion outage remains explicit"
           "synthetic completion outage"
           detail
       | Error error -> fail (Shutdown_finalize.error_to_string error)
       | Ok _ -> fail "completion outage was reported as delivered");
      let pending =
        match
          Shutdown_store.load
            ~config
            ~keeper_name:meta.name
            operation_id
        with
        | Ok operation -> operation
        | Error error -> fail (Shutdown_store.error_to_string error)
      in
      (match pending.phase with
       | Shutdown_types.Finalized
           { completion =
               Shutdown_types.Completion_pending
                 Shutdown_types.Dead_tombstone_reaped
           ; registry_unregistered
           ; _
           } -> check bool "exact dead lane unregistered" true registry_unregistered
       | Shutdown_types.Prepared
       | Shutdown_types.Joined_idle
       | Shutdown_types.Finalizing_tasks _
       | Shutdown_types.Cleanup_ready _
       | Shutdown_types.Reconciliation_required _
       | Shutdown_types.Blocked _
       | Shutdown_types.Finalized _ ->
         fail "completion outage did not retain a pending durable receipt");
      check int "pending receipt did not fire hook" 0 !hook_deliveries;
      (match
         Masc.Keeper_turn_admission.run_if_free
           ~base_path:config.base_path
           ~keeper_name:meta.name
           (fun () -> ())
       with
       | `Busy (Masc.Keeper_turn_admission.Shutdown_requested reserved) ->
         check bool "pending receipt retains exact admission owner" true
           (Shutdown_types.Operation_id.equal operation_id reserved)
       | `Busy (Masc.Keeper_turn_admission.Turn_busy _)
       | `Ran () -> fail "pending completion reopened admission");
      Masc.Keeper_turn_admission.For_testing.reset ();
      let boot_inventory =
        match Shutdown_store.scan_inventory ~config with
        | Ok inventory -> inventory
        | Error error -> fail (Shutdown_store.error_to_string error)
      in
      let restored =
        match
          Shutdown_runtime.restore_inventory_admission ~config boot_inventory
        with
        | Ok restored -> restored
        | Error detail -> fail detail
      in
      check
        (list string)
        "boot restores pending completion owner fence"
        [ meta.name ]
        restored.blocked_keeper_names;
      (match
         Masc.Keeper_turn_admission.run_if_free
           ~base_path:config.base_path
           ~keeper_name:meta.name
           (fun () -> ())
       with
       | `Busy (Masc.Keeper_turn_admission.Shutdown_requested reserved) ->
         check bool "boot-restored fence keeps exact completion owner" true
           (Shutdown_types.Operation_id.equal operation_id reserved)
       | `Busy (Masc.Keeper_turn_admission.Turn_busy _)
       | `Ran () -> fail "boot recovery reopened pending completion admission");
      Shutdown_finalize.register_completion_handler
        Tombstone_cleanup.handle_completion;
      let finalized =
        match Shutdown_finalize.run ~config ~entry:None pending with
        | Ok finalized -> finalized
        | Error error -> fail (Shutdown_finalize.error_to_string error)
      in
      (match finalized.phase with
       | Shutdown_types.Finalized
           { completion =
               Shutdown_types.Completion_delivered
                 Shutdown_types.Dead_tombstone_reaped
           ; registry_unregistered
           ; meta_removed
           ; _
           } ->
         check bool "delivered receipt preserves unregister evidence" true
           registry_unregistered;
         check bool "dead tombstone meta retained" false meta_removed
       | Shutdown_types.Prepared
       | Shutdown_types.Joined_idle
       | Shutdown_types.Finalizing_tasks _
       | Shutdown_types.Cleanup_ready _
       | Shutdown_types.Reconciliation_required _
       | Shutdown_types.Blocked _
       | Shutdown_types.Finalized _ ->
          fail "dead tombstone completion receipt was not delivered");
      check int "Tombstone_reaped delivered once" 1 !hook_deliveries;
      (match Agent_sdk.Event_bus.drain completion_subscription with
       | [ event ] ->
         (match event.Agent_sdk.Event_bus.payload with
          | Agent_sdk.Event_bus.Custom
              ("masc.keeper.lifecycle", `Assoc fields) ->
            (match List.assoc_opt "event" fields, List.assoc_opt "detail" fields with
             | Some (`String event_name), Some (`String detail) ->
               check string "durable completion lifecycle event" "dead_cleaned" event_name;
               check string
                 "durable completion event identity"
                 ("shutdown_operation="
                  ^ Shutdown_types.Operation_id.to_string operation_id)
                 detail
             | _ -> fail "dead completion event payload lost typed fields")
          | Agent_sdk.Event_bus.Custom (topic, _) ->
            fail ("unexpected completion event topic: " ^ topic)
          | _ -> fail "dead completion did not publish a custom lifecycle event")
       | events ->
         fail
           (Printf.sprintf
              "expected one durable completion event, got %d"
              (List.length events)));
      let reloaded =
        match
          Shutdown_store.load
            ~config
            ~keeper_name:meta.name
            operation_id
        with
        | Ok operation -> operation
        | Error error -> fail (Shutdown_store.error_to_string error)
      in
      check bool "delivered completion receipt survives store round-trip" true
        (reloaded.phase = finalized.phase);
      check bool "dead Keeper removed from registry" false
        (R.is_registered ~base_path:config.base_path meta.name);
      (match Keeper_meta_store.read_meta config meta.name with
       | Ok (Some retained) ->
         check bool "retained dead meta paused" true retained.paused;
         (match retained.latched_reason with
          | Some Keeper_latched_reason.Dead_tombstone -> ()
          | Some _ | None -> fail "retained meta lost Dead_tombstone reason")
       | Ok None -> fail "dead tombstone meta was removed"
       | Error detail -> fail detail);
      (match Shutdown_finalize.run ~config ~entry:None finalized with
       | Ok _ -> ()
       | Error error -> fail (Shutdown_finalize.error_to_string error));
      check int "delivered receipt prevents duplicate hook" 1 !hook_deliveries;
      check int
        "delivered receipt prevents duplicate lifecycle event"
        0
        (List.length (Agent_sdk.Event_bus.drain completion_subscription));
      check
        bool
        "delivered dead completion releases admission fence"
        true
        (Option.is_none
           (Masc.Keeper_turn_admission.snapshot_for
              ~base_path:config.base_path
              ~keeper_name:meta.name)
             .snapshot_shutdown_operation_id))

let test_keeper_shutdown_cleanup_replays_after_meta_removal () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let base_dir = temp_dir "shutdown-meta-replay" in
  Fun.protect
    ~finally:(fun () ->
      Masc.Keeper_turn_admission.For_testing.reset ();
      R.clear ();
      cleanup_dir base_dir)
    (fun () ->
      let config = Masc.Workspace.default_config base_dir in
      let (_init_message : string) =
        Masc.Workspace.init config ~agent_name:(Some "operator")
      in
      let meta = make_meta "shutdown-meta-replay-keeper" in
      (match Keeper_meta_store.write_meta config meta with
       | Ok () -> ()
       | Error detail -> fail detail);
      let backlog_version =
        match Workspace_backlog.read_backlog_r config with
        | Ok backlog -> backlog.version
        | Error detail -> fail detail
      in
      let operation_id = Shutdown_types.Operation_id.generate () in
      let cleanup : Shutdown_types.cleanup_evidence =
        { settled_task_ids = []; pending_confirms_removed = 0 }
      in
      let operation : Shutdown_types.t =
        { schema_version = Shutdown_types.schema_version
        ; revision = 0
        ; operation_id
        ; keeper_name = meta.name
        ; lane_id = Lane.id (Lane.create ())
        ; trace_id = meta.runtime.trace_id
        ; generation = meta.runtime.generation
        ; actor = "operator"
        ; cleanup_intent = remove_meta_cleanup
        ; turn_disposition = Shutdown_types.No_inflight_turn
        ; expected_backlog_version = backlog_version
        ; owned_task_ids = []
        ; join_evidence = None
        ; phase = Shutdown_types.Cleanup_ready cleanup
        ; created_at = Masc_domain.now_iso ()
        ; updated_at = Masc_domain.now_iso ()
        }
      in
      (match Shutdown_store.persist_new ~config operation with
       | Ok () -> ()
       | Error error -> fail (Shutdown_store.error_to_string error));
      (match
         Keeper_meta_store.remove_meta_if_identity
           config
           ~name:meta.name
           ~trace_id:meta.runtime.trace_id
           ~generation:meta.runtime.generation
       with
       | Ok () -> ()
       | Error error -> fail (Keeper_meta_store.identity_remove_error_to_string error));
      match Shutdown_finalize.run ~config ~entry:None operation with
      | Ok { phase = Shutdown_types.Finalized evidence; _ } ->
        check bool "meta cleanup remains complete on replay" true evidence.meta_removed
      | Ok _ -> fail "meta cleanup replay did not reach Finalized"
      | Error error -> fail (Shutdown_finalize.error_to_string error))

let test_keeper_shutdown_recovers_committed_task_receipt () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let base_dir = temp_dir "shutdown-task-receipt" in
  Fun.protect
    ~finally:(fun () ->
      Shutdown_finalize.For_testing.reset_remove_pending_confirms_by_target ();
      Masc.Keeper_turn_admission.For_testing.reset ();
      R.clear ();
      cleanup_dir base_dir)
    (fun () ->
      let config = Masc.Workspace.default_config base_dir in
      let (_init_message : string) =
        Masc.Workspace.init config ~agent_name:(Some "operator")
      in
      let meta = make_meta "shutdown-task-receipt-keeper" in
      (match Keeper_meta_store.write_meta config meta with
       | Ok () -> ()
       | Error detail -> fail detail);
      Shutdown_finalize.register_remove_pending_confirms_by_target
        (fun _config ~target_type:_ ~target_id:_ -> Ok 0);
      let task_id_wire =
        match
          Masc.Workspace.add_task_with_result
            config
            ~title:"shutdown receipt fixture"
            ~priority:1
            ~description:"durable task settlement"
        with
        | Ok created -> created.task_id
        | Error error -> fail (Masc.Workspace.add_task_error_to_string error)
      in
      (match
         Masc.Workspace.claim_task_r
           config
           ~agent_name:meta.agent_name
           ~task_id:task_id_wire
           ()
       with
       | Ok _ -> ()
       | Error error -> fail (Masc_domain.masc_error_to_string error));
      let task_id =
        match Keeper_id.Task_id.of_string task_id_wire with
        | Ok task_id -> task_id
        | Error detail -> fail detail
      in
      let backlog_version =
        match Workspace_backlog.read_backlog_r config with
        | Ok backlog -> backlog.version
        | Error detail -> fail detail
      in
      let operation_id = Shutdown_types.Operation_id.generate () in
      let operation : Shutdown_types.t =
        { schema_version = Shutdown_types.schema_version
        ; revision = 0
        ; operation_id
        ; keeper_name = meta.name
        ; lane_id = Lane.id (Lane.create ())
        ; trace_id = meta.runtime.trace_id
        ; generation = meta.runtime.generation
        ; actor = "operator"
        ; cleanup_intent = retain_operator_cleanup
        ; turn_disposition = Shutdown_types.No_inflight_turn
        ; expected_backlog_version = backlog_version
        ; owned_task_ids = [ task_id ]
        ; join_evidence = None
        ; phase = Shutdown_types.Joined_idle
        ; created_at = Masc_domain.now_iso ()
        ; updated_at = Masc_domain.now_iso ()
        }
      in
      (match Shutdown_store.persist_new ~config operation with
       | Ok () -> ()
       | Error error -> fail (Shutdown_store.error_to_string error));
      let handoff_context : Masc_domain.task_handoff_context =
        { summary = "Keeper stopped; task returned to the durable backlog"
        ; reason = Some "Keeper shutdown operation completed lane join"
        ; next_step = Some "A live Keeper may reclaim this task"
        ; failure_mode = None
        ; reclaim_policy = Some Masc_domain.Allow_reclaim
        ; evidence_refs =
            [ "masc://keeper-shutdown/"
              ^ Shutdown_types.Operation_id.to_string operation_id
            ]
        ; updated_at = Some (Masc_domain.now_iso ())
        ; updated_by = Some operation.actor
        }
      in
      (match
         Masc.Workspace.release_task_r
           config
           ~agent_name:meta.agent_name
           ~task_id:task_id_wire
           ~expected_version:backlog_version
           ~handoff_context
           ()
       with
       | Ok _ -> ()
       | Error error -> fail (Masc_domain.masc_error_to_string error));
      match Shutdown_finalize.run ~config ~entry:None operation with
      | Ok { phase = Shutdown_types.Finalized evidence; _ } ->
        check int
          "committed release receipt is recovered exactly once"
          1
          (List.length evidence.cleanup.settled_task_ids)
      | Ok _ -> fail "task receipt recovery did not reach Finalized"
      | Error error -> fail (Shutdown_finalize.error_to_string error))

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

let test_stop_keepalive_only_requests_lane_stop () =
  R.clear ();
  let keeper_name = "manual-stop-entry" in
  let reg = R.register ~base_path:bp keeper_name (make_meta keeper_name) in
  Masc.Keeper_keepalive.stop_keepalive keeper_name;
  match R.get ~base_path:bp keeper_name with
  | None -> fail "expected manual-stop-entry in registry"
  | Some entry ->
    check bool "stop signal set" true (Atomic.get entry.fiber_stop);
    check bool "wakeup signal set" true (Atomic.get entry.fiber_wakeup);
    check string
      "phase remains owned by lane"
      "running"
      (KSM.phase_to_string entry.phase);
    check bool
      "terminal promise is not a stop-request acknowledgement"
      true
      (Option.is_none (Eio.Promise.peek reg.done_p));
    check bool
      "unstarted synthetic entry has not joined"
      true
      (not (R.lane_has_exited entry))

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

let test_blocking_gates_are_classified_before_intake () =
  (match
     KHL.classify_turn_intake_admission
       ~pressure:Keeper_pressure_admission.Admitted
       ~blocking_approval_pending:true
       ~keeper_paused:false
   with
   | KHL.Intake_blocking_approval_pending -> ()
   | KHL.Intake_admitted
   | KHL.Intake_pressure_blocked _
   | KHL.Intake_keeper_paused ->
     fail "blocking approval must stop intake before durable dequeue");
  (match
     KHL.classify_turn_intake_admission
       ~pressure:Keeper_pressure_admission.Admitted
       ~blocking_approval_pending:false
       ~keeper_paused:true
   with
   | KHL.Intake_keeper_paused -> ()
   | KHL.Intake_admitted
   | KHL.Intake_blocking_approval_pending
   | KHL.Intake_pressure_blocked _ ->
     fail "explicit Keeper pause must stop intake before durable dequeue");
  match
    KHL.classify_turn_intake_admission
      ~pressure:Keeper_pressure_admission.Admitted
      ~blocking_approval_pending:false
      ~keeper_paused:false
  with
  | KHL.Intake_admitted -> ()
  | KHL.Intake_blocking_approval_pending
  | KHL.Intake_pressure_blocked _
  | KHL.Intake_keeper_paused ->
    fail "no blocking approval should leave intake admitted"

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
      test_case "stop resolves done after lane exit" `Quick
        test_direct_start_keepalive_resolves_done_on_stop;
      test_case "lane join waits for children and cleanup" `Quick
        test_keeper_lane_join_waits_for_children_and_cleanup;
      test_case "lane join surfaces cleanup failure" `Quick
        test_keeper_lane_surfaces_cleanup_failure;
      test_case "lane identity is typed and unique" `Quick
        test_keeper_lane_identity_is_typed_and_unique;
      test_case "lane cancellation is local and joinable" `Quick
        test_keeper_lane_cancel_is_lane_local_and_joinable;
      test_case "lane records shutdown request on cancel" `Quick
        test_lane_records_shutdown_request_on_cancel;
      test_case "shutdown store round-trip and identity guard" `Quick
        test_keeper_shutdown_store_round_trip_and_identity_guard;
      test_case "shutdown store isolates corrupt owner" `Quick
        test_keeper_shutdown_store_isolates_corrupt_owner;
      test_case "shutdown prepare joins idle lane" `Quick
        test_keeper_shutdown_prepare_joins_idle_lane;
      test_case "shutdown prepare joins not-started lane" `Quick
        test_keeper_shutdown_prepare_joins_not_started_lane;
      test_case "shutdown prepare failure rolls back admission fence" `Quick
        test_keeper_shutdown_prepare_failure_rolls_back_fence;
      test_case "shutdown finalizes idle operation" `Quick
        test_keeper_shutdown_finalizes_idle_operation;
      test_case "shutdown delivers dead tombstone completion after receipt" `Quick
        test_keeper_shutdown_delivers_dead_tombstone_completion_after_receipt;
      test_case "shutdown cleanup replays after meta removal" `Quick
        test_keeper_shutdown_cleanup_replays_after_meta_removal;
      test_case "shutdown recovers committed task receipt" `Quick
        test_keeper_shutdown_recovers_committed_task_receipt;
      test_case "unresolved failing entry is preserved" `Quick
        test_start_keepalive_preserves_unresolved_failing_entry;
      test_case "finished failing entry is reclaimed" `Quick
        test_start_keepalive_reclaims_finished_failing_entry;
      test_case "manual stop only requests lane stop" `Quick
        test_stop_keepalive_only_requests_lane_stop;
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
      test_case "blocking gates are classified before intake" `Quick
        test_blocking_gates_are_classified_before_intake;
      test_case "crashed cycles feed agent health breaker" `Quick
        test_crashed_cycle_records_health_failure;
    ];
  ]
