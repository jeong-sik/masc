(** Integration tests for Adaptive Heartbeat Phase 0/1/2.

    Tests cross-module scenarios that exercise the supervisor → registry
    interaction paths. Not full E2E (no Workspace I/O), but verifies the
    behavioral contracts between modules:

    1. Structured crash flow (3 catch branches)
    2. Supervisor ownership and cleanup lifecycle
    3. Reconcile predicate logic (sweep-owned vs reconcile-eligible)

    @since Phase 2 post-merge improvement *)

open Alcotest

module R = Masc.Keeper_registry
module Workspace = Masc.Workspace
module Keeper_types_profile = Masc.Keeper_types_profile
module Keeper_profile_defaults = Masc.Keeper_types_profile_defaults
module Sup = Masc.Keeper_supervisor
module KT = Keeper_types
module KSM = Keeper_state_machine
module Cfg = Env_config
module KHL = Masc.Keeper_heartbeat_loop
module Keeper_lifecycle_admission = Masc.Keeper_lifecycle_admission
module WO = Masc.Keeper_world_observation
module Health = Masc.Health
module Lane = Masc.Keeper_lane
module Memory_lane = Masc.Keeper_memory_lane
module Shutdown_types = Masc.Keeper_shutdown_types
module Shutdown_store = Masc.Keeper_shutdown_store
module Shutdown_prepare_join = Masc.Keeper_shutdown_prepare_join
module Shutdown_finalize = Masc.Keeper_shutdown_finalize
module Shutdown_runtime = Masc.Keeper_shutdown_runtime
module Shutdown_supersession = Masc.Keeper_shutdown_supersession
module Approval_queue = Masc.Keeper_approval_queue
module Approval_types = Keeper_approval_queue_rules_types
module Turn_up_args = Masc.Keeper_turn_up_args
module Turn_up_update = Masc.Keeper_turn_up_update
module Turn_up_config_persistence = Masc.Keeper_turn_up_config_persistence
module Keeper_meta_contract = Masc.Keeper_meta_contract
module Keeper_meta_json = Masc.Keeper_meta_json
module Keeper_meta_store = Masc.Keeper_meta_store
module Keeper_owner_registry = Masc.Keeper_owner_registry
module Paused_work_receipt = Masc.Keeper_paused_work_disposition_receipt
module Keeper_checkpoint_store = Masc.Keeper_checkpoint_store
module Fusion_config_loader = Masc.Fusion_config_loader
module Keeper_lifecycle_reservation = Masc.Keeper_lifecycle_reservation
module Keeper_types_support = Masc.Keeper_types_support
module Keeper_fs = Masc.Keeper_fs
module Lifecycle_hooks = Masc.Keeper_lifecycle_hooks
module Subprocess_registry = Masc.Keeper_subprocess_registry
module Supervisor_cleanup = Masc.Keeper_supervisor_cleanup
module Dashboard_purge = Masc.Keeper_dashboard_purge
module Dashboard_delete = Server_dashboard_http_delete_actions

exception Librarian_executor_cancel
exception Cancel_direct_keepalive_parent
exception Cancel_keeper_up_after_metadata

let bp = "/tmp/test-heartbeat-integ"

let temp_dir prefix =
  let dir = Filename.temp_file prefix "" in
  Unix.unlink dir;
  Unix.mkdir dir 0o755;
  dir

let write_file path content =
  Fs_compat.mkdir_p (Filename.dirname path);
  let oc = open_out_bin path in
  Fun.protect
    ~finally:(fun () -> close_out_noerr oc)
    (fun () -> output_string oc content)
;;

let install_owner_inventory_exn ~sw config =
  match Keeper_owner_registry.install_from_store ~sw ~operation_runner:None ~on_turn_slot_released:None config with
  | Ok _ -> ()
  | Error error -> fail (Keeper_owner_registry.install_error_to_string error)
;;

let create_owner_meta_exn config meta =
  match Keeper_owner_registry.create_meta ~base_path:config.Workspace.base_path meta with
  | Ok (Some _) -> ()
  | Ok None -> fail "owner metadata creation removed its snapshot"
  | Error error -> fail (Keeper_owner_registry.command_error_to_string error)
;;

let config_revision_exn config keeper_name =
  match Turn_up_config_persistence.current_config_revision ~config ~keeper_name with
  | Ok revision -> revision
  | Error error -> fail error
;;

let ensure_owner_meta_exn config meta =
  match
    Keeper_owner_registry.get
      ~base_path:config.Workspace.base_path
      ~keeper_name:meta.Keeper_meta_contract.name
  with
  | Ok _ -> ()
  | Error (Keeper_owner_registry.Owner_not_found _) ->
    create_owner_meta_exn config meta
  | Error error -> fail (Keeper_owner_registry.lookup_error_to_string error)
;;

let owner_shutdown_operation_id_exn ~base_path ~keeper_name =
  match Keeper_owner_registry.shutdown_operation_id ~base_path ~keeper_name with
  | Ok operation_id -> operation_id
  | Error error -> fail (Keeper_owner_registry.lookup_error_to_string error)
;;

let owner_turn_in_flight_exn ~base_path ~keeper_name =
  match Keeper_owner_registry.get ~base_path ~keeper_name with
  | Ok owner -> Masc.Keeper_owner.turn_in_flight owner
  | Error error -> fail (Keeper_owner_registry.lookup_error_to_string error)
;;

let begin_owner_shutdown_exn ~base_path ~keeper_name ~operation_id =
  match
    Keeper_owner_registry.begin_shutdown ~base_path ~keeper_name ~operation_id
  with
  | Ok result -> result
  | Error error -> fail (Keeper_owner_registry.command_error_to_string error)
;;

let restore_owner_shutdown_exn ~base_path ~keeper_name ~operation_id =
  match
    Keeper_owner_registry.restore_shutdown ~base_path ~keeper_name ~operation_id
  with
  | Ok result -> result
  | Error error -> fail (Keeper_owner_registry.command_error_to_string error)
;;

let transition_owner_shutdown_exn
      ~base_path
      ~keeper_name
      ~from_operation_id
      ~to_operation_id
  =
  match
    Keeper_owner_registry.transition_shutdown
      ~base_path
      ~keeper_name
      ~from_operation_id
      ~to_operation_id
  with
  | Ok result -> result
  | Error error -> fail (Keeper_owner_registry.command_error_to_string error)
;;

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

let snapshot_path path =
  let rec collect root relative =
    let current = if String.equal relative "" then root else Filename.concat root relative in
    if not (Sys.file_exists current)
    then []
    else if Sys.is_directory current
    then
      Sys.readdir current
      |> Array.to_list
      |> List.sort String.compare
      |> List.concat_map (fun name ->
        collect root (if String.equal relative "" then name else Filename.concat relative name))
    else [ relative, In_channel.with_open_bin current In_channel.input_all ]
  in
  collect path ""
;;

let publication_recovery_registry env sw config =
  Masc_test_deps.with_publication_recovery_registry
    ~sw
    ~fs:(Eio.Stdenv.fs env)
    ~registry_root:(Workspace.masc_root_dir config)
    Fun.id

let make_meta name =
  let json = `Assoc [
    ("name", `String name);
    ("trace_id", `String ("trace-integ-" ^ name));
  ] in
  match Masc_test_deps.meta_of_json_fixture json with
  | Ok meta -> meta
  | Error err -> Alcotest.fail ("make_meta failed: " ^ err)

let retain_operator_cleanup : Shutdown_types.cleanup_intent =
  { reason = Shutdown_types.Operator_stop_retain_meta
  ; remove_session = false
  }
;;

let remove_meta_cleanup : Shutdown_types.cleanup_intent =
  { reason = Shutdown_types.Operator_stop_remove_meta
  ; remove_session = false
  }
;;

(* Keepalive resolves its sandbox profile from the persisted keeper TOML. Seed
   the fixture explicitly so this test exercises the lifecycle path rather than
   keeper configuration validation. *)
let seed_keeper_sandbox_profile ~base_dir name =
  let keepers_dir =
    List.fold_left Filename.concat base_dir [ ".masc"; "config"; "keepers" ]
  in
  Fs_compat.mkdir_p keepers_dir;
  Fs_compat.save_file
    (Filename.concat keepers_dir (name ^ ".toml"))
    ("[keeper]\nsandbox_profile = \"local\"\ninstructions = \"# " ^ name ^ "\"\n")

let dashboard_purge_cleanup requested_name
    (meta : Keeper_meta_contract.keeper_meta)
    : Shutdown_types.cleanup_intent
  =
  { reason =
      Shutdown_types.Dashboard_keeper_purge { requested_name }
  ; remove_session = true
  }
;;

let unsupported_shutdown_schema_fixture (operation : Shutdown_types.t) =
  match Shutdown_store.to_json operation with
  | `Assoc fields ->
    `Assoc
      (("schema_version", `Int (Shutdown_types.schema_version - 1))
       :: List.remove_assoc "schema_version" fields)
  | _ -> fail "shutdown JSON codec did not return an object"
;;

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
  { pending_messages = []
  ; pending_board_events = []
  ; idle_seconds = 0
  ; active_goals = []
  ; unclaimed_task_count = 0
  ; claimable_tasks = []
  ; held_task_skills = []
  ; failed_task_count = 0
  ; scheduled_automation = WO.empty_scheduled_automation_observation
  ; backlog_revision = Some 1
  ; running_keeper_fiber_count = 0
  ; connected_surfaces = []
  ; connected_surface_failures = []
  ; own_recent_board_posts = []
  ; fleet_messages = []
  ; own_recent_actions = []
  }

(* ══════════════════════════════════════════════════════════
   1. Structured crash flow — supervisor catch simulation
   ══════════════════════════════════════════════════════════ *)

(** Simulate the Keeper_fiber_crash catch branch in
    launch_supervised_fiber.  Failure reason is pre-stored in registry,
    exception carries no payload (RFC-0002).
    Verifies: state = Crashed, failure_reason stored, done_p resolved. *)
let test_crash_heartbeat_failure () =
  R.For_testing.clear ();
  let meta = make_meta "hb-crash" in
  let reg = R.For_testing.register ~base_path:bp "hb-crash" meta in
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
  R.For_testing.clear ();
  let meta = make_meta "exn-crash" in
  let reg = R.For_testing.register ~base_path:bp "exn-crash" meta in
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
  R.For_testing.clear ();
  let meta = make_meta "unresolved" in
  let reg = R.For_testing.register ~base_path:bp "unresolved" meta in
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
   2. Supervisor ownership and cleanup lifecycle
   ══════════════════════════════════════════════════════════ *)

(** Running and Crashed entries remain sweep-owned; only explicit cleanup
    unregisters an absent Keeper. *)
let test_reconcile_predicate_sweep_owned () =
  R.For_testing.clear ();
  (* Running = sweep-owned *)
  let _e = R.For_testing.register ~base_path:bp "r1" (make_meta "r1") in
  (match R.get ~base_path:bp "r1" with
   | Some e ->
     check string "running" "running" (KSM.phase_to_string e.phase);
     check bool "sweep-owned" true
       (e.phase = KSM.Running || e.phase = KSM.Paused
        || e.phase = KSM.Crashed)
   | None -> fail "expected r1");
  (* Crashed = sweep-owned *)
  ignore (R.dispatch_event ~base_path:bp "r1"
    (KSM.Fiber_terminated { outcome = "test"; provider_id = None; http_status = None }));
  (match R.get ~base_path:bp "r1" with
   | Some e -> check bool "crashed is sweep-owned" true
       (e.phase = KSM.Crashed)
   | None -> fail "expected r1")

let test_reconcile_predicate_stopped_resolved () =
  R.For_testing.clear ();
  let reg = R.For_testing.register ~base_path:bp "s1" (make_meta "s1") in
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
       | KSM.Running | KSM.Paused | KSM.Crashed -> true
       | KSM.Failing
       | KSM.Draining | KSM.Restarting -> true
       | KSM.Offline -> false
       | KSM.Stopped -> not (R.lane_has_exited e)
     in
     check bool "not dominated (reconcile-eligible)" false dominated
   | None -> fail "expected s1")

