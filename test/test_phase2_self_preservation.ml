(** Test suite for Phase 2: keeper_state extensions, failure_reason ADT,
    is_registered, self-preservation config, and state transition invariants. *)

open Alcotest

module R = Masc_mcp.Keeper_registry
module KT = Masc_mcp.Keeper_types
module KSM = Masc_mcp.Keeper_state_machine
module KMR = Masc_mcp.Keeper_manual_reconcile
module Cfg = Env_config

let bp = "/tmp/test-phase2"

let make_meta name =
  let json = `Assoc [
    ("name", `String name);
    ("agent_name", `String ("agent-" ^ name));
    ("trace_id", `String ("trace-test-" ^ name));
    ("goal", `String "test goal");
  ] in
  match KT.meta_of_json json with
  | Ok meta -> meta
  | Error err -> Alcotest.fail ("make_meta failed: " ^ err)

let eio_test name fn =
  test_case name `Quick (fun () -> Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env); fn ())

(* ── keeper_state: Crashed + Dead ─────────────────────── *)

let test_state_to_string_crashed () =
  R.clear ();
  let _entry = R.register ~base_path:bp "k1" (make_meta "k1") in
  ignore (R.dispatch_event ~base_path:bp "k1"
    (KSM.Fiber_terminated { outcome = "test" }));
  match R.get ~base_path:bp "k1" with
  | None -> fail "expected k1"
  | Some e ->
    check string "state is crashed" "crashed" (KSM.phase_to_string e.phase)

let test_state_to_string_dead () =
  R.clear ();
  let _entry = R.register ~base_path:bp "k1" (make_meta "k1") in
  R.mark_dead ~base_path:bp "k1" ~at:(Unix.gettimeofday ());
  match R.get ~base_path:bp "k1" with
  | None -> fail "expected k1"
  | Some e ->
    check string "state is dead" "dead" (KSM.phase_to_string e.phase)

let test_running_count_crashed () =
  R.clear ();
  let _e1 = R.register ~base_path:bp "a" (make_meta "a") in
  let _e2 = R.register ~base_path:bp "b" (make_meta "b") in
  check int "2 running" 2 (R.count_running ());
  ignore (R.dispatch_event ~base_path:bp "a"
    (KSM.Fiber_terminated { outcome = "test" }));
  check int "1 running after crash" 1 (R.count_running ());
  R.mark_dead ~base_path:bp "b" ~at:(Unix.gettimeofday ());
  check int "0 running after dead" 0 (R.count_running ())

(* ── is_registered ────────────────────────────────────── *)

let test_is_registered_running () =
  R.clear ();
  let _e = R.register ~base_path:bp "k1" (make_meta "k1") in
  check bool "running → registered" true (R.is_registered ~base_path:bp "k1")

let test_is_registered_crashed () =
  R.clear ();
  let _e = R.register ~base_path:bp "k1" (make_meta "k1") in
  ignore (R.dispatch_event ~base_path:bp "k1"
    (KSM.Fiber_terminated { outcome = "test" }));
  check bool "crashed → still registered" true (R.is_registered ~base_path:bp "k1")

let test_is_registered_dead () =
  R.clear ();
  let _e = R.register ~base_path:bp "k1" (make_meta "k1") in
  R.mark_dead ~base_path:bp "k1" ~at:(Unix.gettimeofday ());
  check bool "dead → still registered" true (R.is_registered ~base_path:bp "k1")

let test_is_registered_unregistered () =
  R.clear ();
  check bool "absent → not registered" false (R.is_registered ~base_path:bp "k1")

let test_is_registered_after_unregister () =
  R.clear ();
  let _e = R.register ~base_path:bp "k1" (make_meta "k1") in
  R.unregister ~base_path:bp "k1";
  check bool "unregistered → not registered" false (R.is_registered ~base_path:bp "k1")

(* ── failure_reason ADT ───────────────────────────────── *)

let test_failure_reason_heartbeat () =
  let s = R.failure_reason_to_string (R.Heartbeat_consecutive_failures 5) in
  check string "heartbeat reason" "heartbeat_consecutive_failures(5)" s

let test_failure_reason_fiber () =
  let s = R.failure_reason_to_string R.Fiber_unresolved in
  check string "fiber reason" "fiber_unresolved" s

let test_failure_reason_exception () =
  let s = R.failure_reason_to_string (R.Exception "Sys_error(disk full)") in
  check string "exception reason" "exception(Sys_error(disk full))" s

let test_failure_reason_ambiguous_partial_commit () =
  let s =
    R.failure_reason_to_string
      (R.Ambiguous_partial_commit
         {
           kind = R.Post_commit_timeout;
           detail = "turn outcome ambiguous";
         })
  in
  check string "ambiguous partial commit reason"
    "ambiguous_partial_commit(post_commit_timeout:turn outcome ambiguous)" s

let test_failure_reason_ambiguous_partial_commit_kind_string () =
  check string "ambiguous partial commit kind string"
    "post_commit_timeout"
    (R.ambiguous_partial_commit_kind_to_string R.Post_commit_timeout)

