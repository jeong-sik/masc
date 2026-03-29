(** Test suite for Phase 2: keeper_state extensions, failure_reason ADT,
    is_registered, self-preservation config, and state transition invariants. *)

open Alcotest

module R = Masc_mcp.Keeper_registry
module KT = Masc_mcp.Keeper_types
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
  R.set_state ~base_path:bp "k1" R.Crashed;
  match R.get ~base_path:bp "k1" with
  | None -> fail "expected k1"
  | Some e ->
    check string "state is crashed" "crashed" (R.state_to_string e.state)

let test_state_to_string_dead () =
  R.clear ();
  let _entry = R.register ~base_path:bp "k1" (make_meta "k1") in
  R.set_state ~base_path:bp "k1" R.Dead;
  match R.get ~base_path:bp "k1" with
  | None -> fail "expected k1"
  | Some e ->
    check string "state is dead" "dead" (R.state_to_string e.state)

let test_running_count_crashed () =
  R.clear ();
  let _e1 = R.register ~base_path:bp "a" (make_meta "a") in
  let _e2 = R.register ~base_path:bp "b" (make_meta "b") in
  check int "2 running" 2 (R.count_running ());
  R.set_state ~base_path:bp "a" R.Crashed;
  check int "1 running after crash" 1 (R.count_running ());
  R.set_state ~base_path:bp "b" R.Dead;
  check int "0 running after dead" 0 (R.count_running ())

(* ── is_registered ────────────────────────────────────── *)

let test_is_registered_running () =
  R.clear ();
  let _e = R.register ~base_path:bp "k1" (make_meta "k1") in
  check bool "running → registered" true (R.is_registered ~base_path:bp "k1")

let test_is_registered_crashed () =
  R.clear ();
  let _e = R.register ~base_path:bp "k1" (make_meta "k1") in
  R.set_state ~base_path:bp "k1" R.Crashed;
  check bool "crashed → still registered" true (R.is_registered ~base_path:bp "k1")

let test_is_registered_dead () =
  R.clear ();
  let _e = R.register ~base_path:bp "k1" (make_meta "k1") in
  R.set_state ~base_path:bp "k1" R.Dead;
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
  R.set_state ~base_path:bp "k1" R.Crashed;
  check int "0 running" 0 (R.count_running ());
  check bool "is_running false" false (R.is_running ~base_path:bp "k1");
  check bool "is_registered true" true (R.is_registered ~base_path:bp "k1");
  (* Simulate restart: re-register *)
  let _e2 = R.register ~base_path:bp "k1" (make_meta "k1") in
  check int "1 running again" 1 (R.count_running ())

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
    ];
    "config", [
      test_case "ratio default" `Quick test_self_preservation_ratio_default;
      test_case "min candidates default" `Quick test_self_preservation_min_candidates_default;
      test_case "dead TTL default" `Quick test_dead_ttl_default;
      test_case "dead TTL floor" `Quick test_dead_ttl_floor;
    ];
    "state_transitions", [
      eio_test "Running → Crashed → Running" test_state_transition_running_crashed_running;
    ];
  ]