let test_reconcile_predicate_stopped_unresolved () =
  R.For_testing.clear ();
  let _reg = R.For_testing.register ~base_path:bp "s2" (make_meta "s2") in
  ignore (R.dispatch_event ~base_path:bp "s2" KSM.Stop_requested);
  ignore (R.dispatch_event ~base_path:bp "s2" KSM.Drain_complete);
  (* Stopped + unresolved done_p = sweep will handle *)
  (match R.get ~base_path:bp "s2" with
   | Some e ->
     check string "stopped" "stopped" (KSM.phase_to_string e.phase);
     check bool "done_p NOT resolved" true
       (Option.is_none (Eio.Promise.peek e.done_p));
     let dominated = match e.phase with
       | KSM.Running | KSM.Paused | KSM.Crashed -> true
       | KSM.Failing
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
  R.For_testing.clear ();
  let meta = make_meta "restartable" in
  let reg1 = R.For_testing.register ~base_path:bp "restartable" meta in
  resolve_done_for_test reg1 (`Crashed "first crash");
  ignore (R.dispatch_event ~base_path:bp "restartable"
    (KSM.Fiber_terminated { outcome = "first crash"; provider_id = None; http_status = None }));
  R.record_crash ~base_path:bp "restartable" 100.0 "first crash";
  (* Simulate sweep restart: re-register then restore state *)
  let _reg2 = R.For_testing.register ~base_path:bp "restartable" meta in
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
  R.For_testing.clear ();
  let meta = make_meta "turn-crash" in
  let reg = R.For_testing.register ~base_path:bp "turn-crash" meta in
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

(** A healthy heartbeat must not erase provider/tool turn failures.
    Regression for live 2026-05-16 evidence where a runtime_exhausted turn
    moved Failing -> Running via a keepalive heartbeat before the next real
    successful turn. *)
let test_fresh_presence_preserves_turn_failures () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  Eio.Switch.run @@ fun sw ->
  R.For_testing.clear ();
  let base_path = temp_dir "fresh-presence-turn-failure" in
  Fun.protect
    ~finally:(fun () ->
      R.For_testing.clear ();
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
          publication_recovery_provider =
            Masc_test_deps.non_runtime_publication_recovery_provider;
        }
      in
      let meta = make_meta "fresh-presence-turn-failure" in
      ignore (R.For_testing.register ~base_path:config.base_path meta.name meta);
      R.increment_turn_failures ~base_path:config.base_path meta.name;
      ignore
        (R.dispatch_event
           ~base_path:config.base_path
           meta.name
           (KSM.Turn_failed { consecutive = 1 }));
      (match R.get_phase ~base_path:config.base_path meta.name with
       | Some phase -> check string "phase after turn failure" "failing" (KSM.phase_to_string phase)
       | None -> fail "expected registered keeper phase");
      ignore
        (Masc.Keeper_heartbeat_loop.sync_keeper_presence
           ~ctx
           ~meta_current:meta
           ~consecutive_failures:(ref 0));
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
  R.For_testing.clear ();
  let base_path = temp_dir "crashed-cycle-turn-failure" in
  Fun.protect
    ~finally:(fun () ->
      R.For_testing.clear ();
      cleanup_dir base_path)
    (fun () ->
      let config = Masc.Workspace.default_config base_path in
      let meta = make_meta "crashed-cycle" in
      ignore (R.For_testing.register ~base_path:config.base_path meta.name meta);
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
      let event = KHL.turn_status_event ~turn_fail_count:count in
      (match event with
       | KSM.Turn_failed { consecutive } ->
         check int "consecutive" 1 consecutive
       | _ -> fail "expected Turn_failed for crashed cycle");
      ignore (R.dispatch_event ~base_path:config.base_path meta.name event);
      (match R.get_phase ~base_path:config.base_path meta.name with
       | Some phase ->
         check string "crashed cycle moves state machine to failing" "failing"
           (KSM.phase_to_string phase)
       | None -> fail "expected registered keeper phase");
      (* Clean cycle (count = 0) still maps to Turn_succeeded. *)
      match KHL.turn_status_event ~turn_fail_count:0 with
      | KSM.Turn_succeeded -> ()
      | _ -> fail "expected Turn_succeeded when no failures recorded")

let test_turn_status_preserves_configuration_failure_reason () =
  let configuration_reason =
    R.Turn_configuration_error
      { code = "invalid_config"
      ; field = Some "provider_credential"
      ; detail = "required provider credential is missing"
      }
  in
  (match
     KHL.failure_reason_after_turn_status
       ~turn_fail_count:1
       (Some configuration_reason)
   with
   | Some (R.Turn_configuration_error { field = Some field; _ }) ->
     check string "configuration field" "provider_credential" field
   | Some reason ->
     failf "configuration reason was overwritten: %s" (R.failure_reason_to_string reason)
   | None -> fail "configuration reason was cleared");
  match KHL.failure_reason_after_turn_status ~turn_fail_count:2 None with
  | Some (R.Turn_consecutive_failures count) -> check int "fallback count" 2 count
  | Some reason ->
    failf "expected generic turn failure, got %s" (R.failure_reason_to_string reason)
  | None -> fail "expected generic turn failure"

let test_operator_interrupt_skips_turn_accounting () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  R.For_testing.clear ();
  let base_path = temp_dir "operator-interrupt-turn-accounting" in
  Fun.protect
    ~finally:(fun () ->
      R.For_testing.clear ();
      cleanup_dir base_path)
    (fun () ->
      let meta = make_meta "operator-interrupt-turn-accounting" in
      ignore (R.For_testing.register ~base_path meta.name meta);
      let outcome =
        KHL.handle_cycle_exception
          ~base_path
          ~meta
          (Eio.Cancel.Cancelled R.Operator_interrupt)
      in
      check int
        "operator interrupt does not increment turn failures"
        0
        (R.get_turn_failures ~base_path meta.name);
      check bool "selected stimuli stay pending" false outcome.stimuli_acked;
      (match outcome.cycle_status with
       | KHL.Turn_cycle_interrupted -> ()
       | KHL.Turn_cycle_completed
       | KHL.Turn_cycle_crashed
       | KHL.Turn_cycle_busy _ ->
         fail "operator interrupt did not retain its typed cycle status");
      match KHL.decide_keepalive_cycle_action outcome.cycle_status with
      | KHL.Skip_interrupted_turn -> ()
      | KHL.Defer_autonomous_work _ | KHL.Record_turn_status _ ->
        fail "operator interrupt must not emit turn success or failure")

(* ══════════════════════════════════════════════════════════
   8. Direct keepalive path resolves lifecycle promises
   ══════════════════════════════════════════════════════════ *)

let test_direct_start_keepalive_resolves_done_on_stop () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  R.For_testing.clear ();
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
          publication_recovery_provider =
            Masc_test_deps.publication_recovery_provider
              (publication_recovery_registry env sw config);
        }
      in
      seed_keeper_sandbox_profile ~base_dir keeper_name;
      ignore
        (Masc.Keeper_keepalive.start_keepalive ctx meta
          : Masc.Keeper_keepalive.start_keepalive_outcome);
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

let test_direct_start_rolls_back_when_the_launch_owner_is_already_cancelled () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  R.For_testing.clear ();
  Memory_lane.For_testing.reset ();
  let base_dir = temp_dir "direct-keepalive-fork-reject" in
  let keeper_name = "direct-fork-reject" in
  Fun.protect
    ~finally:(fun () ->
      Memory_lane.For_testing.reset ();
      R.For_testing.clear ();
      cleanup_dir base_dir)
    (fun () ->
      ensure_default_runtime ();
      let config = Masc.Workspace.default_config base_dir in
      ignore (Masc.Workspace.init config ~agent_name:(Some "tester"));
      let meta = make_meta keeper_name in
      seed_keeper_sandbox_profile ~base_dir keeper_name;
      let launch_outcome = ref None in
      (try
         Eio.Switch.run @@ fun cancelling_sw ->
         let ctx : _ Keeper_types_profile.context =
           { config
           ; agent_name = "tester"
           ; sw = cancelling_sw
           ; clock = Eio.Stdenv.clock env
           ; proc_mgr = Some (Eio.Stdenv.process_mgr env)
           ; net = None
           ; publication_recovery_provider =
               Masc_test_deps.publication_recovery_provider
                 (publication_recovery_registry env cancelling_sw config)
           }
         in
         Eio.Switch.fail cancelling_sw Cancel_direct_keepalive_parent;
         launch_outcome := Some (Masc.Keeper_keepalive.start_keepalive ctx meta)
       with
       | Cancel_direct_keepalive_parent -> ());
      (* The launch transaction re-raises [Eio.Cancel.Cancelled] instead of
         folding it into a launch outcome, so a caller can never keep working
         inside a context its owner already tore down. KeeperOASAdvanced.tla
         checks exactly that with [CancelledNeverAbsorbed]. *)
      (match !launch_outcome with
       | None -> ()
       | Some outcome ->
         failf
           "cancelled launch owner produced an outcome instead of propagating: %s"
           (Masc.Keeper_keepalive.start_keepalive_outcome_to_string outcome));
      (* Rollback runs before the re-raise, so nothing is left behind. A
         registry entry here would tell operators a Keeper crashed when it
         never started. *)
      match R.get ~base_path:config.base_path keeper_name with
      | None -> ()
      | Some entry ->
        failf
          "cancelled launch left a registry entry: phase=%s done=%s"
          (KSM.phase_to_string entry.phase)
          (match Eio.Promise.peek entry.done_p with
           | None -> "unresolved"
           | Some `Stopped -> "stopped"
           | Some (`Crashed reason) -> "crashed:" ^ reason))

let test_direct_stop_resolves_done_after_librarian_drain_failure () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  R.For_testing.clear ();
  Memory_lane.For_testing.reset ();
  let base_dir = temp_dir "direct-keepalive-librarian-failure" in
  let keeper_name = "direct-librarian-failure" in
  Fun.protect
    ~finally:(fun () ->
      Masc.Keeper_keepalive.stop_keepalive ~base_path:base_dir keeper_name;
      Memory_lane.For_testing.reset ();
      R.For_testing.clear ();
      cleanup_dir base_dir)
    (fun () ->
      ensure_default_runtime ();
      let config = Masc.Workspace.default_config base_dir in
      ignore (Masc.Workspace.init config ~agent_name:(Some "tester"));
      let meta = make_meta keeper_name in
      Eio.Switch.run @@ fun keeper_sw ->
      let ctx : _ Keeper_types_profile.context =
        { config
        ; agent_name = "tester"
        ; sw = keeper_sw
        ; clock = Eio.Stdenv.clock env
        ; proc_mgr = Some (Eio.Stdenv.process_mgr env)
        ; net = None
        ; publication_recovery_provider =
            Masc_test_deps.publication_recovery_provider
              (publication_recovery_registry env keeper_sw config)
        }
      in
      seed_keeper_sandbox_profile ~base_dir keeper_name;
      (try
         Eio.Switch.run @@ fun librarian_sw ->
         Memory_lane.init ~sw:librarian_sw;
         (match Masc.Keeper_keepalive.start_keepalive ctx meta with
          | Masc.Keeper_keepalive.Keepalive_started _ -> ()
          | outcome ->
            failf
              "direct Librarian fixture failed to start: %s"
              (Masc.Keeper_keepalive.start_keepalive_outcome_to_string outcome));
         Eio.Time.sleep ctx.clock 0.05;
         let started, resolve_started = Eio.Promise.create () in
         let never, _resolve_never = Eio.Promise.create () in
         (match
            Memory_lane.submit
              ~base_path:config.base_path
              ~keeper_name
              (fun () ->
                 Eio.Promise.resolve resolve_started ();
                 Eio.Promise.await never)
          with
          | Memory_lane.Submitted -> ()
          | Memory_lane.Coalesced
          | Memory_lane.Ran_inline
          | Memory_lane.Dropped
          | Memory_lane.Rejected_draining ->
            fail "failed Librarian receipt fixture was not submitted");
         Eio.Promise.await started;
         Eio.Switch.fail librarian_sw Librarian_executor_cancel
       with
       | Librarian_executor_cancel -> ());
      match
        Masc.Keeper_keepalive.stop_keepalive_and_await
          ~base_path:config.base_path
          keeper_name
      with
      | Masc.Keeper_keepalive.Keeper_not_registered ->
        fail "failed-drain keeper disappeared before joined stop"
      | Masc.Keeper_keepalive.Keeper_joined
          { terminal = `Stopped; lane_exit = { cleanup_error = Some _; _ } } -> ()
      | Masc.Keeper_keepalive.Keeper_joined
          { terminal = `Stopped; lane_exit = { cleanup_error = None; _ } } ->
        fail "failed Librarian drain was not preserved as lane cleanup evidence"
      | Masc.Keeper_keepalive.Keeper_joined { terminal = `Crashed reason; _ } ->
        fail ("failed Librarian drain changed explicit stop into crash: " ^ reason))

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
   | Lane.Shutdown_cancel_failed failure ->
     fail
       ("unexpected shutdown cancellation failure: "
        ^ Printexc.to_string failure.cause)
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

let test_lane_cancel_before_start_is_joinable () =
  Eio_main.run @@ fun _env ->
  let lane = Lane.create () in
  (match Lane.request_cancel lane with
   | Lane.Cancel_requested -> ()
   | Lane.Cancel_already_requested
   | Lane.Cancel_already_exiting
   | Lane.Cancel_wrong_domain
   | Lane.Cancel_not_committed _
   | Lane.Cancel_committed_with_failure _ ->
     fail "expected request_cancel to be accepted on a fresh lane");
  match Lane.await_exit lane with
  | { outcome = Lane.Shutdown_before_start; _ } -> ()
  | { outcome = _; _ } ->
    fail "expected a not-started lane cancel to resolve Shutdown_before_start"

let test_keeper_lane_cancel_is_lane_local_and_joinable () =
  Eio_main.run @@ fun _env ->
  Eio.Switch.run @@ fun parent_sw ->
  let lane = Lane.create () in
  let never_p, _never_r = Eio.Promise.create () in
  let observed_origin = Atomic.make None in
  (match
     Lane.fork
       ~sw:parent_sw
       lane
       ~run:(fun _lane_sw ->
         try Eio.Promise.await never_p with
         | Eio.Cancel.Cancelled cause ->
           Atomic.set observed_origin (Some (Lane.classify_cancellation_cause cause)))
       ~cleanup:(fun _outcome -> Ok ())
   with
   | Ok () -> ()
   | Error error -> fail (Lane.start_error_to_string error));
  Eio.Fiber.yield ();
  (match Domain.join (Domain.spawn (fun () -> Lane.request_cancel lane)) with
   | Lane.Cancel_wrong_domain -> ()
   | Lane.Cancel_requested -> fail "cross-domain cancellation mutated the lane"
   | Lane.Cancel_already_requested ->
     fail "cross-domain cancellation observed a committed request"
   | Lane.Cancel_already_exiting -> fail "lane exited during cross-domain probe"
   | Lane.Cancel_not_committed exn
   | Lane.Cancel_committed_with_failure exn ->
     fail ("cross-domain cancellation touched Eio state: " ^ Printexc.to_string exn));
  check bool
    "cross-domain rejection leaves lane running"
    true
    (Option.is_none (Lane.peek_exit lane));
  (match Lane.request_cancel lane with
   | Lane.Cancel_requested -> ()
   | Lane.Cancel_already_requested
   | Lane.Cancel_already_exiting
   | Lane.Cancel_wrong_domain
   | Lane.Cancel_not_committed _
   | Lane.Cancel_committed_with_failure _ ->
     fail "first lane cancellation was not accepted");
  let exit = Lane.await_exit lane in
  (match Atomic.get observed_origin with
   | Some Lane.Shutdown_request -> ()
   | Some (Lane.External_cancel cause) ->
     fail ("lane body observed external cancellation: " ^ Printexc.to_string cause)
   | None -> fail "lane body did not observe cancellation origin");
  match exit.outcome with
  | Lane.Shutdown_requested -> ()
  | Lane.Shutdown_before_start -> fail "running lane reported pre-start shutdown"
  | Lane.Completed -> fail "cancelled lane reported normal completion"
  | Lane.Shutdown_cancel_failed failure ->
    fail
      ("lane shutdown cancellation failed: " ^ Printexc.to_string failure.cause)
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
      Eio.Switch.run @@ fun sw ->
      install_owner_inventory_exn ~sw config;
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
        ; lane_ownership = Shutdown_types.Registered_lane (Lane.id lane)
        ; trace_id = meta.runtime.trace_id
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
                  { settled_task_ids = []
                  ; pending_confirms_removed = 0
                  ; meta_snapshot_digest =
                      Keeper_meta_json.Snapshot_digest.of_meta meta
                  }
              ; meta_removed = false
              ; session_removed = false
              ; registry_unregistered = false
              ; accumulator_dropped = false
              ; completion =
                  Shutdown_types.Completion_pending
                    Shutdown_types.Supervisor_cleaned
              }
        }
      in
      (match Shutdown_store.persist_new ~config invalid_completion_operation with
       | Error
           (Shutdown_store.Invalid_operation
             (Shutdown_types.Finalized_completion_mismatch _)) -> ()
       | Error error -> fail (Shutdown_store.error_to_string error)
       | Ok () -> fail "store accepted completion outside supervisor cleanup intent");
      (match
         operation
         |> unsupported_shutdown_schema_fixture
         |> Shutdown_store.of_json
       with
       | Error (Shutdown_store.Decode_error _) -> ()
       | Error error -> fail (Shutdown_store.error_to_string error)
       | Ok _ -> fail "shutdown decoder accepted an unsupported schema");
      let loaded =
        match Shutdown_store.load ~config ~keeper_name:meta.name operation_id with
        | Ok loaded -> loaded
        | Error error -> fail (Shutdown_store.error_to_string error)
      in
      check string "shutdown keeper round-trip" operation.keeper_name loaded.keeper_name;
      (match operation.lane_ownership, loaded.lane_ownership with
       | Shutdown_types.Registered_lane expected,
         Shutdown_types.Registered_lane actual ->
         check bool
           "shutdown lane identity round-trip"
           true
           (Lane.Id.equal expected actual)
       | (Shutdown_types.Registered_lane _ | Shutdown_types.Dormant_meta), _ ->
         fail "shutdown lane ownership changed during round-trip");
      let joining =
        { loaded with
          revision = loaded.revision + 1
        ; phase = Shutdown_types.Joining_lanes
        ; updated_at = Masc_domain.now_iso ()
        }
      in
      (match Shutdown_store.replace ~config ~expected_revision:loaded.revision joining with
       | Ok () -> ()
       | Error error -> fail (Shutdown_store.error_to_string error));
      let joining_loaded =
        match Shutdown_store.load ~config ~keeper_name:meta.name operation_id with
        | Ok loaded -> loaded
        | Error error -> fail (Shutdown_store.error_to_string error)
      in
      (match joining_loaded.phase with
       | Shutdown_types.Joining_lanes -> ()
       | _ -> fail "durable lane-join phase did not round-trip");
      let joined =
        { joining_loaded with
          revision = joining_loaded.revision + 1
        ; phase = Shutdown_types.Joined_idle
        ; updated_at = Masc_domain.now_iso ()
        }
      in
      (match
         Shutdown_store.replace
           ~config
           ~expected_revision:joining_loaded.revision
           joined
       with
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
      let mismatched =
        { joined with
          lane_ownership = Shutdown_types.Registered_lane (Lane.id (Lane.create ()))
        }
      in
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
             (fun _intake_token ->
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
       | Shutdown_types.Joining_lanes
       | Shutdown_types.Joined_idle
       | Shutdown_types.Finalizing_tasks _
       | Shutdown_types.Cleanup_ready _
       | Shutdown_types.Reconciliation_required _
       | Shutdown_types.Finalized _
       | Shutdown_types.Blocked _
       | Shutdown_types.Superseded _ ->
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

let test_operator_update_supersedes_exact_blocked_shutdown () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  Eio.Switch.run @@ fun sw ->
  let base_dir = temp_dir "shutdown-supersession" in
  Fun.protect
    ~finally:(fun () ->
      cleanup_dir base_dir)
    (fun () ->
      let config = Masc.Workspace.default_config base_dir in
      let (_init_message : string) =
        Masc.Workspace.init config ~agent_name:(Some "tester")
      in
      install_owner_inventory_exn ~sw config;
      let backlog_version =
        match Workspace_backlog.read_backlog_r config with
        | Ok backlog -> backlog.version
        | Error detail -> fail detail
      in
      let operation ~name ~reason ~phase =
        let meta = make_meta name in
        ensure_owner_meta_exn config meta;
        let now = Masc_domain.now_iso () in
        { Shutdown_types.schema_version = Shutdown_types.schema_version
        ; revision = 0
        ; operation_id = Shutdown_types.Operation_id.generate ()
        ; keeper_name = name
        ; lane_ownership = Shutdown_types.Registered_lane (Lane.id (Lane.create ()))
        ; trace_id = meta.runtime.trace_id
        ; actor = "tester"
        ; cleanup_intent = { reason; remove_session = false }
        ; turn_disposition = Shutdown_types.No_inflight_turn
        ; expected_backlog_version = backlog_version
        ; owned_task_ids = []
        ; join_evidence = None
        ; phase
        ; created_at = now
        ; updated_at = now
        }
      in
      let blocked_phase =
        Shutdown_types.Blocked
          { stage = Shutdown_types.Record_update
          ; detail = "operator repair required"
          }
      in
      let blocked =
        operation
          ~name:"superseded-keeper"
          ~reason:Shutdown_types.Operator_stop_retain_meta
          ~phase:blocked_phase
      in
      (match Shutdown_store.persist_new ~config blocked with
       | Ok () -> ()
       | Error error -> fail (Shutdown_store.error_to_string error));
      let blocked_path =
        match
          Shutdown_store.path
            ~config
            ~keeper_name:blocked.keeper_name
            blocked.operation_id
        with
        | Ok path -> path
        | Error error -> fail (Shutdown_store.error_to_string error)
      in
      (match
         begin_owner_shutdown_exn
           ~base_path:config.base_path
           ~keeper_name:blocked.keeper_name
           ~operation_id:blocked.operation_id
       with
       | Masc.Keeper_owner.Shutdown_reserved _ -> ()
       | Masc.Keeper_owner.Shutdown_already_reserved _ ->
         fail "fixture admission was already reserved");
      let token =
        match
          Shutdown_supersession.preflight
            ~config
            ~keeper_name:blocked.keeper_name
            ~actor:"tester"
        with
        | Ok token -> token
        | Error error -> fail (Shutdown_supersession.error_to_string error)
      in
      let superseded =
        match Shutdown_supersession.commit_after_metadata_update ~config token with
        | Ok (Shutdown_supersession.Shutdown_superseded operation) -> operation
        | Ok Shutdown_supersession.No_shutdown_admission ->
          fail "blocked admission was not superseded"
        | Error error -> fail (Shutdown_supersession.error_to_string error)
      in
      check int
        "supersession keeps the current schema"
        Shutdown_types.schema_version
        superseded.schema_version;
      (match superseded.phase with
       | Shutdown_types.Superseded
           (Shutdown_types.Operator_metadata_update { actor }) ->
         check string "supersession preserves validated operator actor" "tester" actor
       | _ -> fail "blocked shutdown did not reach typed Superseded");
      let released =
        owner_shutdown_operation_id_exn
          ~base_path:config.base_path
          ~keeper_name:blocked.keeper_name
      in
      check (option string)
        "exact superseded admission is released"
        None
        (Option.map
           Shutdown_types.Operation_id.to_string
           released);
      let corrupt_owner_name = "superseded-corrupt-owner" in
      let corrupt_owner_blocked =
        operation
          ~name:corrupt_owner_name
          ~reason:Shutdown_types.Operator_stop_retain_meta
          ~phase:blocked_phase
      in
      let corrupt_sibling =
        operation
          ~name:corrupt_owner_name
          ~reason:Shutdown_types.Operator_stop_retain_meta
          ~phase:Shutdown_types.Prepared
      in
      (match Shutdown_store.persist_new ~config corrupt_owner_blocked with
       | Ok () -> ()
       | Error error -> fail (Shutdown_store.error_to_string error));
      (match Shutdown_store.persist_new ~config corrupt_sibling with
       | Ok () -> ()
       | Error error -> fail (Shutdown_store.error_to_string error));
      let corrupt_sibling_path =
        match
          Shutdown_store.path
            ~config
            ~keeper_name:corrupt_owner_name
            corrupt_sibling.operation_id
        with
        | Ok path -> path
        | Error error -> fail (Shutdown_store.error_to_string error)
      in
      (match
         Fs_compat.save_file_atomic
           corrupt_sibling_path
           (unsupported_shutdown_schema_fixture corrupt_sibling
            |> Yojson.Safe.to_string)
       with
       | Ok () -> ()
       | Error detail -> fail detail);
      (match
         begin_owner_shutdown_exn
           ~base_path:config.base_path
           ~keeper_name:corrupt_owner_name
           ~operation_id:corrupt_owner_blocked.operation_id
       with
       | Masc.Keeper_owner.Shutdown_reserved _ -> ()
       | Masc.Keeper_owner.Shutdown_already_reserved _ ->
         fail "corrupt-owner fixture admission was already reserved");
      let corrupt_owner_token =
        match
          Shutdown_supersession.preflight
            ~config
            ~keeper_name:corrupt_owner_name
            ~actor:"tester"
        with
        | Ok token -> token
        | Error error -> fail (Shutdown_supersession.error_to_string error)
      in
      (match
         Shutdown_supersession.commit_after_metadata_update
           ~config
           corrupt_owner_token
       with
       | Ok (Shutdown_supersession.Shutdown_superseded _) -> ()
       | Ok Shutdown_supersession.No_shutdown_admission ->
         fail "corrupt-owner blocked admission was not superseded"
       | Error error -> fail (Shutdown_supersession.error_to_string error));
      check
        (option string)
        "supersession hands admission directly to the corrupt sibling"
        (Some (Shutdown_types.Operation_id.to_string corrupt_sibling.operation_id))
        (Option.map
           Shutdown_types.Operation_id.to_string
           (owner_shutdown_operation_id_exn
              ~base_path:config.base_path
              ~keeper_name:corrupt_owner_name));
      let persisted_json =
        Fs_compat.load_file blocked_path |> Yojson.Safe.from_string
      in
      let persisted_schema =
        match persisted_json with
        | `Assoc fields ->
          (match List.assoc_opt "schema_version" fields with
           | Some (`Int version) -> version
           | _ -> fail "persisted supersession omitted schema_version")
        | _ -> fail "persisted supersession is not an object"
      in
      check int
        "supersession wire schema remains current"
        Shutdown_types.schema_version
        persisted_schema;
      (* #25491: a [Reconciliation_required] fence previously had no release
         path at all. The worker no-ops on it by design and supersession
         accepted only [Blocked], so the keeper was unreachable in every
         direction (RFC-0000 §1.2 LAW 1 "no dead-end"). Since #25522 boot
         recovery settles the phase automatically instead of minting it, so
         this operator route is now the manual fallback. These pin that the
         operator route releases it and that the accepted turn survives in the
         durable record, since [Superseded] overwrites the phase that carried
         it. *)
      let unreconciled_turn =
        { Shutdown_types.lane = Some Shutdown_types.Autonomous
        ; admitted_at = Some 1784545390.0
        ; observed_turn_id = Some 5744
        ; observation_started_at = Some 1784545390.5
        }
      in
      let reconciling =
        operation
          ~name:"reconciliation-keeper"
          ~reason:Shutdown_types.Operator_stop_retain_meta
          ~phase:(Shutdown_types.Reconciliation_required unreconciled_turn)
      in
      (match Shutdown_store.persist_new ~config reconciling with
       | Ok () -> ()
       | Error error -> fail (Shutdown_store.error_to_string error));
      (match
         begin_owner_shutdown_exn
           ~base_path:config.base_path
           ~keeper_name:reconciling.keeper_name
           ~operation_id:reconciling.operation_id
       with
       | Masc.Keeper_owner.Shutdown_reserved _ -> ()
       | Masc.Keeper_owner.Shutdown_already_reserved _ ->
         fail "reconciliation fixture admission was already reserved");
      let reconciling_token =
        match
          Shutdown_supersession.preflight
            ~config
            ~keeper_name:reconciling.keeper_name
            ~actor:"tester"
        with
        | Ok token -> token
        | Error error -> fail (Shutdown_supersession.error_to_string error)
      in
      let reconciling_superseded =
        match
          Shutdown_supersession.commit_after_metadata_update ~config reconciling_token
        with
        | Ok (Shutdown_supersession.Shutdown_superseded superseded_operation) ->
          superseded_operation
        | Ok Shutdown_supersession.No_shutdown_admission ->
          fail "reconciliation admission was not superseded"
        | Error error -> fail (Shutdown_supersession.error_to_string error)
      in
      (match reconciling_superseded.phase with
       | Shutdown_types.Superseded
           (Shutdown_types.Operator_reconciliation_accepted
              { actor; unreconciled_turn = recorded }) ->
         check
           string
           "reconciliation supersession preserves the validated operator actor"
           "tester"
           actor;
         check
           (option int)
           "the accepted turn is recorded so the audit says what was released"
           (Some 5744)
           recorded.observed_turn_id
       | _ ->
         fail "Reconciliation_required did not reach typed Superseded");
      let reconciling_released =
        owner_shutdown_operation_id_exn
          ~base_path:config.base_path
          ~keeper_name:reconciling.keeper_name
      in
      check
        (option string)
        "releasing the reconciliation fence frees exact admission"
        None
        (Option.map
           Shutdown_types.Operation_id.to_string
           reconciling_released);
      let invalid_superseded =
        { superseded with
          operation_id = Shutdown_types.Operation_id.generate ()
        ; cleanup_intent =
            { reason = Shutdown_types.Operator_stop_remove_meta
            ; remove_session = false
            }
        }
      in
      (match Shutdown_store.persist_new ~config invalid_superseded with
       | Error
           (Shutdown_store.Invalid_operation
             (Shutdown_types.Superseded_cleanup_reason_mismatch _)) -> ()
       | Error error -> fail (Shutdown_store.error_to_string error)
       | Ok () -> fail "Superseded accepted a non-retained cleanup intent");
      (match
         restore_owner_shutdown_exn
           ~base_path:config.base_path
           ~keeper_name:blocked.keeper_name
           ~operation_id:blocked.operation_id
       with
       | Masc.Keeper_owner.Shutdown_restored -> ()
       | Masc.Keeper_owner.Shutdown_already_restored
       | Masc.Keeper_owner.Shutdown_restore_conflict _ ->
         fail "crash-window admission fixture could not be restored");
      let retry_token =
        match
          Shutdown_supersession.preflight
            ~config
            ~keeper_name:blocked.keeper_name
            ~actor:"tester"
        with
        | Ok token -> token
        | Error error -> fail (Shutdown_supersession.error_to_string error)
      in
      (match
         Shutdown_supersession.commit_after_metadata_update
           ~config
           retry_token
       with
       | Ok (Shutdown_supersession.Shutdown_superseded _) -> ()
       | Ok Shutdown_supersession.No_shutdown_admission ->
         fail "idempotent supersession lost the exact admission owner"
       | Error error -> fail (Shutdown_supersession.error_to_string error));
      let inventory =
        match Shutdown_store.scan_inventory ~config with
        | Ok inventory -> inventory
        | Error error -> fail (Shutdown_store.error_to_string error)
      in
      (match Shutdown_runtime.restore_inventory_admission ~config inventory with
       | Error detail -> fail detail
       | Ok restored ->
         check
           (list string)
           "boot restore fences only the corrupt sibling owner"
           [ corrupt_owner_name ]
           restored.blocked_keeper_names;
         check
           (option string)
           "boot restore keeps the superseded owner's corrupt identity"
           (Some (Shutdown_types.Operation_id.to_string corrupt_sibling.operation_id))
           (Option.map
              Shutdown_types.Operation_id.to_string
              (owner_shutdown_operation_id_exn
                 ~base_path:config.base_path
                 ~keeper_name:corrupt_owner_name)));

      let conflict =
        operation
          ~name:"supersession-conflict"
          ~reason:Shutdown_types.Operator_stop_retain_meta
          ~phase:blocked_phase
      in
      (match Shutdown_store.persist_new ~config conflict with
       | Ok () -> ()
       | Error error -> fail (Shutdown_store.error_to_string error));
      ignore
        (begin_owner_shutdown_exn
           ~base_path:config.base_path
           ~keeper_name:conflict.keeper_name
           ~operation_id:conflict.operation_id
          : Masc.Keeper_owner.begin_shutdown_result);
      let conflict_token =
        match
          Shutdown_supersession.preflight
            ~config
            ~keeper_name:conflict.keeper_name
            ~actor:"tester"
        with
        | Ok token -> token
        | Error error -> fail (Shutdown_supersession.error_to_string error)
      in
      let concurrently_advanced =
        { conflict with
          revision = conflict.revision + 1
        ; phase =
            Shutdown_types.Blocked
              { stage = Shutdown_types.Meta_update
              ; detail = "new durable failure"
              }
        }
      in
      (match
         Shutdown_store.replace
           ~config
           ~expected_revision:conflict.revision
           concurrently_advanced
       with
       | Ok () -> ()
       | Error error -> fail (Shutdown_store.error_to_string error));
      (match
         Shutdown_supersession.commit_after_metadata_update
           ~config
           conflict_token
       with
       | Error
           (Shutdown_supersession.Metadata_committed_supersession_failed
             (Shutdown_store.Revision_conflict _)) -> ()
       | Error error -> fail (Shutdown_supersession.error_to_string error)
       | Ok _ -> fail "stale preflight token superseded a newer revision");
      let still_fenced =
        owner_shutdown_operation_id_exn
          ~base_path:config.base_path
          ~keeper_name:conflict.keeper_name
      in
      check (option string)
        "failed supersession leaves exact admission fenced"
        (Some (Shutdown_types.Operation_id.to_string conflict.operation_id))
        (Option.map
           Shutdown_types.Operation_id.to_string
           still_fenced);

      let live_name = "update-blocked-admission" in
      let live_meta = { (make_meta live_name) with paused = true } in
      create_owner_meta_exn config live_meta;
      let live_blocked =
        { (operation
             ~name:live_name
             ~reason:Shutdown_types.Operator_stop_retain_meta
             ~phase:blocked_phase) with
          trace_id = live_meta.runtime.trace_id
        }
      in
      (match Shutdown_store.persist_new ~config live_blocked with
       | Ok () -> ()
       | Error error -> fail (Shutdown_store.error_to_string error));
      ignore
        (begin_owner_shutdown_exn
           ~base_path:config.base_path
           ~keeper_name:live_name
           ~operation_id:live_blocked.operation_id
          : Masc.Keeper_owner.begin_shutdown_result);
      let profile_defaults =
        { Keeper_profile_defaults.empty_keeper_profile_defaults with
          sandbox_profile = Some live_meta.sandbox_profile
        }
      in
      let parsed : Turn_up_args.parsed_args =
        { name = live_name
        ; runtime_id_opt = None
        ; autoboot_enabled_opt = None
        ; mention_targets_opt = None
        ; max_context_override_opt = None
        ; max_context_override_present = false
        ; proactive_enabled_opt = None
        ; sandbox_profile_opt = None
        ; network_mode_opt = None
        ; remote_endpoint_opt = None
        ; remote_endpoint_present = false
        ; skill_names_opt = None
        ; skill_names_present = false
        ; native_tool_posture_opt = None
        ; native_tool_posture_present = false
        ; instructions_arg = Some "new operator intent"
        ; profile_defaults
        ; declarative_manifest_snapshot =
            Keeper_types_profile.Declarative_manifest_missing
        ; instructions_opt = profile_defaults.instructions
        }
      in
      let ctx : _ Keeper_types_profile.context =
        { config
        ; agent_name = "tester"
        ; sw
        ; clock = Eio.Stdenv.clock env
        ; proc_mgr = None
        ; net = None
        ; publication_recovery_provider =
            Masc_test_deps.non_runtime_publication_recovery_provider
        }
      in
      let result =
        Turn_up_update.update_keeper
          ~expected_config_revision:(config_revision_exn config live_name)
          ctx
          parsed
          live_meta
      in
      check bool
        "keeper_up restarts despite the stale blocked admission"
        true
        (Keeper_types_profile.tool_result_success result);
      let live_operation =
        match
          Shutdown_store.load
            ~config
            ~keeper_name:live_name
            live_blocked.operation_id
        with
        | Ok operation -> operation
        | Error error -> fail (Shutdown_store.error_to_string error)
      in
      (match live_operation.phase with
       | Shutdown_types.Superseded
           (Shutdown_types.Operator_metadata_update { actor = "tester" }) -> ()
       | _ -> fail "update_keeper did not supersede the blocked operator stop");
      let live_after =
        match Keeper_meta_store.read_meta config live_name with
        | Ok (Some meta) -> meta
        | Ok None -> fail "update_keeper removed retained metadata"
        | Error detail -> fail detail
      in
      check bool "update_keeper persisted the new resume intent" false live_after.paused;
      ignore
        (Masc.Keeper_keepalive.stop_keepalive_and_await
           ~base_path:config.base_path
           live_name
          : Masc.Keeper_keepalive.joined_stop_result);

      let stale_name = "stale-up-does-not-resume-operator-pause" in
      let stale_meta =
        Shutdown_finalize.For_testing.paused_meta (make_meta stale_name)
      in
      create_owner_meta_exn config stale_meta;
      let stale_parsed =
        { parsed with
          name = stale_name
        ; instructions_arg = Some "stale operator intent"
        }
      in
      let initial_revision =
        let missing_revision = config_revision_exn config stale_name in
        match
          Turn_up_config_persistence.persist
            ~expected_revision:missing_revision
            ~config
            ~parsed:stale_parsed
            ~meta:{ stale_meta with instructions = "initial manifest" }
            ()
        with
        | Ok _ -> config_revision_exn config stale_name
        | Error error ->
          fail (Turn_up_config_persistence.error_to_string error)
      in
      let winner_parsed =
        { stale_parsed with instructions_arg = Some "winning manifest" }
      in
      (match
         Turn_up_config_persistence.persist
           ~expected_revision:initial_revision
           ~config
           ~parsed:winner_parsed
           ~meta:{ stale_meta with instructions = "winning manifest" }
           ()
       with
       | Ok _ -> ()
       | Error error ->
         fail (Turn_up_config_persistence.error_to_string error));
      let manifest_path =
        Config_dir_resolver.keepers_dir_for_base_path ~base_path:config.base_path
        |> fun dir -> Filename.concat dir (stale_name ^ ".toml")
      in
      let receipt_root =
        let keeper_hash =
          Digestif.SHA256.(digest_string stale_name |> to_hex)
        in
        Filename.concat
          (Filename.concat
             (Workspace.masc_root_dir config)
             ("paused-work-dispositions-"
              ^ Paused_work_receipt.store_version))
          ("keeper-" ^ keeper_hash)
      in
      let trace_id =
        Keeper_id.Trace_id.to_string stale_meta.runtime.trace_id
      in
      let checkpoint_path =
        Keeper_checkpoint_store.agent_core_checkpoint_path
          ~session_dir:
            (Filename.concat
               (Keeper_types_profile.session_base_dir config)
               trace_id)
          ~session_id:trace_id
      in
      let runtime_path =
        Config_dir_resolver.runtime_toml_path_for_base_path
          ~base_path:config.base_path
      in
      let meta_snapshot () =
        match Keeper_meta_store.read_meta config stale_name with
        | Ok (Some meta) ->
          Keeper_meta_json.meta_to_json meta |> Yojson.Safe.to_string
        | Ok None -> "missing"
        | Error detail -> fail detail
      in
      let authority_snapshot () =
        ( snapshot_path manifest_path
        , snapshot_path receipt_root
        , snapshot_path runtime_path
        , snapshot_path checkpoint_path
        , meta_snapshot () )
      in
      let before_stale_update = authority_snapshot () in
      let stale_result =
        Turn_up_update.update_keeper
          ~expected_config_revision:initial_revision
          ctx
          stale_parsed
          stale_meta
      in
      check bool "stale paused update is rejected by manifest CAS" true
        (Option.is_some
           (Turn_up_update.config_revision_conflict_of_result stale_result));
      check bool
        "stale paused update leaves manifest, receipt, runtime, checkpoint, and meta unchanged"
        true
        (authority_snapshot () = before_stale_update);
      (match Keeper_meta_store.read_meta config stale_name with
       | Ok (Some meta) ->
         check bool "stale update leaves pause bit set" true meta.paused
       | Ok None -> fail "stale update removed paused metadata"
       | Error detail -> fail detail);
      let before_profile_failure = authority_snapshot () in
      let profile_failure_result =
        Turn_up_update.For_testing.update_keeper_with_apply_profile
          ~apply_profile:(fun ~base_path:_ ~keeper_name _command ->
            Error
              (Keeper_owner_registry.Command_lookup_failed
                 (Keeper_owner_registry.Owner_not_found keeper_name)))
          ~expected_config_revision:(config_revision_exn config stale_name)
          ctx
          stale_parsed
          stale_meta
      in
      check bool "profile failure is reported as unapplied" true
        (Option.is_some
           (Turn_up_update.config_publication_rollback_of_result
              profile_failure_result));
      check bool
        "profile failure before resume leaves pause receipt, meta, manifest, runtime, and checkpoint unchanged"
        true
        (authority_snapshot () = before_profile_failure);

      let stopped_name = "explicit-up-resumes-operator-stop" in
      let stopped_meta =
        Shutdown_finalize.For_testing.paused_meta (make_meta stopped_name)
      in
      create_owner_meta_exn config stopped_meta;
      let stopped_parsed =
        { parsed with
          name = stopped_name
        ; instructions_arg = Some "resume this stopped keeper"
        }
      in
      let stopped_result =
        Turn_up_update.update_keeper
          ~expected_config_revision:(config_revision_exn config stopped_name)
          ctx
          stopped_parsed
          stopped_meta
      in
      check bool
        "explicit keeper_up resumes an operator-stopped keeper"
        true
        (Keeper_types_profile.tool_result_success stopped_result);
      let stopped_after =
        match Keeper_meta_store.read_meta config stopped_name with
        | Ok (Some meta) -> meta
        | Ok None -> fail "explicit keeper_up removed stopped metadata"
        | Error detail -> fail detail
      in
      check bool
        "explicit keeper_up clears the operator pause"
        false
        stopped_after.paused;
      check (option string)
        "explicit keeper_up clears the operator pause latch"
        None
        (Option.map
           Keeper_latched_reason.to_wire
           stopped_after.latched_reason);
      ignore
        (Masc.Keeper_keepalive.stop_keepalive_and_await
           ~base_path:config.base_path
           stopped_name
          : Masc.Keeper_keepalive.joined_stop_result))