let test_failure_reason_manual_reconcile_required () =
  check bool "ambiguous partial commit requires manual reconcile" true
    (R.failure_reason_requires_manual_reconcile
       (R.Ambiguous_partial_commit
          {
            kind = R.Post_commit_failure;
            detail = "turn outcome ambiguous";
          }));
  check bool "turn failures do not require manual reconcile" false
    (R.failure_reason_requires_manual_reconcile
       (R.Turn_consecutive_failures 2))

(* ── Config defaults ──────────────────────────────────── *)

let test_self_preservation_ratio_default () =
  let v = Cfg.KeeperSupervisor.self_preservation_ratio in
  check (float 0.01) "default ratio 0.3" 0.3 v

let test_self_preservation_min_candidates_default () =
  let v = Cfg.KeeperSupervisor.self_preservation_min_candidates in
  check int "default min candidates 2" 2 v

let test_dead_ttl_default () =
  let v = Cfg.KeeperSupervisor.dead_ttl_sec in
  check (float 0.1) "default dead TTL 3600s" 3600.0 v

let test_dead_ttl_floor () =
  let v = Cfg.KeeperSupervisor.dead_ttl_sec in
  check bool "dead TTL >= 60s" true (v >= 60.0)

(* ── State transition: Running → Crashed → Running ───── *)

let test_state_transition_running_crashed_running () =
  R.clear ();
  let _e = R.register ~base_path:bp "k1" (make_meta "k1") in
  check int "1 running" 1 (R.count_running ());
  ignore (R.dispatch_event ~base_path:bp "k1"
    (KSM.Fiber_terminated { outcome = "test" }));
  check int "0 running" 0 (R.count_running ());
  check bool "is_running false" false (R.is_running ~base_path:bp "k1");
  check bool "is_registered true" true (R.is_registered ~base_path:bp "k1");
  (* Simulate restart: re-register *)
  let _e2 = R.register ~base_path:bp "k1" (make_meta "k1") in
  check int "1 running again" 1 (R.count_running ())

(* ── Dead is terminal: set_state Dead → Running is no-op ── *)

let test_dead_to_running_blocked () =
  R.clear ();
  let _e = R.register ~base_path:bp "k1" (make_meta "k1") in
  R.mark_dead ~base_path:bp "k1" ~at:(Unix.gettimeofday ());
  check int "0 running" 0 (R.count_running ());
  (* Attempt to transition Dead → Running via set_state *)
  ignore (R.dispatch_event ~base_path:bp "k1" KSM.Fiber_started);
  match R.get ~base_path:bp "k1" with
  | None -> fail "expected k1"
  | Some e ->
    check string "still dead" "dead" (KSM.phase_to_string e.phase);
    check int "still 0 running" 0 (R.count_running ())

(* ── Fix 1: last_failure_reason stored in registry ────── *)

let test_failure_reason_stored () =
  R.clear ();
  let _e = R.register ~base_path:bp "k1" (make_meta "k1") in
  (* Initially None *)
  (match R.get ~base_path:bp "k1" with
   | Some e -> check bool "initially None" true (Option.is_none e.last_failure_reason)
   | None -> fail "expected k1");
  (* Set a reason *)
  R.set_failure_reason ~base_path:bp "k1"
    (Some (R.Heartbeat_consecutive_failures 5));
  match R.get ~base_path:bp "k1" with
  | None -> fail "expected k1"
  | Some e ->
    check bool "has reason" true (Option.is_some e.last_failure_reason);
    (match e.last_failure_reason with
     | Some (R.Heartbeat_consecutive_failures n) ->
       check int "failure count" 5 n
     | _ -> fail "expected Heartbeat_consecutive_failures")

let test_failure_reason_cleared_on_reregister () =
  R.clear ();
  let _e = R.register ~base_path:bp "k1" (make_meta "k1") in
  R.set_failure_reason ~base_path:bp "k1"
    (Some R.Fiber_unresolved);
  (* Re-register (simulates restart) clears the reason *)
  let _e2 = R.register ~base_path:bp "k1" (make_meta "k1") in
  match R.get ~base_path:bp "k1" with
  | None -> fail "expected k1"
  | Some e ->
    check bool "cleared on re-register" true
      (Option.is_none e.last_failure_reason)

(* ── Fix 2: Cohort detection uses ADT, not string prefix ── *)

module Sup = Masc_mcp.Keeper_supervisor

let test_cohort_key_heartbeat () =
  let key = Sup.cohort_key_of_reason
    (Some (R.Heartbeat_consecutive_failures 3)) in
  check string "heartbeat cohort" "heartbeat_failures" key

let test_cohort_key_fiber () =
  let key = Sup.cohort_key_of_reason (Some R.Fiber_unresolved) in
  check string "fiber cohort" "fiber_unresolved" key

let test_cohort_key_exception () =
  let key = Sup.cohort_key_of_reason
    (Some (R.Exception "Sys_error(disk full)")) in
  check string "exception cohort" "exception" key

let test_cohort_key_none () =
  let key = Sup.cohort_key_of_reason None in
  check string "unknown cohort" "unknown" key