let test_update_keeper_rejects_lane_swap_while_turn_in_flight () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  Eio.Switch.run @@ fun sw ->
  let base_dir = temp_dir "update-turn-in-flight" in
  Fun.protect
    ~finally:(fun () ->
      cleanup_dir base_dir)
    (fun () ->
      let config = Masc.Workspace.default_config base_dir in
      let (_init_message : string) =
        Masc.Workspace.init config ~agent_name:(Some "tester")
      in
      install_owner_inventory_exn ~sw config;
      let name = "update-turn-in-flight" in
      let meta = make_meta name in
      create_owner_meta_exn config meta;
      let profile_defaults =
        { Keeper_profile_defaults.empty_keeper_profile_defaults with
          sandbox_profile = Some meta.sandbox_profile
        }
      in
      let parsed : Turn_up_args.parsed_args =
        { name
        ; runtime_id_opt = None
        ; autoboot_enabled_opt = None
        ; mention_targets_opt = None
        ; max_context_override_opt = None
        ; max_context_override_present = false
        ; proactive_enabled_opt = None
        ; sandbox_profile_opt = None
        ; network_mode_opt = None
        ; remote_endpoint_opt = None
        ; remote_endpoint_present = false
        ; skill_names_opt = None
        ; skill_names_present = false
        ; native_tool_posture_opt = None
        ; native_tool_posture_present = false
        ; instructions_arg = Some "rejected mid-turn intent"
        ; profile_defaults
        ; declarative_manifest_snapshot =
            Keeper_types_profile.Declarative_manifest_missing
        ; instructions_opt = profile_defaults.instructions
        }
      in
      let ctx : _ Keeper_types_profile.context =
        { config
        ; agent_name = "tester"
        ; sw
        ; clock = Eio.Stdenv.clock env
        ; proc_mgr = None
        ; net = None
        ; publication_recovery_provider =
            Masc_test_deps.non_runtime_publication_recovery_provider
        }
      in
      (* A keeper's own turn holds the slot while its tools run: invoking
         the update from inside the admitted closure reproduces the
         mid-turn self masc_keeper_up of #26542 structurally. *)
      (match
         Keeper_owner_registry.run_maintenance_if_idle
           ~base_path:config.base_path
           ~keeper_name:name
           (fun () ->
             Turn_up_update.update_keeper
               ~expected_config_revision:(config_revision_exn config name)
               ctx
               parsed
               meta)
       with
       | Error error -> fail (Keeper_owner_registry.command_error_to_string error)
       | Ok (`Busy _) -> fail "Owner unexpectedly busy before the test turn"
       | Ok (`Ran result) ->
         check bool "mid-turn update is rejected" false
           (Keeper_types_profile.tool_result_success result);
         let data = Tool_result.data result in
         check (option string) "rejection is typed"
           (Some "keeper_turn_in_flight")
           (Json_util.get_string data "error");
         check bool "rejection rolls the fence back inside the turn" true
           (Option.is_none
              (owner_shutdown_operation_id_exn
                 ~base_path:config.base_path
                 ~keeper_name:name)));
      let after =
        match Keeper_meta_store.read_meta config name with
        | Ok (Some after) -> after
        | Ok None -> fail "keeper metadata disappeared"
        | Error detail -> fail detail
      in
      check string "metadata commit preceded the rejection"
        "rejected mid-turn intent"
        after.instructions;
      check bool "no shutdown fence remains after the turn" true
        (Option.is_none
           (owner_shutdown_operation_id_exn
              ~base_path:config.base_path
              ~keeper_name:name));
      check bool "Keeper Owner is idle after the turn" true
        (Option.is_none
           (owner_turn_in_flight_exn
              ~base_path:config.base_path
              ~keeper_name:name));
      let retry =
        Turn_up_update.update_keeper
          ~expected_config_revision:(config_revision_exn config name)
          ctx
          parsed
          after
      in
      check bool "idle update restarts the lane" true
        (Keeper_types_profile.tool_result_success retry);
      ignore
        (Masc.Keeper_keepalive.stop_keepalive_and_await
           ~base_path:config.base_path
           name
          : Masc.Keeper_keepalive.joined_stop_result))

let test_update_keeper_cancellation_finishes_lane_swap () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  R.For_testing.clear ();
  Memory_lane.For_testing.reset ();
  let base_dir = temp_dir "update-cancelled-lane-swap" in
  let name = "update-cancelled-lane-swap" in
  Fun.protect
    ~finally:(fun () ->
      Masc.Keeper_keepalive.stop_keepalive ~base_path:base_dir name;
      Memory_lane.For_testing.reset ();
      R.For_testing.clear ();
      cleanup_dir base_dir)
    (fun () ->
      ensure_default_runtime ();
      let config = Masc.Workspace.default_config base_dir in
      ignore (Masc.Workspace.init config ~agent_name:(Some "tester"));
      seed_keeper_sandbox_profile ~base_dir name;
      Eio.Switch.run @@ fun root_sw ->
      install_owner_inventory_exn ~sw:root_sw config;
      Memory_lane.init ~sw:root_sw;
      let clock = Eio.Stdenv.clock env in
      let meta =
        { (make_meta name) with
          proactive = { enabled = false }
        }
      in
      create_owner_meta_exn config meta;
      let ctx : _ Keeper_types_profile.context =
        { config
        ; agent_name = "tester"
        ; sw = root_sw
        ; clock
        ; proc_mgr = Some (Eio.Stdenv.process_mgr env)
        ; net = None
        ; publication_recovery_provider =
            Masc_test_deps.publication_recovery_provider
              (publication_recovery_registry env root_sw config)
        }
      in
      (match Masc.Keeper_keepalive.start_keepalive ctx meta with
       | Masc.Keeper_keepalive.Keepalive_started _ -> ()
       | outcome ->
         failf
           "cancelled-update fixture failed to start: %s"
           (Masc.Keeper_keepalive.start_keepalive_outcome_to_string outcome));
      Eio.Time.sleep clock 0.05;
      let librarian_started, resolve_librarian_started = Eio.Promise.create () in
      let release_librarian, resolve_release_librarian = Eio.Promise.create () in
      (match
         Memory_lane.submit
           ~base_path:config.base_path
           ~keeper_name:name
           (fun () ->
              Eio.Promise.resolve resolve_librarian_started ();
              Eio.Promise.await release_librarian)
       with
       | Memory_lane.Submitted -> ()
       | Memory_lane.Coalesced
       | Memory_lane.Ran_inline
       | Memory_lane.Dropped
       | Memory_lane.Rejected_draining ->
         fail "cancelled-update Librarian fixture was not submitted");
      Eio.Promise.await librarian_started;
      let profile_defaults =
        { Keeper_profile_defaults.empty_keeper_profile_defaults with
          sandbox_profile = Some meta.sandbox_profile
        }
      in
      let parsed : Turn_up_args.parsed_args =
        { name
        ; runtime_id_opt = None
        ; autoboot_enabled_opt = None
        ; mention_targets_opt = None
        ; max_context_override_opt = None
        ; max_context_override_present = false
        ; proactive_enabled_opt = Some false
        ; sandbox_profile_opt = None
        ; network_mode_opt = None
        ; remote_endpoint_opt = None
        ; remote_endpoint_present = false
        ; skill_names_opt = None
        ; skill_names_present = false
        ; native_tool_posture_opt = None
        ; native_tool_posture_present = false
        ; instructions_arg = Some "durable cancelled update"
        ; profile_defaults
        ; declarative_manifest_snapshot =
            Keeper_types_profile.Declarative_manifest_missing
        ; instructions_opt = profile_defaults.instructions
        }
      in
      let update_switch, resolve_update_switch = Eio.Promise.create () in
      let update_done, resolve_update_done = Eio.Promise.create () in
      Eio.Fiber.fork ~sw:root_sw (fun () ->
        let disposition =
          try
            Eio.Switch.run @@ fun update_sw ->
            Eio.Promise.resolve resolve_update_switch update_sw;
            ignore
              (Turn_up_update.update_keeper
                 ~expected_config_revision:(config_revision_exn config name)
                 ctx
                 parsed
                 meta);
            `Returned
          with
          | Cancel_keeper_up_after_metadata -> `Cancelled
        in
        Eio.Promise.resolve resolve_update_done disposition);
      let update_sw = Eio.Promise.await update_switch in
      Eio.Time.with_timeout_exn clock 1.0 (fun () ->
        let rec await_lane_swap_fence () =
          match
            owner_shutdown_operation_id_exn
              ~base_path:config.base_path
              ~keeper_name:name
          with
          | Some _ -> ()
          | None ->
            Eio.Fiber.yield ();
            await_lane_swap_fence ()
        in
        await_lane_swap_fence ());
      Eio.Switch.fail update_sw Cancel_keeper_up_after_metadata;
      Eio.Promise.resolve resolve_release_librarian ();
      (match Eio.Promise.await update_done with
       | `Cancelled -> ()
       | `Returned -> fail "keeper update returned after its caller was cancelled");
      check bool
        "cancelled update rolls back its temporary shutdown fence"
        true
        (Option.is_none
           (owner_shutdown_operation_id_exn
              ~base_path:config.base_path
              ~keeper_name:name));
      (match R.get ~base_path:config.base_path name with
       | Some entry ->
         check string
           "cancelled update finishes the lane restart"
           "running"
           (KSM.phase_to_string entry.phase);
         check bool "replacement lane remains live" false (R.lane_has_exited entry)
       | None -> fail "cancelled update left the Keeper unregistered");
      ignore
        (Masc.Keeper_keepalive.stop_keepalive_and_await
           ~base_path:config.base_path
           name
          : Masc.Keeper_keepalive.joined_stop_result))
;;

let test_keeper_up_shared_boundary_outlives_calling_turn () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let base_dir = temp_dir "cross-keeper-up-lifetime" in
  let target_name = "cross-keeper-target" in
  let previous_startup_state = Masc.Server_startup_state.snapshot () in
  Fun.protect
    ~finally:(fun () ->
      Masc.Server_startup_state.For_testing.restore previous_startup_state;
      R.For_testing.clear ();
      cleanup_dir base_dir)
    (fun () ->
      ensure_default_runtime ();
      let config = Masc.Workspace.default_config base_dir in
      ignore (Masc.Workspace.init config ~agent_name:(Some "beta"));
      seed_keeper_sandbox_profile ~base_dir target_name;
      ignore Masc.Keeper_tool_surface.schemas;
      Masc.Server_startup_state.reset ();
      (match
         Masc.Server_startup_state.mark_state_ready ()
       with
       | Ok () -> ()
       | Error error ->
         fail (Masc.Server_startup_state.state_ready_error_to_string error));
      let clock = Eio.Stdenv.clock env in
      Eio.Switch.run @@ fun root_sw ->
      install_owner_inventory_exn ~sw:root_sw config;
      Eio_context.with_test_env
        ~net:(Eio.Stdenv.net env)
        ~clock
        ~mono_clock:(Eio.Stdenv.mono_clock env)
        ~sw:root_sw
      @@ fun () ->
      Masc_test_deps.with_publication_recovery_registry
        ~sw:root_sw
        ~fs:(Eio.Stdenv.fs env)
        ~registry_root:(Workspace.masc_root_dir config)
      @@ fun publication_recovery_registry ->
      let stop_target () =
        ignore
          (Masc.Keeper_keepalive.stop_keepalive_and_await
             ~base_path:config.base_path
             target_name
            : Masc.Keeper_keepalive.joined_stop_result)
      in
      Fun.protect
        ~finally:stop_target
        (fun () ->
          let result =
            try
              Some
                (Eio.Time.with_timeout_exn clock 1.0 (fun () ->
                   Eio.Switch.run @@ fun turn_sw ->
                   Eio_context.with_turn_switch turn_sw @@ fun () ->
                   let ctx : _ Masc.Keeper_tool_surface.context =
                     { config
                     ; agent_name = "beta"
                     ; sw = turn_sw
                     ; clock
                     ; proc_mgr = None
                     ; net = None
                     ; publication_recovery_provider =
                         Masc_test_deps.publication_recovery_provider
                           publication_recovery_registry
                     }
                   in
                   Masc.Keeper_tool_surface.dispatch
                     ctx
                     ~name:"masc_keeper_up"
                     ~args:
                       (`Assoc
                          [ "name", `String target_name
                          ; "proactive_enabled", `Bool false
                          ; "autoboot_enabled", `Bool false
                          ])))
            with
            | Eio.Time.Timeout -> None
          in
          let result =
            match result with
            | Some (Some result) -> result
            | Some None -> fail "masc_keeper_up dispatch was missing"
            | None ->
              fail
                "the calling Keeper turn waited for the target's long-lived lane"
          in
          if not (Keeper_types_profile.tool_result_success result)
          then
            fail
              ("cross-keeper up failed: "
               ^ Yojson.Safe.to_string (Tool_result.data result));
          match R.get ~base_path:config.base_path target_name with
          | None -> fail "target Keeper lane was not registered"
          | Some entry ->
            check bool
              "target lane remains alive after the calling turn closes"
              false
              (R.lane_has_exited entry)))
;;

let test_keeper_shutdown_store_isolates_corrupt_owner () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  Eio.Switch.run @@ fun sw ->
  let base_dir = temp_dir "shutdown-store-corrupt-owner" in
  Fun.protect
    ~finally:(fun () ->
      cleanup_dir base_dir)
    (fun () ->
      let config = Masc.Workspace.default_config base_dir in
      let (_init_message : string) =
        Masc.Workspace.init config ~agent_name:(Some "tester")
      in
      install_owner_inventory_exn ~sw config;
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
        ensure_owner_meta_exn config meta;
        let now = Masc_domain.now_iso () in
        let operation : Shutdown_types.t =
          { schema_version = Shutdown_types.schema_version
          ; revision = 0
          ; operation_id = Shutdown_types.Operation_id.generate ()
          ; keeper_name = meta.name
          ; lane_ownership =
              Shutdown_types.Registered_lane (Lane.id (Lane.create ()))
          ; trace_id = meta.runtime.trace_id
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
         owner_shutdown_operation_id_exn
           ~base_path:config.base_path
           ~keeper_name:corrupt_operation.keeper_name
       with
       | Some operation_id ->
         check bool
           "corrupt owner fence retains durable operation id"
           true
           (Shutdown_types.Operation_id.equal
              corrupt_operation.operation_id
              operation_id)
       | None ->
         fail "corrupt owner admission was reopened");
      match Shutdown_runtime.recover_operation ~config recoverable_operation with
      | Ok recovered ->
        check bool
          "unrelated blocked operation remains explicitly recoverable"
          true
          (recovered.phase = recoverable_operation.phase)
      | Error detail -> fail detail)

let test_terminal_shutdown_recovery_releases_admission () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let base_dir = temp_dir "terminal-shutdown-recovery-release" in
  Fun.protect
    ~finally:(fun () -> cleanup_dir base_dir)
    (fun () ->
      let config = Masc.Workspace.default_config base_dir in
      let (_init_message : string) =
        Masc.Workspace.init config ~agent_name:(Some "tester")
      in
      let meta = make_meta "terminal-recovery-owner" in
      let now = Masc_domain.now_iso () in
      let terminal =
        { Shutdown_types.schema_version = Shutdown_types.schema_version
        ; revision = 0
        ; operation_id = Shutdown_types.Operation_id.generate ()
        ; keeper_name = meta.name
        ; lane_ownership = Shutdown_types.Dormant_meta
        ; trace_id = meta.runtime.trace_id
        ; actor = "tester"
        ; cleanup_intent = retain_operator_cleanup
        ; turn_disposition = Shutdown_types.No_inflight_turn
        ; expected_backlog_version = 0
        ; owned_task_ids = []
        ; join_evidence = None
        ; phase =
            Shutdown_types.Superseded
              (Shutdown_types.Operator_metadata_update { actor = "tester" })
        ; created_at = now
        ; updated_at = now
        }
      in
      Eio.Switch.run @@ fun sw ->
      install_owner_inventory_exn ~sw config;
      ensure_owner_meta_exn config meta;
      (match
         restore_owner_shutdown_exn
           ~base_path:config.base_path
           ~keeper_name:terminal.keeper_name
           ~operation_id:terminal.operation_id
       with
       | Masc.Keeper_owner.Shutdown_restored -> ()
       | Masc.Keeper_owner.Shutdown_already_restored
       | Masc.Keeper_owner.Shutdown_restore_conflict _ ->
         fail "terminal recovery fixture could not restore exact admission");
      (match
         Shutdown_runtime.recover_operation_with_corrupt_owner_fence
           ~config
           ~corrupt_owner_fence:None
           terminal
       with
       | Ok recovered ->
         check bool
           "terminal shutdown remains terminal"
           false
           (Shutdown_types.requires_admission_fence recovered)
       | Error detail -> fail detail);
      check
        (option string)
        "terminal recovery releases exact admission"
        None
        (Option.map
           Shutdown_types.Operation_id.to_string
           (owner_shutdown_operation_id_exn
              ~base_path:config.base_path
              ~keeper_name:terminal.keeper_name)))