(* ── Fix 2: Dead tombstone lifecycle ─────────────────── *)

let test_dead_tombstone_is_registered () =
  R.clear ();
  let _e = R.register ~base_path:bp "k1" (make_meta "k1") in
  ignore (R.dispatch_event ~base_path:bp "k1"
    (KSM.Fiber_terminated { outcome = "test" }));
  R.mark_dead ~base_path:bp "k1" ~at:(Unix.gettimeofday ());
  (* Dead keeper is still registered — reconcile must skip *)
  check bool "Dead is registered" true (R.is_registered ~base_path:bp "k1");
  check bool "Dead is not running" false (R.is_running ~base_path:bp "k1")

let test_manual_reconcile_store_roundtrip () =
  let dir = Filename.concat (Filename.get_temp_dir_name ()) "test-phase2-manual-reconcile" in
  (try Unix.mkdir dir 0o755 with Unix.Unix_error (Unix.EEXIST, _, _) -> ());
  let config = Masc_mcp.Room.default_config dir in
  let record =
    KMR.open_pending config
      ~keeper_name:"k1"
      ~blocker_class:"ambiguous_post_commit_timeout"
      ~summary:"turn outcome ambiguous"
      ~failure_reason:(Some "ambiguous_partial_commit(post_commit_timeout:test)")
      ~trace_id:(Some "trace-k1")
      ~generation:(Some 2)
      ~committed_tools:["keeper_shell"; "keeper_task_done"]
  in
  check bool "pending after open" true (KMR.is_pending config "k1");
  check string "cache key opened" record.updated_at
    (match String.split_on_char '|' (KMR.cache_key config "k1") with
     | _status :: updated_at :: _ -> updated_at
     | _ -> "");
  match KMR.clear config ~keeper_name:"k1" ~actor:"tester"
          ~resolution:"verified downstream side effects"
          ~evidence_refs:["board:p-1"; "task:T-1"]
          ~idempotency_key:(Some "idem-1")
  with
  | KMR.Cleared_record cleared ->
      check bool "not pending after clear" false (KMR.is_pending config "k1");
      check string "status cleared" "cleared"
        (match KMR.read config "k1" with
         | Some record -> (
             match record.status with
             | KMR.Cleared -> "cleared"
             | KMR.Pending -> "pending")
         | None -> "missing");
      check string "resolution persisted" "verified downstream side effects"
        (Option.value ~default:"" cleared.resolution)
  | KMR.Already_cleared _ -> fail "expected first clear to mutate"
  | KMR.No_record -> fail "expected persisted record"

(* ── Test runner ──────────────────────────────────────── *)

let () =
  run "phase2_self_preservation" [
    "keeper_state", [
      eio_test "crashed state" test_state_to_string_crashed;
      eio_test "dead state" test_state_to_string_dead;
      eio_test "running count with crashed/dead" test_running_count_crashed;
    ];
    "is_registered", [
      eio_test "running" test_is_registered_running;
      eio_test "crashed" test_is_registered_crashed;
      eio_test "dead" test_is_registered_dead;
      eio_test "absent" test_is_registered_unregistered;
      eio_test "after unregister" test_is_registered_after_unregister;
    ];
    "failure_reason", [
      test_case "heartbeat" `Quick test_failure_reason_heartbeat;
      test_case "fiber_unresolved" `Quick test_failure_reason_fiber;
      test_case "exception" `Quick test_failure_reason_exception;
      test_case "ambiguous partial commit" `Quick
        test_failure_reason_ambiguous_partial_commit;
      test_case "ambiguous partial commit kind string" `Quick
        test_failure_reason_ambiguous_partial_commit_kind_string;
      test_case "manual reconcile helper" `Quick
        test_failure_reason_manual_reconcile_required;
    ];
    "config", [
      test_case "ratio default" `Quick test_self_preservation_ratio_default;
      test_case "min candidates default" `Quick test_self_preservation_min_candidates_default;
      test_case "dead TTL default" `Quick test_dead_ttl_default;
      test_case "dead TTL floor" `Quick test_dead_ttl_floor;
    ];
    "state_transitions", [
      eio_test "Running → Crashed → Running" test_state_transition_running_crashed_running;
      eio_test "Dead → Running blocked" test_dead_to_running_blocked;
    ];
    "failure_reason_field", [
      eio_test "stored in registry" test_failure_reason_stored;
      eio_test "cleared on re-register" test_failure_reason_cleared_on_reregister;
    ];
    "cohort_detection", [
      test_case "heartbeat key" `Quick test_cohort_key_heartbeat;
      test_case "fiber key" `Quick test_cohort_key_fiber;
      test_case "exception key" `Quick test_cohort_key_exception;
      test_case "none key" `Quick test_cohort_key_none;
    ];
    "dead_tombstone", [
      eio_test "Dead is registered but not running" test_dead_tombstone_is_registered;
    ];
    "manual_reconcile_store", [
      eio_test "pending -> clear roundtrip" test_manual_reconcile_store_roundtrip;
    ];
  ]