let test_unsupported_shutdown_schema_retains_exact_fence () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let base_dir = temp_dir "unsupported-shutdown-schema" in
  Fun.protect
    ~finally:(fun () ->
      cleanup_dir base_dir)
    (fun () ->
      let config = Masc.Workspace.default_config base_dir in
      let (_init_message : string) =
        Masc.Workspace.init config ~agent_name:(Some "tester")
      in
      Eio.Switch.run @@ fun sw ->
      install_owner_inventory_exn ~sw config;
      let backlog_version =
        match Workspace_backlog.read_backlog_r config with
        | Ok backlog -> backlog.version
        | Error detail -> fail detail
      in
      let meta = make_meta "unsupported-schema-owner" in
      ensure_owner_meta_exn config meta;
      let operation_id = Shutdown_types.Operation_id.generate () in
      let now = Masc_domain.now_iso () in
      let operation : Shutdown_types.t =
        { schema_version = Shutdown_types.schema_version
        ; revision = 0
        ; operation_id
        ; keeper_name = meta.name
        ; lane_ownership = Shutdown_types.Registered_lane (Lane.id (Lane.create ()))
        ; trace_id = meta.runtime.trace_id
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
      let current_operation =
        { operation with operation_id = Shutdown_types.Operation_id.generate () }
      in
      (match Shutdown_store.persist_new ~config current_operation with
       | Ok () -> ()
       | Error error -> fail (Shutdown_store.error_to_string error));
      let operation_path =
        match Shutdown_store.path ~config ~keeper_name:meta.name operation_id with
        | Ok path -> path
        | Error error -> fail (Shutdown_store.error_to_string error)
      in
      (match
         Fs_compat.save_file_atomic
           operation_path
           (unsupported_shutdown_schema_fixture operation |> Yojson.Safe.to_string)
       with
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
       | [ current ] ->
         check bool
           "current row for corrupt owner remains stored"
           true
           (Shutdown_types.Operation_id.equal
              current_operation.operation_id
              current.operation_id)
       | _ -> fail "current row for corrupt owner changed inventory cardinality");
      (match corrupt_records with
       | [ corrupt ] ->
         check string "unsupported row keeps its path owner" meta.name corrupt.keeper_name;
         check bool
           "unsupported row keeps its operation identity"
           true
           (Shutdown_types.Operation_id.equal operation_id corrupt.operation_id)
       | _ -> fail "unsupported row was not isolated as one corrupt record");
      let restored =
        match Shutdown_runtime.restore_inventory_admission ~config inventory with
        | Ok restored -> restored
        | Error detail -> fail detail
      in
      check
        (list string)
        "unsupported row keeps its owner fenced"
        [ meta.name ]
        restored.blocked_keeper_names;
      check int "unsupported row remains explicit" 1
        (List.length restored.corrupt_records);
      check int "corrupt owner current operation remains recoverable" 1
        (List.length restored.operations);
      (match restored.operations with
       | [ recoverable ] ->
         check bool
           "current operation owns admission during recovery"
           true
           (Shutdown_types.Operation_id.equal
              current_operation.operation_id
              recoverable.operation_id)
       | _ -> fail "corrupt owner current recovery cardinality changed");
      check
        (option string)
        "current operation owns the initial fence"
        (Some (Shutdown_types.Operation_id.to_string current_operation.operation_id))
        (Option.map
           Shutdown_types.Operation_id.to_string
           (owner_shutdown_operation_id_exn
              ~base_path:config.base_path
              ~keeper_name:meta.name));
      (match restored.corrupt_owner_fences with
       | [ fence ] ->
         (match
            transition_owner_shutdown_exn
              ~base_path:config.base_path
              ~keeper_name:meta.name
              ~from_operation_id:current_operation.operation_id
              ~to_operation_id:(Some fence.operation_id)
          with
          | Masc.Keeper_owner.Shutdown_transition_applied -> ()
          | Masc.Keeper_owner.Shutdown_transition_already_applied
          | Masc.Keeper_owner.Shutdown_transition_reserved_by_other _ ->
            fail "current operation did not hand admission to its corrupt sibling")
       | _ -> fail "corrupt owner fence cardinality changed");
      check
        (option string)
        "corrupt owner fence is restored after current recovery"
        (Some (Shutdown_types.Operation_id.to_string operation_id))
        (Option.map
           Shutdown_types.Operation_id.to_string
           (owner_shutdown_operation_id_exn
              ~base_path:config.base_path
              ~keeper_name:meta.name)))

let test_dashboard_purge_resolution_is_fail_closed () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let base_dir = temp_dir "dashboard-purge-resolution" in
  Fun.protect
    ~finally:(fun () ->
      R.For_testing.clear ();
      cleanup_dir base_dir)
    (fun () ->
      let config = Masc.Workspace.default_config base_dir in
      let (_init_message : string) =
        Masc.Workspace.init config ~agent_name:(Some "operator")
      in
      Eio.Switch.run @@ fun sw ->
      install_owner_inventory_exn ~sw config;
      (match Dashboard_purge.resolve config "plain-agent" with
       | Ok None -> ()
       | Ok (Some _) -> fail "plain agent was classified as a Keeper"
       | Error error -> fail (Dashboard_purge.resolve_error_to_string error));
      (match Dashboard_purge.resolve config "plain:agent" with
       | Ok None -> ()
       | Ok (Some _) -> fail "namespaced plain agent was classified as a Keeper"
       | Error error -> fail (Dashboard_purge.resolve_error_to_string error));
      let long_name = String.make 75 'k' in
      let long_meta = { (make_meta "dashboard-purge-long") with name = long_name } in
      create_owner_meta_exn config long_meta;
      (match Dashboard_purge.existing_operation config long_name with
       | Ok None -> ()
       | Ok (Some _) -> fail "long-name Keeper unexpectedly had a purge operation"
       | Error error -> fail (Dashboard_purge.resolve_error_to_string error));
      (match Dashboard_purge.resolve config long_name with
       | Ok (Some target) ->
         check string "resolved long Keeper name" long_name target.keeper_name
       | Ok None -> fail "long-name Keeper fell through to plain-agent purge"
       | Error error -> fail (Dashboard_purge.resolve_error_to_string error));
      (match
         Dashboard_purge.resolve
           config
           (String.make (Keeper_id.Keeper_name.max_length + 1) 'k')
       with
       | Error (Dashboard_purge.Invalid_requested_name _) -> ()
       | Error error -> fail (Dashboard_purge.resolve_error_to_string error)
       | Ok _ -> fail "Keeper name beyond the creation limit was accepted");
      let persisted = make_meta "dashboard-purge-persisted" in
      create_owner_meta_exn config persisted;
      let persisted =
        match Keeper_meta_store.read_meta config persisted.name with
        | Ok (Some meta) -> meta
        | Ok None -> fail "persisted dashboard purge metadata disappeared"
        | Error detail -> fail detail
      in
      let target =
        match Dashboard_purge.resolve config persisted.name with
        | Ok (Some target) -> target
        | Ok None -> fail "persisted Keeper fell through to plain-agent purge"
        | Error error -> fail (Dashboard_purge.resolve_error_to_string error)
      in
      check string "resolved exact Keeper name" persisted.name target.keeper_name;
      (* A Keeper that can still execute a turn is refused here, not raced.
         The dashboard hides the control in the same states, but a caller
         reaching the endpoint directly bypassed that entirely — which is how a
         live campaign Keeper was purged mid-run on 2026-08-20. *)
      let executing_entry =
        R.register_offline ~base_path:config.base_path persisted.name persisted
      in
      (match
         R.put_entry
           ~base_path:config.base_path
           persisted.name
           { executing_entry with phase = Keeper_state_machine.Running }
       with
       | Error _ -> fail "could not stage an executing lane for purge admission"
       | Ok () ->
         (match Dashboard_purge.resolve config persisted.name with
          | Error (Dashboard_purge.Keeper_lane_executing { keeper_name; phase }) ->
            check string "refused the executing Keeper" persisted.name keeper_name;
            check
              string
              "reported the phase that refused it"
              "running"
              (String.lowercase_ascii phase)
          | Error other ->
            fail
              ("executing lane produced the wrong refusal: "
               ^ Dashboard_purge.resolve_error_to_string other)
          | Ok _ -> fail "an executing Keeper must not be admitted for purge"));
      (* The chat lane never changes phase: run_keeper_invocation_turn_admitted
         calls mark_turn_started, which writes current_turn_observation and
         leaves phase alone. A phase-only guard reads a Paused Keeper answering
         a chat message as purgeable, so the refusal has to see the live turn
         too. *)
      (match
         R.put_entry
           ~base_path:config.base_path
           persisted.name
           { executing_entry with phase = Keeper_state_machine.Paused }
       with
       | Error _ -> fail "could not stage a paused lane for the chat-lane check"
       | Ok () ->
         R.mark_turn_started
           ~base_path:config.base_path
           ~wake:Masc.Keeper_registry_types.Chat_request
           persisted.name;
         (match Dashboard_purge.resolve config persisted.name with
          | Error
              (Dashboard_purge.Keeper_lane_executing
                { keeper_name; live_turn_id = Some _; _ }) ->
            check string "refused the Keeper mid chat turn" persisted.name keeper_name
          | Error other ->
            fail
              ("a chat turn in flight produced the wrong refusal: "
               ^ Dashboard_purge.resolve_error_to_string other)
          | Ok _ ->
            fail "a Keeper running a chat turn must not be admitted for purge"));
      (* Drop the staged lane so the assertions below still describe a Keeper
         that only has persisted metadata. *)
      ignore (R.unregister_exact executing_entry);
      check bool
        "resolved exact metadata trace"
        true
        (Keeper_id.Trace_id.equal
           persisted.runtime.trace_id
           target.meta.runtime.trace_id);
      let backlog_version =
        match Workspace_backlog.read_backlog_r config with
        | Ok backlog -> backlog.version
        | Error detail -> fail detail
      in
      let existing_operation : Shutdown_types.t =
        { schema_version = Shutdown_types.schema_version
        ; revision = 0
        ; operation_id = Shutdown_types.Operation_id.generate ()
        ; keeper_name = persisted.name
        ; lane_ownership = Shutdown_types.Dormant_meta
        ; trace_id = persisted.runtime.trace_id
        ; actor = "supervisor"
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
      (match Shutdown_store.persist_new ~config existing_operation with
       | Ok () -> ()
       | Error error -> fail (Shutdown_store.error_to_string error));
      (match
         restore_owner_shutdown_exn
           ~base_path:config.base_path
           ~keeper_name:persisted.name
           ~operation_id:existing_operation.operation_id
       with
       | Masc.Keeper_owner.Shutdown_restored -> ()
       | Masc.Keeper_owner.Shutdown_already_restored
       | Masc.Keeper_owner.Shutdown_restore_conflict _ ->
         fail "existing cleanup fixture could not restore admission");
      (match Dashboard_purge.submit ~config ~actor:"operator" target with
       | Error (Shutdown_runtime.Existing_operation_intent_mismatch operation) ->
         check bool
           "mismatched operation identity is surfaced"
           true
           (Shutdown_types.Operation_id.equal
              existing_operation.operation_id
              operation.operation_id)
       | Error error -> fail (Shutdown_runtime.submit_error_to_string error)
       | Ok _ -> fail "dashboard purge reused an unrelated cleanup operation");
      let corrupt_name = "dashboard-purge-corrupt" in
      write_file
        (Keeper_types_profile.keeper_meta_path config corrupt_name)
        "{not-json";
      (match Dashboard_purge.resolve config corrupt_name with
       | Error (Dashboard_purge.Keeper_metadata_unreadable _) -> ()
       | Error error -> fail (Dashboard_purge.resolve_error_to_string error)
       | Ok _ -> fail "corrupt Keeper metadata fell through to agent purge");
      let configured_name = "dashboard-purge-configured" in
      let configured_path =
        Filename.concat
          (Config_dir_resolver.keepers_dir_for_base_path
             ~base_path:config.base_path)
          (configured_name ^ ".toml")
      in
      write_file configured_path "[keeper]\nautoboot = false\n";
      match Dashboard_purge.resolve config configured_name with
      | Error
          (Dashboard_purge.Keeper_metadata_required
            { configuration_path; _ }) ->
        check string
          "configuration-only Keeper path stays explicit"
          configured_path
          configuration_path
      | Error error -> fail (Dashboard_purge.resolve_error_to_string error)
      | Ok _ -> fail "configuration-only Keeper fell through to agent purge")
;;

let test_keeper_shutdown_prepare_joins_idle_lane () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  Eio.Switch.run @@ fun parent_sw ->
  let base_dir = temp_dir "shutdown-prepare-join" in
  Fun.protect
    ~finally:(fun () ->
      Memory_lane.For_testing.reset ();
      R.For_testing.clear ();
      cleanup_dir base_dir)
    (fun () ->
      let config = Masc.Workspace.default_config base_dir in
      let (_init_message : string) =
        Masc.Workspace.init config ~agent_name:(Some "operator")
      in
      Eio.Switch.run @@ fun sw ->
      install_owner_inventory_exn ~sw config;
      let name = "shutdown-idle-lane" in
      let meta = make_meta name in
      create_owner_meta_exn config meta;
      let entry = R.For_testing.register ~base_path:config.base_path name meta in
      Memory_lane.init ~sw:parent_sw;
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
      let librarian_started, resolve_librarian_started = Eio.Promise.create () in
      let librarian_release, resolve_librarian_release = Eio.Promise.create () in
      let librarian_cancelled = ref false in
      let librarian_completed = ref false in
      (match
         Memory_lane.submit
           ~base_path:config.base_path
           ~keeper_name:name
           (fun () ->
              Eio.Promise.resolve resolve_librarian_started ();
              try
                Eio.Promise.await librarian_release;
                librarian_completed := true
              with
              | Eio.Cancel.Cancelled _ as exn ->
                librarian_cancelled := true;
                raise exn)
       with
       | Memory_lane.Submitted -> ()
       | Memory_lane.Coalesced
       | Memory_lane.Ran_inline
       | Memory_lane.Dropped
       | Memory_lane.Rejected_draining ->
         fail "shutdown Librarian was not submitted");
      Eio.Promise.await librarian_started;
      let shutdown_done, resolve_shutdown_done = Eio.Promise.create () in
      Eio.Fiber.fork ~sw (fun () ->
        Eio.Promise.resolve
          resolve_shutdown_done
          (Shutdown_prepare_join.run
             ~config
             ~entry
             ~request:
               { actor = "operator"
               ; cleanup_intent = retain_operator_cleanup
               }));
      let rec await_durable_joining_lanes () =
        match Eio.Promise.peek shutdown_done with
        | Some (Ok _) -> fail "shutdown completed before Librarian release"
        | Some (Error error) -> fail (Shutdown_prepare_join.error_to_string error)
        | None ->
          (match
             owner_shutdown_operation_id_exn
               ~base_path:config.base_path
               ~keeper_name:name
           with
           | None ->
             Eio.Fiber.yield ();
             await_durable_joining_lanes ()
           | Some operation_id ->
             (match Shutdown_store.load ~config ~keeper_name:name operation_id with
              | Ok { phase = Shutdown_types.Joining_lanes; _ } -> operation_id
              | Ok { phase = Shutdown_types.Prepared; _ } ->
                Eio.Fiber.yield ();
                await_durable_joining_lanes ()
              | Ok operation ->
                fail
                  (Printf.sprintf
                     "Librarian wait entered unexpected durable revision=%d"
                     operation.revision)
              | Error (Shutdown_store.Not_found _) ->
                Eio.Fiber.yield ();
                await_durable_joining_lanes ()
              | Error error -> fail (Shutdown_store.error_to_string error)))
      in
      let _joining_operation_id = await_durable_joining_lanes () in
      check bool
        "shutdown remains pending while accepted Librarian work runs"
        true
        (Option.is_none (Eio.Promise.peek shutdown_done));
      Eio.Promise.resolve resolve_librarian_release ();
      let operation =
        match Eio.Promise.await shutdown_done with
        | Ok operation -> operation
        | Error error -> fail (Shutdown_prepare_join.error_to_string error)
      in
      (match operation.phase with
       | Shutdown_types.Joined_idle -> ()
       | Shutdown_types.Prepared
       | Shutdown_types.Joining_lanes
       | Shutdown_types.Finalizing_tasks _
       | Shutdown_types.Cleanup_ready _
       | Shutdown_types.Reconciliation_required _
       | Shutdown_types.Finalized _
       | Shutdown_types.Blocked _
       | Shutdown_types.Superseded _ -> fail "idle lane did not reach Joined_idle");
      check bool
        "shutdown operation records lane join evidence"
        true
        (Option.is_some operation.join_evidence);
      check bool
        "shutdown preserved the detached Librarian through completion"
        false
        !librarian_cancelled;
      check bool
        "shutdown drained the detached Librarian before returning"
        true
        !librarian_completed;
      check
        (option int)
        "shutdown joined the detached Librarian"
        (Some 0)
        (Memory_lane.For_testing.pending
           ~base_path:config.base_path
           ~keeper_name:name);
      (match
         owner_shutdown_operation_id_exn
           ~base_path:config.base_path
           ~keeper_name:name
       with
       | Some operation_id ->
         check bool
           "shutdown admission fence retains operation identity"
           true
           (Shutdown_types.Operation_id.equal operation.operation_id operation_id)
       | None ->
         fail "shutdown admission fence reopened before finalization"))

let test_keeper_shutdown_owner_failure_persists_blocked_join () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let base_dir = temp_dir "shutdown-owner-failure" in
  Fun.protect
    ~finally:(fun () ->
      R.For_testing.clear ();
      cleanup_dir base_dir)
    (fun () ->
      let config = Masc.Workspace.default_config base_dir in
      let (_init_message : string) =
        Masc.Workspace.init config ~agent_name:(Some "operator")
      in
      let name = "shutdown-owner-failure-lane" in
      let meta = make_meta name in
      (match Keeper_meta_store.replace_snapshot config meta with
       | Ok () -> ()
       | Error detail -> fail detail);
      let prepared = ref None in
      let exception Close_owner_before_join in
      (try
         Eio.Switch.run @@ fun owner_sw ->
         install_owner_inventory_exn ~sw:owner_sw config;
         let entry = R.For_testing.register ~base_path:config.base_path name meta in
         let operation =
           match
             Shutdown_prepare_join.prepare
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
         prepared := Some (entry, operation);
         Eio.Switch.fail owner_sw Close_owner_before_join
       with
       | Close_owner_before_join -> ());
      let entry, operation =
        match !prepared with
        | Some prepared -> prepared
        | None -> fail "shutdown owner failure fixture was not prepared"
      in
      let blocked =
        match Shutdown_prepare_join.join_prepared ~config ~entry ~operation with
        | Error (Shutdown_prepare_join.Join_failed blocked) -> blocked
        | Error error -> fail (Shutdown_prepare_join.error_to_string error)
        | Ok _ -> fail "closed owner was reported as a successful lane join"
      in
      (match blocked.phase with
       | Shutdown_types.Blocked { stage = Shutdown_types.Lane_join; detail } ->
         check bool "owner failure records a non-empty join detail" true
           (String.length detail > 0)
       | _ -> fail "owner failure did not become durable Blocked/Lane_join");
      let loaded =
        match
          Shutdown_store.load
            ~config
            ~keeper_name:name
            operation.operation_id
        with
        | Ok loaded -> loaded
        | Error error -> fail (Shutdown_store.error_to_string error)
      in
      match loaded.phase with
      | Shutdown_types.Blocked { stage = Shutdown_types.Lane_join; _ } -> ()
      | _ -> fail "reloaded owner failure remained stranded in Joining_lanes")

let test_keeper_shutdown_blocks_join_replay_after_record_failure () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  Eio.Switch.run @@ fun sw ->
  let base_dir = temp_dir "shutdown-join-record-retry" in
  Fun.protect
    ~finally:(fun () ->
      Memory_lane.For_testing.reset ();
      R.For_testing.clear ();
      cleanup_dir base_dir)
    (fun () ->
      let config = Masc.Workspace.default_config base_dir in
      let (_init_message : string) =
        Masc.Workspace.init config ~agent_name:(Some "operator")
      in
      let name = "shutdown-join-record-retry-lane" in
      let meta = make_meta name in
      (match Keeper_meta_store.replace_snapshot config meta with
       | Ok () -> ()
       | Error detail -> fail detail);
      install_owner_inventory_exn ~sw config;
      let entry = R.For_testing.register ~base_path:config.base_path name meta in
      Memory_lane.init ~sw;
      let librarian_started, resolve_librarian_started = Eio.Promise.create () in
      let librarian_release, resolve_librarian_release = Eio.Promise.create () in
      (match
         Memory_lane.submit
           ~base_path:config.base_path
           ~keeper_name:name
           (fun () ->
              Eio.Promise.resolve resolve_librarian_started ();
              Eio.Promise.await librarian_release)
       with
       | Memory_lane.Submitted -> ()
       | Memory_lane.Coalesced
       | Memory_lane.Ran_inline
       | Memory_lane.Dropped
       | Memory_lane.Rejected_draining ->
         fail "record retry Librarian fixture was not submitted");
      Eio.Promise.await librarian_started;
      let operation =
        match
          Shutdown_prepare_join.prepare
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
      let first_join, resolve_first_join = Eio.Promise.create () in
      Eio.Fiber.fork ~sw (fun () ->
        Eio.Promise.resolve
          resolve_first_join
          (Shutdown_prepare_join.join_prepared ~config ~entry ~operation));
      let rec await_joining () =
        match Shutdown_store.load ~config ~keeper_name:name operation.operation_id with
        | Ok ({ phase = Shutdown_types.Joining_lanes; _ } as joining) -> joining
        | Ok _ | Error (Shutdown_store.Not_found _) ->
          Eio.Fiber.yield ();
          await_joining ()
        | Error error -> fail (Shutdown_store.error_to_string error)
      in
      let joining = await_joining () in
      let operation_path =
        match Shutdown_store.path ~config ~keeper_name:name operation.operation_id with
        | Ok path -> path
        | Error error -> fail (Shutdown_store.error_to_string error)
      in
      let held_path = operation_path ^ ".held" in
      Unix.rename operation_path held_path;
      Eio.Promise.resolve resolve_librarian_release ();
      (match Eio.Promise.await first_join with
       | Error (Shutdown_prepare_join.Join_record_update_failed _) -> ()
       | Error error -> fail (Shutdown_prepare_join.error_to_string error)
       | Ok _ -> fail "missing shutdown record did not fail final join persistence");
      Unix.rename held_path operation_path;
      R.For_testing.unregister ~base_path:config.base_path name;
      let blocked =
        match Shutdown_prepare_join.join_prepared ~config ~entry ~operation:joining with
        | Error (Shutdown_prepare_join.Join_failed blocked) -> blocked
        | Error error -> fail (Shutdown_prepare_join.error_to_string error)
        | Ok _ -> fail "Joining_lanes replay guessed a successful prior join"
      in
      (match blocked.phase with
       | Shutdown_types.Blocked { stage = Shutdown_types.Lane_join; _ } -> ()
       | _ -> fail "join replay did not fail closed as Blocked/Lane_join");
      match
        Shutdown_store.load ~config ~keeper_name:name operation.operation_id
      with
      | Ok { phase = Shutdown_types.Blocked { stage = Shutdown_types.Lane_join; _ }; _ } ->
        ()
      | Ok _ -> fail "reloaded join replay remained stranded in Joining_lanes"
      | Error error -> fail (Shutdown_store.error_to_string error))

let test_keeper_shutdown_prepare_joins_not_started_lane () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  Eio.Switch.run @@ fun sw ->
  let base_dir = temp_dir "shutdown-prepare-not-started" in
  Fun.protect
    ~finally:(fun () ->
      R.For_testing.clear ();
      cleanup_dir base_dir)
    (fun () ->
      let config = Masc.Workspace.default_config base_dir in
      let (_init_message : string) =
        Masc.Workspace.init config ~agent_name:(Some "operator")
      in
      install_owner_inventory_exn ~sw config;
      let name = "shutdown-not-started-lane" in
      let meta = make_meta name in
      create_owner_meta_exn config meta;
      let entry = R.For_testing.register ~base_path:config.base_path name meta in
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
       | Shutdown_types.Joining_lanes
       | Shutdown_types.Finalizing_tasks _
       | Shutdown_types.Cleanup_ready _
       | Shutdown_types.Reconciliation_required _
       | Shutdown_types.Finalized _
       | Shutdown_types.Blocked _
       | Shutdown_types.Superseded _ -> fail "not-started lane did not reach Joined_idle");
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
  Eio.Switch.run @@ fun sw ->
  let base_dir = temp_dir "shutdown-prepare-rollback" in
  Fun.protect
    ~finally:(fun () ->
      R.For_testing.clear ();
      cleanup_dir base_dir)
    (fun () ->
      let config = Masc.Workspace.default_config base_dir in
      let (_init_message : string) =
        Masc.Workspace.init config ~agent_name:(Some "operator")
      in
      install_owner_inventory_exn ~sw config;
      let name = "shutdown-prepare-rollback-lane" in
      let meta = make_meta name in
      create_owner_meta_exn config meta;
      let entry = R.For_testing.register ~base_path:config.base_path name meta in
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
      match
        owner_shutdown_operation_id_exn
          ~base_path:config.base_path
          ~keeper_name:name
      with
      | None -> ()
      | Some id ->
        fail
          (Printf.sprintf
             "failed shutdown prepare left the keeper admission fence closed: \
              shutdown operation %s still owns the Owner"
             (Shutdown_types.Operation_id.to_string id))
      )

let test_keeper_dormant_shutdown_join_cancel_rolls_back_fence () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let base_dir = temp_dir "shutdown-dormant-cancel-rollback" in
  Fun.protect
    ~finally:(fun () ->
      R.For_testing.clear ();
      cleanup_dir base_dir)
    (fun () ->
      let config = Masc.Workspace.default_config base_dir in
      let (_init_message : string) =
        Masc.Workspace.init config ~agent_name:(Some "operator")
      in
      Eio.Switch.run @@ fun sw ->
      install_owner_inventory_exn ~sw config;
      let name = "shutdown-dormant-cancel-rollback" in
      let meta = make_meta name in
      create_owner_meta_exn config meta;
      let intake_started, intake_started_u = Eio.Promise.create () in
      let release_intake, release_intake_u = Eio.Promise.create () in
      let intake_finished, intake_finished_u = Eio.Promise.create () in
      Eio.Switch.run @@ fun outer_sw ->
      Eio.Fiber.fork ~sw:outer_sw (fun () ->
        (match
           Masc.Keeper_shutdown_intake_fence.run_durable_intake_if_open
             ~base_path:config.base_path
             ~keeper_name:name
             (fun _intake_token ->
                Eio.Promise.resolve intake_started_u ();
                Eio.Promise.await release_intake)
         with
         | Masc.Keeper_shutdown_intake_fence.Intake_committed () -> ()
         | Masc.Keeper_shutdown_intake_fence.Intake_shutdown_reserved operation_id ->
           fail
             ("test intake unexpectedly saw shutdown reservation "
              ^ Shutdown_types.Operation_id.to_string operation_id));
        Eio.Promise.resolve intake_finished_u ());
      Eio.Promise.await intake_started;
      let exception Cancel_dormant_prepare in
      (try
         Eio.Switch.run @@ fun prepare_sw ->
         Eio.Fiber.fork ~sw:prepare_sw (fun () ->
           ignore
             (Shutdown_prepare_join.prepare_dormant
                ~config
                ~meta
                ~request:
                  { actor = "operator"
                  ; cleanup_intent = retain_operator_cleanup
                  }
              : (Shutdown_types.t, Shutdown_prepare_join.error) result));
         Eio.Fiber.yield ();
         check bool "dormant prepare reserved shutdown before joining intake" true
           (Option.is_some
              (owner_shutdown_operation_id_exn
                 ~base_path:config.base_path
                 ~keeper_name:name));
         Eio.Switch.fail prepare_sw Cancel_dormant_prepare
       with
       | Cancel_dormant_prepare -> ());
      Eio.Promise.resolve release_intake_u ();
      Eio.Promise.await intake_finished;
      match
        owner_shutdown_operation_id_exn
          ~base_path:config.base_path
          ~keeper_name:name
      with
      | None -> ()
      | Some operation_id ->
        fail
          ("cancelled dormant prepare left shutdown reservation "
           ^ Shutdown_types.Operation_id.to_string operation_id)
      )

let install_pending_summary ~base_path ~keeper_name ~bind_exact =
  Approval_queue.For_testing.reset_runtime_state ();
  (match Approval_queue.install_persistence ~base_path with
   | Ok _ -> ()
   | Error error -> fail (Approval_queue.install_error_to_string error));
  let id =
    match
      Approval_queue.submit_pending
        ~keeper_name
        ~tool_name:"shutdown-fixture"
        ~input:(`String "effect")
        ~base_path
        ()
    with
    | Ok submission -> submission.approval_id
    | Error error -> fail (Approval_queue.storage_error_to_string error)
  in
  (match Approval_queue.mark_summary_pending ~id with
   | Ok true -> ()
   | Ok false -> fail "summary did not become pending"
   | Error error ->
     fail (Approval_queue.summary_transition_error_to_string error));
  if bind_exact
  then (
    let entry =
      match Approval_queue.For_testing.get_pending_entry_unchecked ~id with
      | Some entry -> entry
      | None -> fail "pending summary disappeared before exact bind"
    in
    match
      Approval_queue.bind_summary_exact_attempt
        ~id
        ~input_hash:entry.input_hash
        ~sequence:entry.sequence
        ~slot_id:"shutdown-slot"
        ~call_id:"shutdown-call"
        ~plan_fingerprint:(String.make 64 'p')
        ~request_body_sha256:(String.make 64 'a')
    with
    | Ok _ -> ()
    | Error error -> fail (Approval_queue.exact_attempt_error_to_string error));
  id
;;

let test_keeper_shutdown_finalizes_idle_operation () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  Eio.Switch.run @@ fun owner_sw ->
  let base_dir = temp_dir "shutdown-finalize" in
  Fun.protect
    ~finally:(fun () ->
      Shutdown_finalize.For_testing.reset_remove_pending_confirms_by_target ();
      Approval_queue.For_testing.reset_runtime_state ();
      R.For_testing.clear ();
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
      let approval_id =
        install_pending_summary
          ~base_path:config.base_path
          ~keeper_name:meta.name
          ~bind_exact:false
      in
      (match Keeper_meta_store.replace_snapshot config meta with
       | Ok () -> ()
       | Error detail -> fail detail);
      install_owner_inventory_exn ~sw:owner_sw config;
      Shutdown_finalize.register_remove_pending_confirms_by_target
        (fun _config ~target_type:_ ~target_id:_ -> Ok 0);
      let operation_id = Shutdown_types.Operation_id.generate () in
      let operation : Shutdown_types.t =
        { schema_version = Shutdown_types.schema_version
        ; revision = 0
        ; operation_id
        ; keeper_name = meta.name
        ; lane_ownership =
            Shutdown_types.Registered_lane (Lane.id (Lane.create ()))
        ; trace_id = meta.runtime.trace_id
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
         begin_owner_shutdown_exn
           ~base_path:config.base_path
           ~keeper_name:meta.name
           ~operation_id
       with
       | Masc.Keeper_owner.Shutdown_reserved _ -> ()
       | Masc.Keeper_owner.Shutdown_already_reserved _ ->
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
       | Shutdown_types.Joining_lanes
       | Shutdown_types.Joined_idle
       | Shutdown_types.Finalizing_tasks _
       | Shutdown_types.Cleanup_ready _
       | Shutdown_types.Reconciliation_required _
       | Shutdown_types.Blocked _
       | Shutdown_types.Superseded _ -> fail "shutdown did not reach Finalized");
      (match
         begin_owner_shutdown_exn
           ~base_path:config.base_path
           ~keeper_name:meta.name
           ~operation_id
       with
       | Masc.Keeper_owner.Shutdown_reserved _ -> ()
       | Masc.Keeper_owner.Shutdown_already_reserved _ ->
         fail "finalized shutdown did not release its admission fence");
      (match Shutdown_finalize.run ~config ~entry:None finalized with
       | Ok _ -> ()
       | Error error -> fail (Shutdown_finalize.error_to_string error));
      check
        bool
        "finalized shutdown replay releases admission fence"
        true
        (Option.is_none
           (owner_shutdown_operation_id_exn
             ~base_path:config.base_path
              ~keeper_name:meta.name));
      (match Approval_queue.For_testing.get_pending_entry_unchecked ~id:approval_id with
       | Some { summary_status = Approval_types.Summary_pending; _ } -> ()
       | Some _ | None -> fail "retain-meta shutdown changed pending summary");
      match Keeper_meta_store.read_meta config meta.name with
      | Ok (Some retained) ->
        check bool "retained Keeper is paused" true retained.paused;
        check bool "retained Keeper task binding is cleared" true
          (Option.is_none retained.current_task_id)
      | Ok None -> fail "retained Keeper metadata disappeared"
      | Error detail -> fail detail)

let test_destructive_shutdown_drains_bound_summary_then_completes () =
  List.iter
    (fun mode ->
       Eio_main.run @@ fun env ->
       Fs_compat.set_fs (Eio.Stdenv.fs env);
       Eio.Switch.run @@ fun owner_sw ->
       let label =
         match mode with
         | `Remove -> "remove"
         | `Supervisor_cleanup -> "supervisor-cleanup"
         | `Purge -> "purge"
       in
       let base_dir = temp_dir ("shutdown-summary-retirement-" ^ label) in
       Fun.protect
         ~finally:(fun () ->
           Approval_queue.For_testing.reset_runtime_state ();
           Shutdown_finalize.For_testing.reset_completion_handler ();
           R.For_testing.clear ();
           cleanup_dir base_dir)
         (fun () ->
            let config = Masc.Workspace.default_config base_dir in
            ignore (Masc.Workspace.init config ~agent_name:(Some "operator"));
            let backlog_version =
              match Workspace_backlog.read_backlog_r config with
              | Ok backlog -> backlog.version
              | Error detail -> fail detail
            in
            let meta = make_meta ("shutdown-summary-" ^ label) in
            (match Keeper_meta_store.replace_snapshot config meta with
             | Ok () -> ()
             | Error detail -> fail detail);
            let meta =
              match Keeper_meta_store.read_meta config meta.name with
              | Ok (Some persisted) -> persisted
              | Ok None -> fail "retirement fixture metadata disappeared"
              | Error detail -> fail detail
            in
            install_owner_inventory_exn ~sw:owner_sw config;
            let entry =
              R.For_testing.register
                ~base_path:config.base_path
                meta.name
                meta
            in
            let approval_id =
              install_pending_summary
                ~base_path:config.base_path
                ~keeper_name:meta.name
                ~bind_exact:true
            in
            Shutdown_finalize.register_completion_handler
              (fun _config _operation _action -> Ok ());
            let session_dir =
              Filename.concat
                (Keeper_types_profile.session_base_dir config)
                (Keeper_id.Trace_id.to_string meta.runtime.trace_id)
            in
            Fs_compat.mkdir_p session_dir;
            let cleanup_intent =
              match mode with
              | `Remove -> { remove_meta_cleanup with remove_session = true }
              | `Supervisor_cleanup ->
                { Shutdown_types.reason =
                    Shutdown_types.Supervisor_cleanup
                ; remove_session = true
                }
              | `Purge -> dashboard_purge_cleanup meta.name meta
            in
            let operation_id = Shutdown_types.Operation_id.generate () in
            let operation : Shutdown_types.t =
              { schema_version = Shutdown_types.schema_version
              ; revision = 0
              ; operation_id
              ; keeper_name = meta.name
              ; lane_ownership =
                  Shutdown_types.Registered_lane (Lane.id entry.lane)
              ; trace_id = meta.runtime.trace_id
              ; actor = "operator"
              ; cleanup_intent
              ; turn_disposition = Shutdown_types.No_inflight_turn
              ; expected_backlog_version = backlog_version
              ; owned_task_ids = []
              ; join_evidence = None
              ; phase =
                  Shutdown_types.Cleanup_ready
                    { settled_task_ids = []
                    ; pending_confirms_removed = 0
                    ; meta_snapshot_digest =
                        Keeper_meta_json.Snapshot_digest.of_meta meta
                    }
              ; created_at = Masc_domain.now_iso ()
              ; updated_at = Masc_domain.now_iso ()
              }
            in
            (match Shutdown_store.persist_new ~config operation with
             | Ok () -> ()
             | Error error -> fail (Shutdown_store.error_to_string error));
            let draining =
              match
                Shutdown_finalize.run
                  ~config
                  ~entry:(Some entry)
                  operation
              with
              | Error (Shutdown_finalize.Finalization_draining (draining, _)) ->
                draining
              | Error error -> fail (Shutdown_finalize.error_to_string error)
              | Ok _ -> fail "bound shutdown skipped the draining boundary"
            in
            (match draining.phase with
             | Shutdown_types.Cleanup_ready _ -> ()
             | _ -> fail "draining shutdown did not remain retryable");
            (match Keeper_meta_store.read_meta config meta.name with
             | Ok (Some _) -> ()
             | Ok None -> fail "retirement failure removed metadata"
             | Error detail -> fail detail);
            check bool "registry identity retained while draining" true
              (Option.is_some
                 (R.get ~base_path:config.base_path meta.name));
            let pending =
              match Approval_queue.For_testing.get_pending_entry_unchecked ~id:approval_id with
              | Some pending -> pending
              | None -> fail "bound summary disappeared while draining"
            in
            (match
               Approval_queue.quarantine_summary_exact_attempt
                 ~id:approval_id
                 ~input_hash:pending.input_hash
                 ~sequence:pending.sequence
                 ~slot_id:"shutdown-slot"
                 ~call_id:"shutdown-call"
                 ~plan_fingerprint:(String.make 64 'p')
                 ~request_body_sha256:(String.make 64 'a')
                 ~cause:Approval_types.Exact_flow_execution_failed
             with
             | Ok _ -> ()
             | Error error ->
               fail (Approval_queue.exact_attempt_error_to_string error));
            let finalized =
              match
                Shutdown_finalize.run
                  ~config
                  ~entry:(Some entry)
                  draining
              with
              | Ok finalized -> finalized
              | Error error -> fail (Shutdown_finalize.error_to_string error)
            in
            (match finalized.phase with
             | Shutdown_types.Finalized _ -> ()
             | _ -> fail "settled draining shutdown did not finalize");
            check bool "registry retired after settlement" true
              (Option.is_none
                 (R.get ~base_path:config.base_path meta.name));
            check bool "session removed after settlement" false
              (Sys.file_exists session_dir)))
    [ `Remove; `Supervisor_cleanup; `Purge ]
;;

let test_dashboard_keeper_purge_finalizes_artifacts_and_receipt () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  Eio.Switch.run @@ fun owner_sw ->
  let base_dir = temp_dir "dashboard-purge-finalization" in
  let completion_bus = Agent_core.Event_bus.create () in
  let completion_subscription =
    Masc.Runtime_event_bus.subscribe
      ~capacity:256
      ~overflow:Agent_core.Event_bus.Drop_oldest
      ~purpose:"dashboard-purge-completion-test"
      completion_bus
  in
  Event_bus_slots.set_masc completion_bus;
  Fun.protect
    ~finally:(fun () ->
      Masc.Runtime_event_bus.unsubscribe completion_bus completion_subscription;
      Shutdown_finalize.For_testing.reset_remove_pending_confirms_by_target ();
      Shutdown_finalize.For_testing.reset_completion_handler ();
      R.For_testing.clear ();
      cleanup_dir base_dir)
    (fun () ->
      let config = Masc.Workspace.default_config base_dir in
      let (_init_message : string) =
        Masc.Workspace.init config ~agent_name:(Some "operator")
      in
      let initial =
        { (make_meta "dashboard-purge-finalize") with name = String.make 75 'p' }
      in
      (match Keeper_meta_store.replace_snapshot config initial with
       | Ok () -> ()
       | Error detail -> fail detail);
      let meta =
        match Keeper_meta_store.read_meta config initial.name with
        | Ok (Some meta) -> meta
        | Ok None -> fail "dashboard purge metadata disappeared"
        | Error detail -> fail detail
      in
      install_owner_inventory_exn ~sw:owner_sw config;
      let backlog_version =
        match Workspace_backlog.read_backlog_r config with
        | Ok backlog -> backlog.version
        | Error detail -> fail detail
      in
      let metrics_dir = Keeper_types_support.keeper_metrics_dir config meta.name in
      write_file (Filename.concat metrics_dir "2026-07/15.jsonl") "{}\n";
      let sidecar_paths =
        [ Keeper_types_support.keeper_decision_log_path config meta.name
        ; Keeper_types_support.keeper_feedback_log_path config meta.name
        ]
      in
      List.iter (fun path -> write_file path "fixture") sidecar_paths;
      let runtime_dir = Filename.concat (Keeper_fs.keeper_dir config) meta.name in
      write_file (Filename.concat runtime_dir "runtime.json") "{}";
      let session_dir =
        Keeper_types_support.keeper_session_dir
          config
          (Keeper_id.Trace_id.to_string meta.runtime.trace_id)
      in
      write_file (Filename.concat session_dir "history.jsonl") "{}\n";
      let configuration_path =
        Filename.concat
          (Config_dir_resolver.keepers_dir_for_base_path
             ~base_path:config.base_path)
          (meta.name ^ ".toml")
      in
      write_file configuration_path "[keeper]\nautoboot = false\n";
      let playground_paths =
        Keeper_types_profile.all_sandbox_profiles
        |> List.map (fun profile ->
             Filename.concat
               config.base_path
               (Masc.Keeper_sandbox.host_root_rel_of_profile profile meta.name))
        |> List.sort_uniq String.compare
      in
      List.iter
        (fun path -> write_file (Filename.concat path "workspace/stale.txt") "stale")
        playground_paths;
      let unrelated_playground_path =
        Filename.concat
          config.base_path
          ".masc/playground/unrelated/workspace/keep.txt"
      in
      write_file unrelated_playground_path "keep";
      let agent_path =
        Filename.concat
          (Workspace.agents_dir config)
          (Workspace.safe_filename meta.name ^ ".json")
      in
      write_file agent_path "{}";
      let agent_metrics_dir =
        Masc.Metrics_store_eio.agent_metrics_dir config meta.name
      in
      write_file (Filename.concat agent_metrics_dir "fixture.jsonl") "{}\n";
      let unrelated_path =
        Filename.concat (Workspace.agents_dir config) "unrelated.json"
      in
      write_file unrelated_path "{}";
      Auth.save_credential
        config.base_path
        { id = None
        ; agent_id = None
        ; agent_name = meta.name
        ; token = Auth.sha256_hash "dashboard-purge-token"
        ; role = Masc_domain.Worker
        ; created_at = Masc_domain.now_iso ()
        ; expires_at = None
        };
      ignore
        (Workspace.update_state config (fun state ->
           { state with
             active_agents = meta.name :: state.active_agents
           }));
      ignore
        (Heartbeat.start
           ~agent_name:meta.name
           ~interval:30
           ~message:"dashboard purge fixture");
      let operation_id = Shutdown_types.Operation_id.generate () in
      let operation : Shutdown_types.t =
        { schema_version = Shutdown_types.schema_version
        ; revision = 0
        ; operation_id
        ; keeper_name = meta.name
        ; lane_ownership = Shutdown_types.Dormant_meta
        ; trace_id = meta.runtime.trace_id
        ; actor = "operator"
        ; cleanup_intent = dashboard_purge_cleanup meta.name meta
        ; turn_disposition = Shutdown_types.No_inflight_turn
        ; expected_backlog_version = backlog_version
        ; owned_task_ids = []
        ; join_evidence = None
        ; phase =
            Shutdown_types.Cleanup_ready
              { settled_task_ids = []
              ; pending_confirms_removed = 0
              ; meta_snapshot_digest =
                  Keeper_meta_json.Snapshot_digest.of_meta meta
              }
        ; created_at = Masc_domain.now_iso ()
        ; updated_at = Masc_domain.now_iso ()
        }
      in
      (match Shutdown_store.persist_new ~config operation with
       | Ok () -> ()
       | Error error -> fail (Shutdown_store.error_to_string error));
      (match
         restore_owner_shutdown_exn
           ~base_path:config.base_path
           ~keeper_name:meta.name
           ~operation_id
       with
       | Masc.Keeper_owner.Shutdown_restored -> ()
       | Masc.Keeper_owner.Shutdown_already_restored
       | Masc.Keeper_owner.Shutdown_restore_conflict _ ->
         fail "dashboard purge fixture could not restore admission");
      Shutdown_finalize.register_remove_pending_confirms_by_target
        (fun _config ~target_type:_ ~target_id:_ -> Ok 0);
      Shutdown_finalize.register_completion_handler
        (fun _config _operation _action -> Error "synthetic dashboard completion outage");
      (match Shutdown_finalize.run ~config ~entry:None operation with
       | Error (Shutdown_finalize.Completion_failed (_, detail)) ->
         check string
           "dashboard completion outage remains explicit"
           "synthetic dashboard completion outage"
           detail
       | Error error -> fail (Shutdown_finalize.error_to_string error)
       | Ok _ -> fail "dashboard completion outage was reported as delivered");
      let pending =
        match Shutdown_store.load ~config ~keeper_name:meta.name operation_id with
        | Ok pending -> pending
        | Error error -> fail (Shutdown_store.error_to_string error)
      in
      check bool
        "pending dashboard completion already removed exact metadata"
        false
        (Sys.file_exists (Keeper_types_profile.keeper_meta_path config meta.name));
      check bool
        "pending dashboard completion already removed exact session"
        false
        (Sys.file_exists session_dir);
      check bool
        "pending dashboard completion retains server artifacts for retry"
        true
        (Sys.file_exists configuration_path);
      (match Dashboard_purge.existing_operation config meta.name with
       | Ok (Some existing) ->
         check bool
           "HTTP retry recovers the exact pending dashboard operation"
           true
           (Shutdown_types.Operation_id.equal
              operation_id
              existing.operation_id)
       | Ok None -> fail "pending dashboard operation was not discoverable"
       | Error error -> fail (Dashboard_purge.resolve_error_to_string error));
      Shutdown_finalize.register_completion_handler
        Dashboard_delete.handle_keeper_lifecycle_completion;
      let finalized =
        match Shutdown_finalize.run ~config ~entry:None pending with
        | Ok finalized -> finalized
        | Error error -> fail (Shutdown_finalize.error_to_string error)
      in
      (match finalized.phase with
       | Shutdown_types.Finalized
           { meta_removed = true
           ; session_removed = true
           ; completion =
               Shutdown_types.Completion_delivered
                 Shutdown_types.Dashboard_keeper_purged
           ; _
           } -> ()
       | _ -> fail "dashboard purge did not persist its delivered receipt");
      let removed_paths =
        [ Keeper_types_profile.keeper_meta_path config meta.name
        ; metrics_dir
        ; runtime_dir
        ; session_dir
        ; configuration_path
        ; agent_path
        ; agent_metrics_dir
        ; Auth.credential_file config.base_path meta.name
        ]
        @ sidecar_paths
        @ playground_paths
      in
      List.iter
        (fun path ->
           check bool ("artifact removed: " ^ path) false (Sys.file_exists path))
        removed_paths;
      check bool "unrelated agent artifact preserved" true
        (Sys.file_exists unrelated_path);
      check bool "unrelated playground preserved" true
        (Sys.file_exists unrelated_playground_path);
      check bool
        "exact workspace owner unbound"
        false
        (List.exists
           (String.equal meta.name)
           (Workspace.read_state config).active_agents);
      check int
        "exact agent heartbeats stopped"
        0
        (List.length
           (List.filter
              (fun (heartbeat : Heartbeat.t) ->
                 String.equal heartbeat.agent_name meta.name)
              (Heartbeat.list ())));
      (match Masc.Runtime_event_bus.drain completion_subscription with
       | [ event ] ->
         (match event.Agent_core.Event_bus.payload with
          | Agent_core.Event_bus.Custom
              ("masc.keeper.lifecycle", `Assoc fields) ->
            check string
              "dashboard purge lifecycle event"
              "purged"
              (match List.assoc_opt "event" fields with
               | Some (`String event_name) -> event_name
               | _ -> fail "dashboard purge event omitted event name")
          | _ -> fail "dashboard purge did not publish a lifecycle event")
       | events ->
         fail
           (Printf.sprintf
              "expected one dashboard purge lifecycle event, got %d"
              (List.length events)));
      (match Shutdown_finalize.run ~config ~entry:None finalized with
       | Ok replayed -> check bool "finalized replay is stable" true
                          (replayed.phase = finalized.phase)
       | Error error -> fail (Shutdown_finalize.error_to_string error));
      check int
        "delivered dashboard purge receipt prevents duplicate event"
        0
        (List.length (Masc.Runtime_event_bus.drain completion_subscription));
      let admission =
        owner_shutdown_operation_id_exn
          ~base_path:config.base_path
          ~keeper_name:meta.name
      in
      check bool
        "delivered dashboard purge released admission fence"
        true
        (Option.is_none admission))
;;

let test_keeper_shutdown_cleanup_replays_after_meta_removal () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  Eio.Switch.run @@ fun owner_sw ->
  let base_dir = temp_dir "shutdown-meta-replay" in
  Fun.protect
    ~finally:(fun () ->
      R.For_testing.clear ();
      cleanup_dir base_dir)
    (fun () ->
      let config = Masc.Workspace.default_config base_dir in
      let (_init_message : string) =
        Masc.Workspace.init config ~agent_name:(Some "operator")
      in
      let meta = make_meta "shutdown-meta-replay-keeper" in
      (match Keeper_meta_store.replace_snapshot config meta with
       | Ok () -> ()
       | Error detail -> fail detail);
      install_owner_inventory_exn ~sw:owner_sw config;
      let backlog_version =
        match Workspace_backlog.read_backlog_r config with
        | Ok backlog -> backlog.version
        | Error detail -> fail detail
      in
      let operation_id = Shutdown_types.Operation_id.generate () in
      let cleanup : Shutdown_types.cleanup_evidence =
        { settled_task_ids = []
        ; pending_confirms_removed = 0
        ; meta_snapshot_digest = Keeper_meta_json.Snapshot_digest.of_meta meta
        }
      in
      let operation : Shutdown_types.t =
        { schema_version = Shutdown_types.schema_version
        ; revision = 0
        ; operation_id
        ; keeper_name = meta.name
        ; lane_ownership =
            Shutdown_types.Registered_lane (Lane.id (Lane.create ()))
        ; trace_id = meta.runtime.trace_id
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
         Keeper_meta_store.remove_snapshot config ~name:meta.name
       with
       | Ok () -> ()
       | Error error -> fail error);
      match Shutdown_finalize.run ~config ~entry:None operation with
      | Ok { phase = Shutdown_types.Finalized evidence; _ } ->
        check bool "meta cleanup remains complete on replay" true evidence.meta_removed
      | Ok _ -> fail "meta cleanup replay did not reach Finalized"
      | Error error -> fail (Shutdown_finalize.error_to_string error))

let test_keeper_shutdown_rejects_stale_snapshot_delete () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  Eio.Switch.run @@ fun owner_sw ->
  let base_dir = temp_dir "shutdown-stale-meta-delete" in
  Fun.protect
    ~finally:(fun () ->
      R.For_testing.clear ();
      cleanup_dir base_dir)
    (fun () ->
       let config = Masc.Workspace.default_config base_dir in
       ignore (Masc.Workspace.init config ~agent_name:(Some "operator"));
       let meta = make_meta "shutdown-stale-meta-delete-keeper" in
       Keeper_meta_store.replace_snapshot config meta |> Result.get_ok;
       install_owner_inventory_exn ~sw:owner_sw config;
       let backlog_version =
         Workspace_backlog.read_backlog_r config |> Result.get_ok |> fun backlog ->
         backlog.version
       in
       let cleanup : Shutdown_types.cleanup_evidence =
         { settled_task_ids = []
         ; pending_confirms_removed = 0
         ; meta_snapshot_digest = Keeper_meta_json.Snapshot_digest.of_meta meta
         }
       in
       let operation : Shutdown_types.t =
         { schema_version = Shutdown_types.schema_version
         ; revision = 0
         ; operation_id = Shutdown_types.Operation_id.generate ()
         ; keeper_name = meta.name
         ; lane_ownership = Shutdown_types.Dormant_meta
         ; trace_id = meta.runtime.trace_id
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
       Shutdown_store.persist_new ~config operation |> Result.get_ok;
       (match
          Keeper_owner_registry.apply_meta
            ~base_path:config.base_path
            ~keeper_name:meta.name
            (Masc.Keeper_owner_reducer.Set_autoboot
               { enabled = true; updated_at = "newer-snapshot" })
        with
        | Ok (Some _) -> ()
        | Ok None -> fail "concurrent metadata update removed its snapshot"
        | Error error -> fail (Keeper_owner_registry.command_error_to_string error));
       (match Shutdown_finalize.run ~config ~entry:None operation with
        | Error
            (Shutdown_finalize.Finalization_blocked
              { phase = Shutdown_types.Blocked { stage = Shutdown_types.Meta_remove; _ }
              ; _
              }) -> ()
        | Error error -> fail (Shutdown_finalize.error_to_string error)
        | Ok _ -> fail "stale cleanup authority deleted a newer metadata snapshot");
       match Keeper_meta_store.read_meta config meta.name with
       | Ok (Some current) ->
         check bool "newer metadata survives stale cleanup" true current.autoboot_enabled
       | Ok None -> fail "stale cleanup removed newer metadata"
       | Error detail -> fail detail)

let test_keeper_shutdown_recovers_committed_task_receipt () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  Eio.Switch.run @@ fun owner_sw ->
  let base_dir = temp_dir "shutdown-task-receipt" in
  Fun.protect
    ~finally:(fun () ->
      Shutdown_finalize.For_testing.reset_remove_pending_confirms_by_target ();
      R.For_testing.clear ();
      cleanup_dir base_dir)
    (fun () ->
      let config = Masc.Workspace.default_config base_dir in
      let (_init_message : string) =
        Masc.Workspace.init config ~agent_name:(Some "operator")
      in
      let meta = make_meta "shutdown-task-receipt-keeper" in
      (match Keeper_meta_store.replace_snapshot config meta with
       | Ok () -> ()
       | Error detail -> fail detail);
      install_owner_inventory_exn ~sw:owner_sw config;
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
           ~agent_name:meta.name
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
        ; lane_ownership =
            Shutdown_types.Registered_lane (Lane.id (Lane.create ()))
        ; trace_id = meta.runtime.trace_id
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
           ~agent_name:meta.name
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

let test_librarian_rejection_unregisters_with_lifecycle_authority () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  R.For_testing.clear ();
  Memory_lane.For_testing.reset ();
  let base_dir = temp_dir "librarian-lifecycle-rejection" in
  let keeper_name = "librarian-lifecycle-rejection" in
  Fun.protect
    ~finally:(fun () ->
      R.For_testing.clear ();
      Memory_lane.For_testing.reset ();
      cleanup_dir base_dir)
    (fun () ->
      let config = Masc.Workspace.default_config base_dir in
      ignore (Masc.Workspace.init config ~agent_name:(Some "tester"));
      let meta = make_meta keeper_name in
      Eio.Switch.run @@ fun sw ->
      Memory_lane.init ~sw;
      let librarian_started, resolve_librarian_started = Eio.Promise.create () in
      let librarian_release, resolve_librarian_release = Eio.Promise.create () in
      (match
         Memory_lane.submit
           ~base_path:config.base_path
           ~keeper_name
           (fun () ->
              Eio.Promise.resolve resolve_librarian_started ();
              Eio.Promise.await librarian_release)
       with
       | Memory_lane.Submitted -> ()
       | Memory_lane.Coalesced
       | Memory_lane.Ran_inline
       | Memory_lane.Dropped
       | Memory_lane.Rejected_draining ->
         fail "Librarian lifecycle rejection fixture was not submitted");
      Eio.Promise.await librarian_started;
      let token =
        match
          Keeper_lifecycle_reservation.acquire
            ~base_path:config.base_path
            ~keeper_name
            ~purpose:Keeper_lifecycle_reservation.Paused_work_disposition
        with
        | Ok token -> token
        | Error _ -> fail "failed to acquire lifecycle rejection fixture token"
      in
      let ctx : _ Keeper_types_profile.context =
        { config
        ; agent_name = "tester"
        ; sw
        ; clock = Eio.Stdenv.clock env
        ; proc_mgr = Some (Eio.Stdenv.process_mgr env)
        ; net = None
        ; publication_recovery_provider =
            Masc_test_deps.publication_recovery_provider
              (publication_recovery_registry env sw config)
        }
      in
      seed_keeper_sandbox_profile ~base_dir keeper_name;
      (match Masc.Keeper_keepalive.start_keepalive ~lifecycle_token:token ctx meta with
       | Masc.Keeper_keepalive.Keepalive_memory_lane_not_ready
           Memory_lane.Librarian_drain_still_active -> ()
       | outcome ->
         failf
           "Librarian rejection returned unexpected launch outcome: %s"
           (Masc.Keeper_keepalive.start_keepalive_outcome_to_string outcome));
      check bool
        "lifecycle-authorized rejection removed fresh registry entry"
        false
        (R.is_registered ~base_path:config.base_path keeper_name);
      (match Keeper_lifecycle_reservation.release token with
       | Keeper_lifecycle_reservation.Released -> ()
       | outcome ->
         fail
           ("failed to release lifecycle rejection fixture: "
            ^ Keeper_lifecycle_reservation.release_outcome_to_string outcome));
      Eio.Promise.resolve resolve_librarian_release ())

let test_start_keepalive_preserves_unresolved_failing_entry () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  R.For_testing.clear ();
  let base_dir = temp_dir "direct-keepalive-live-failing" in
  let keeper_name = "live-failing-entry" in
  Fun.protect
    ~finally:(fun () ->
      Masc.Keeper_keepalive.stop_keepalive keeper_name;
      R.For_testing.clear ();
      cleanup_dir base_dir)
    (fun () ->
      let config = Masc.Workspace.default_config base_dir in
      ignore (Masc.Workspace.init config ~agent_name:(Some "tester"));
      let meta = make_meta keeper_name in
      let original = R.For_testing.register ~base_path:config.base_path keeper_name meta in
      ignore
        (R.dispatch_event
           ~base_path:config.base_path
           keeper_name
           (KSM.Turn_failed { consecutive = 1 }));
      Eio.Switch.run @@ fun sw ->
      let ctx : _ Keeper_types_profile.context =
        {
          config;
          agent_name = "tester";
          sw;
          clock = Eio.Stdenv.clock env;
          proc_mgr = Some (Eio.Stdenv.process_mgr env);
          net = None;
          publication_recovery_provider =
            Masc_test_deps.publication_recovery_provider
              (publication_recovery_registry env sw config);
        }
      in
      seed_keeper_sandbox_profile ~base_dir keeper_name;
      ignore
        (Masc.Keeper_keepalive.start_keepalive ctx meta
          : Masc.Keeper_keepalive.start_keepalive_outcome);
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
  R.For_testing.clear ();
  let base_dir = temp_dir "direct-keepalive-stale-failing" in
  let keeper_name = "stale-failing-entry" in
  Fun.protect
    ~finally:(fun () ->
      Masc.Keeper_keepalive.stop_keepalive keeper_name;
      R.For_testing.clear ();
      cleanup_dir base_dir)
    (fun () ->
      let config = Masc.Workspace.default_config base_dir in
      ignore (Masc.Workspace.init config ~agent_name:(Some "tester"));
      let meta = make_meta keeper_name in
      let original = R.For_testing.register ~base_path:config.base_path keeper_name meta in
      ignore
        (R.dispatch_event
           ~base_path:config.base_path
           keeper_name
           (KSM.Turn_failed { consecutive = 1 }));
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
          publication_recovery_provider =
            Masc_test_deps.publication_recovery_provider
              (publication_recovery_registry env sw config);
        }
      in
      seed_keeper_sandbox_profile ~base_dir keeper_name;
      ignore
        (Masc.Keeper_keepalive.start_keepalive ctx meta
          : Masc.Keeper_keepalive.start_keepalive_outcome);
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
  R.For_testing.clear ();
  let keeper_name = "manual-stop-entry" in
  let reg = R.For_testing.register ~base_path:bp keeper_name (make_meta keeper_name) in
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
  R.For_testing.clear ();
  let keeper_name = "crashed-before-stop" in
  let reg = R.For_testing.register ~base_path:bp keeper_name (make_meta keeper_name) in
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
  R.For_testing.clear ();
  let keeper_name = "double-resolve-contract" in
  let reg = R.For_testing.register ~base_path:bp keeper_name (make_meta keeper_name) in
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

   Failure streaks are observational and do not terminate the Keeper lane.
   ══════════════════════════════════════════════════════════ *)

module ES = Masc.Keeper_status_runtime

(** Verify pipeline_stage_of_phase covers every phase and produces the
    expected deterministic mapping. No heuristic, no timestamps. The case
    list is checked against [KSM.all_phases], not a hand-counted literal —
    the literal 9 survived one phase removal and failed for weeks. *)
let test_pipeline_stage_of_phase_exhaustive () =
  let cases = [
    (KSM.Offline, "offline");
    (KSM.Running, "idle");
    (KSM.Failing, "failing");
    (KSM.Draining, "draining");
    (KSM.Paused, "paused");
    (KSM.Stopped, "offline");
    (KSM.Crashed, "crashed");
    (KSM.Restarting, "restarting");
  ] in
  check int "every phase has a pinned mapping"
    (List.length KSM.all_phases) (List.length cases);
  List.iter
    (fun phase ->
      check bool
        (Printf.sprintf "phase %s is pinned" (KSM.phase_to_string phase))
        true
        (List.mem_assoc phase cases))
    KSM.all_phases;
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
  R.For_testing.clear ();
  (* Unregistered: get_phase must return None *)
  check bool "unregistered → no phase"
    true (Option.is_none (R.get_phase ~base_path:bp "ghost"));
  (* Registered: get_phase returns real phase, of_phase gives deterministic stage *)
  let meta = make_meta "alive" in
  let _reg = R.For_testing.register ~base_path:bp "alive" meta in
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
    distinguishes running/failing/etc. *)
let test_pipeline_stage_sensitivity () =
  let non_offline_phases = [
    KSM.Running; KSM.Failing;
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
  let offline_phases = [KSM.Offline; KSM.Stopped] in
  List.iter (fun phase ->
    let stage = ES.pipeline_stage_of_phase phase in
    check string
      (Printf.sprintf "%s should map to offline"
         (KSM.phase_to_string phase))
      "offline" stage
  ) offline_phases

let test_runtime_observation_cannot_block_requested_turn () =
  let meta = make_meta "runtime-observation" in
  let obs =
    { base_observation with
      pending_messages =
        [ { Masc.Keeper_world_observation_message_scope.message_id = "mention-1"
          ; speaker = "operator"
          ; content = "please run"
          ; kind = Mention
          }
        ]
    }
  in
  let decision =
    KHL.decide_keepalive_scheduling
      ~stop:(Atomic.make false)
      ~meta
      obs
  in
  check bool "eligible turn reaches runtime boundary" true decision.should_run_turn;
  check (list string) "only the typed mention reason is retained"
    [ "mention_pending" ]
    decision.verdict_reasons

let test_explicit_stop_blocks_requested_turn () =
  let meta = make_meta "stopped-scheduling" in
  let obs =
    { base_observation with
      pending_messages =
        [ { Masc.Keeper_world_observation_message_scope.message_id = "mention-1"
          ; speaker = "operator"
          ; content = "please run"
          ; kind = Mention
          }
        ]
    }
  in
  let decision =
    KHL.decide_keepalive_scheduling
      ~stop:(Atomic.make true)
      ~meta
      obs
  in
  check bool "explicit loop stop prevents dispatch" false decision.should_run_turn

let test_turn_intake_uses_only_lifecycle () =
  let lifecycle =
    Keeper_lifecycle_admission.Autonomous_admitted
  in
  (match
     KHL.classify_turn_intake_admission ~lifecycle
   with
   | KHL.Intake_admitted -> ()
   | KHL.Intake_lifecycle_blocked _ ->
     fail "active lifecycle must admit intake");
  let paused_lifecycle =
    Keeper_lifecycle_admission.state ~paused:true ~latched_reason:None
    |> Keeper_lifecycle_admission.admit_autonomous
  in
  (match
     KHL.classify_turn_intake_admission ~lifecycle:paused_lifecycle
   with
   | KHL.Intake_lifecycle_blocked
       (Keeper_lifecycle_admission.Autonomous_paused _) -> ()
   | KHL.Intake_admitted ->
     fail "explicit Keeper pause must stop intake before durable dequeue")

let test_crashed_cycle_records_health_failure () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let base_path = temp_dir "health-feed" in
  let keeper_name = "health-feed-keeper" in
  Health.record_success ~agent_name:keeper_name;
  for i = 1 to 3 do
    KHL.record_crashed_cycle_failure
      ~base_path
      ~keeper_name
      (Failure (Printf.sprintf "boom-%d" i))
  done;
  let summary = Health.get_summary ~agent_name:keeper_name in
  check int "crashed cycles are observed" 3 summary.failure_count

let test_invalid_keeper_config_revision_name_creates_no_artifact () =
  let base_path = temp_dir "invalid-config-revision-name" in
  Fun.protect
    ~finally:(fun () -> cleanup_dir base_path)
    (fun () ->
      let config = Masc.Workspace.default_config base_path in
      let keepers_dir =
        Config_dir_resolver.keepers_dir_for_base_path ~base_path
      in
      let escaped =
        Filename.concat (Filename.dirname keepers_dir) "escaped.toml.lock"
      in
      (match
         Turn_up_config_persistence.current_config_revision
           ~config
           ~keeper_name:"../escaped"
       with
       | Ok _ -> fail "invalid Keeper name unexpectedly acquired a revision"
       | Error _ -> ());
      check bool "invalid name created no escaped lock artifact" false
        (Sys.file_exists escaped);
      check bool "invalid name created no keepers directory" false
        (Sys.file_exists keepers_dir))

(* ── Test runner ──────────────────────────────────────────── *)

(* keeper_up field-only update must resolve TOML-declared sandbox settings.
   The persisted meta never carries sandbox_profile/network_mode — the meta
   decoder pins them to the Local defaults — so an update that omitted
   sandbox_profile used to fall back to that pin, and the fail-closed
   playground gate rejected every field-only update on docker/microvm
   keepers (and a TOML "none" network mode would have read back inherit). *)
let test_field_only_update_honors_toml_declared_profile () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  Eio.Switch.run @@ fun sw ->
  let base_dir = temp_dir "update-toml-profile" in
  let gate = "MASC_EXEC_ALLOW_LOCAL_PLAYGROUND" in
  let prev_gate = Sys.getenv_opt gate in
  Fun.protect
    ~finally:(fun () ->
      Unix.putenv gate (Option.value prev_gate ~default:"0");
      cleanup_dir base_dir)
    (fun () ->
      (* Production posture: the local playground is off. *)
      Unix.putenv gate "0";
      let config = Masc.Workspace.default_config base_dir in
      let (_ : string) =
        Masc.Workspace.init config ~agent_name:(Some "tester")
      in
      install_owner_inventory_exn ~sw config;
      let name = "toml-docker-keeper" in
      let meta = make_meta name in
      create_owner_meta_exn config meta;
      let profile_defaults =
        { Keeper_profile_defaults.empty_keeper_profile_defaults with
          sandbox_profile = Some Keeper_types_profile.Docker
        }
      in
      let parsed : Turn_up_args.parsed_args =
        { name
        ; runtime_id_opt = None
        ; autoboot_enabled_opt = None
        ; mention_targets_opt = None
        ; max_context_override_opt = None
        ; max_context_override_present = false
        ; proactive_enabled_opt = None
        ; sandbox_profile_opt = None
        ; network_mode_opt = None
        ; remote_endpoint_opt = None
        ; remote_endpoint_present = false
        ; skill_names_opt = None
        ; skill_names_present = false
        ; native_tool_posture_opt = None
        ; native_tool_posture_present = false
        ; instructions_arg = Some "field-only update"
        ; profile_defaults
        ; declarative_manifest_snapshot =
            Keeper_types_profile.Declarative_manifest_missing
        ; instructions_opt = profile_defaults.instructions
        }
      in
      let ctx : _ Keeper_types_profile.context =
        { config
        ; agent_name = "tester"
        ; sw
        ; clock = Eio.Stdenv.clock env
        ; proc_mgr = None
        ; net = None
        ; publication_recovery_provider =
            Masc_test_deps.non_runtime_publication_recovery_provider
        }
      in
      let result =
        Turn_up_update.update_keeper
          ~expected_config_revision:(config_revision_exn config name)
          ctx
          parsed
          meta
      in
      check bool
        "field-only update on a TOML-declared docker keeper succeeds"
        true
        (Keeper_types_profile.tool_result_success result);
      ignore
        (Masc.Keeper_keepalive.stop_keepalive_and_await
           ~base_path:config.base_path
           name
          : Masc.Keeper_keepalive.joined_stop_result);
      (* Control: without any declared profile the same update still
         resolves Local and the gate stays closed. *)
      let bare = "no-declaration-keeper" in
      let bare_meta = make_meta bare in
      create_owner_meta_exn config bare_meta;
      let bare_parsed =
        { parsed with
          name = bare
        ; profile_defaults =
            Keeper_profile_defaults.empty_keeper_profile_defaults
        ; instructions_opt = None
        }
      in
      let bare_result =
        Turn_up_update.update_keeper
          ~expected_config_revision:(config_revision_exn config bare)
          ctx
          bare_parsed
          bare_meta
      in
      check bool
        "update without any declared profile still fails closed on Local"
        false
        (Keeper_types_profile.tool_result_success bare_result))
;;

let () =
  run "heartbeat_integration" [
    "structured_crash_flow", [
      eio_test "heartbeat_failure catch" test_crash_heartbeat_failure;
      eio_test "generic exception catch" test_crash_generic_exception;
      eio_test "fiber_unresolved fallback" test_crash_fiber_unresolved;
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
      test_case "fresh presence preserves turn failures" `Quick
        test_fresh_presence_preserves_turn_failures;
      test_case "crashed cycle surfaces as turn failure" `Quick
        test_crashed_cycle_records_turn_failure;
      test_case "turn status preserves configuration failure" `Quick
        test_turn_status_preserves_configuration_failure_reason;
      test_case "operator interrupt skips turn accounting" `Quick
        test_operator_interrupt_skips_turn_accounting;
    ];
    "direct_keepalive", [
      test_case "stop resolves done after lane exit" `Quick
        test_direct_start_keepalive_resolves_done_on_stop;
      test_case "cancelled launch owner rolls back under launch reservation" `Quick
        test_direct_start_rolls_back_when_the_launch_owner_is_already_cancelled;
      test_case "stop resolves done after Librarian drain failure" `Quick
        test_direct_stop_resolves_done_after_librarian_drain_failure;
      test_case "lane join waits for children and cleanup" `Quick
        test_keeper_lane_join_waits_for_children_and_cleanup;
      test_case "lane join surfaces cleanup failure" `Quick
        test_keeper_lane_surfaces_cleanup_failure;
      test_case "lane identity is typed and unique" `Quick
        test_keeper_lane_identity_is_typed_and_unique;
      test_case "lane cancellation is local and joinable" `Quick
        test_keeper_lane_cancel_is_lane_local_and_joinable;
      test_case "lane cancel before start is joinable" `Quick
        test_lane_cancel_before_start_is_joinable;
      test_case "shutdown store round-trip and identity guard" `Quick
        test_keeper_shutdown_store_round_trip_and_identity_guard;
      test_case "operator update supersedes exact blocked shutdown" `Quick
        test_operator_update_supersedes_exact_blocked_shutdown;
      test_case "field-only update honors TOML-declared profile" `Quick
        test_field_only_update_honors_toml_declared_profile;
      test_case "update rejects lane swap while turn in flight" `Quick
        test_update_keeper_rejects_lane_swap_while_turn_in_flight;
      test_case "cancelled update finishes lane swap" `Quick
        test_update_keeper_cancellation_finishes_lane_swap;
      test_case "keeper up shared boundary outlives calling turn" `Quick
        test_keeper_up_shared_boundary_outlives_calling_turn;
      test_case "shutdown store isolates corrupt owner" `Quick
        test_keeper_shutdown_store_isolates_corrupt_owner;
      test_case "terminal shutdown recovery releases admission" `Quick
        test_terminal_shutdown_recovery_releases_admission;
      test_case "unsupported shutdown schema retains exact fence" `Quick
        test_unsupported_shutdown_schema_retains_exact_fence;
      test_case "dashboard purge resolution is fail closed" `Quick
        test_dashboard_purge_resolution_is_fail_closed;
      test_case "Librarian rejection unregisters with lifecycle authority" `Quick
        test_librarian_rejection_unregisters_with_lifecycle_authority;
      test_case "shutdown prepare joins idle lane" `Quick
        test_keeper_shutdown_prepare_joins_idle_lane;
      test_case "shutdown owner failure persists blocked join" `Quick
        test_keeper_shutdown_owner_failure_persists_blocked_join;
      test_case "shutdown blocks join replay after record failure" `Quick
        test_keeper_shutdown_blocks_join_replay_after_record_failure;
      test_case "shutdown prepare joins not-started lane" `Quick
        test_keeper_shutdown_prepare_joins_not_started_lane;
      test_case "shutdown prepare failure rolls back admission fence" `Quick
        test_keeper_shutdown_prepare_failure_rolls_back_fence;
      test_case "cancelled dormant shutdown join rolls back admission fence" `Quick
        test_keeper_dormant_shutdown_join_cancel_rolls_back_fence;
      test_case "shutdown finalizes idle operation" `Quick
        test_keeper_shutdown_finalizes_idle_operation;
      test_case "destructive shutdown blocks on bound summary" `Quick
        test_destructive_shutdown_drains_bound_summary_then_completes;
      test_case "dashboard purge finalizes artifacts and receipt" `Quick
        test_dashboard_keeper_purge_finalizes_artifacts_and_receipt;
      test_case "shutdown cleanup replays after meta removal" `Quick
        test_keeper_shutdown_cleanup_replays_after_meta_removal;
      test_case "shutdown rejects stale snapshot delete" `Quick
        test_keeper_shutdown_rejects_stale_snapshot_delete;
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
      test_case "exhaustive 9-phase mapping" `Quick
        test_pipeline_stage_of_phase_exhaustive;
	      test_case "offline projection details remain distinct" `Quick
	        test_pipeline_stage_detail_distinguishes_offline_projection;
	      test_case "unregistered keeper → offline" `Quick
	        test_pipeline_stage_unregistered_is_offline;
      test_case "sensitivity: active phases ≠ offline" `Quick
        test_pipeline_stage_sensitivity;
    ];
    "scheduling", [
      test_case "invalid config revision name creates no artifact" `Quick
        test_invalid_keeper_config_revision_name_creates_no_artifact;
      test_case "runtime observations cannot block requested turn" `Quick
        test_runtime_observation_cannot_block_requested_turn;
      test_case "explicit stop blocks requested turn" `Quick
        test_explicit_stop_blocks_requested_turn;
      test_case "active and paused lifecycle classify intake" `Quick
        test_turn_intake_uses_only_lifecycle;
      test_case "crashed cycles feed agent health breaker" `Quick
        test_crashed_cycle_records_health_failure;
    ];
  ]
