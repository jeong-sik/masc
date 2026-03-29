(** Test suite for Keeper_supervisor — fiber liveness tracking and recovery.
    Pure tests for backoff/helpers. Fiber health queries now delegate to
    Keeper_registry (tested in test_keeper_registry.ml). *)

open Alcotest
module Sup = Masc_mcp.Keeper_supervisor
module Reg = Masc_mcp.Keeper_registry
module KT = Masc_mcp.Keeper_types

(* ── Pure tests: backoff_delay ──────────────────────────── *)

let test_backoff_delay_attempt_0 () =
  (* Default base: 10.0s *)
  let d = Sup.backoff_delay 0 in
  check (float 0.1) "attempt 0 = base" 10.0 d

let test_backoff_delay_exponential () =
  let d1 = Sup.backoff_delay 1 in
  let d2 = Sup.backoff_delay 2 in
  let d3 = Sup.backoff_delay 3 in
  check (float 0.1) "attempt 1 = 2*base" 20.0 d1;
  check (float 0.1) "attempt 2 = 4*base" 40.0 d2;
  check (float 0.1) "attempt 3 = 8*base" 80.0 d3

let test_backoff_delay_cap () =
  (* Default max: 300.0s. 2^5 * 10 = 320 > 300 *)
  let d5 = Sup.backoff_delay 5 in
  check (float 0.1) "attempt 5 capped at 300" 300.0 d5;
  let d10 = Sup.backoff_delay 10 in
  check (float 0.1) "attempt 10 capped at 300" 300.0 d10

(* ── Pure tests: keep_last_n ────────────────────────────── *)

let test_keep_last_n_under_limit () =
  let result = Sup.keep_last_n 5 "a" ["b"; "c"] in
  check int "length 3" 3 (List.length result);
  check string "first is new item" "a" (List.hd result)

let test_keep_last_n_at_limit () =
  let result = Sup.keep_last_n 3 "a" ["b"; "c"] in
  check int "length 3" 3 (List.length result);
  check string "first is new item" "a" (List.hd result)

let test_keep_last_n_over_limit () =
  let result = Sup.keep_last_n 3 "a" ["b"; "c"; "d"] in
  check int "length capped at 3" 3 (List.length result);
  check string "first is new item" "a" (List.hd result);
  (* oldest item "d" should be dropped *)
  check bool "old item dropped" false (List.mem "d" result)

(* ── Registry-based tests (replacing removed supervisor Hashtbl queries) *)

let test_fiber_health_unknown () =
  Reg.clear ();
  let health = Reg.fiber_health_of ~base_path:"/tmp" "nonexistent-keeper" in
  check bool "unknown for unregistered"
    true (health = KT.Fiber_unknown)

let test_registry_count_initially_zero () =
  Reg.clear ();
  check int "no keepers initially" 0 (Reg.count_running ())

let test_crash_log_empty_for_unknown () =
  Reg.clear ();
  check int "empty crash log" 0
    (List.length (Reg.crash_log_of ~base_path:"/tmp" "nonexistent"))

let test_should_cleanup_dead_true () =
  Reg.clear ();
  let _entry = Reg.register ~base_path:"/tmp" "dead1"
      (let json = `Assoc [
        ("name", `String "dead1");
        ("agent_name", `String "agent-dead1");
        ("trace_id", `String "trace-dead1");
        ("goal", `String "goal");
      ] in
      match KT.meta_of_json json with
      | Ok meta -> meta
      | Error err -> fail err)
  in
  Reg.mark_dead ~base_path:"/tmp" "dead1" ~at:10.0;
  let entry = Option.get (Reg.get ~base_path:"/tmp" "dead1") in
  check bool "ttl exceeded" true
    (Sup.should_cleanup_dead ~now:4000.0 ~dead_ttl_sec:3600.0 entry)

let test_should_cleanup_dead_false_when_recent () =
  Reg.clear ();
  let _entry = Reg.register ~base_path:"/tmp" "dead2"
      (let json = `Assoc [
        ("name", `String "dead2");
        ("agent_name", `String "agent-dead2");
        ("trace_id", `String "trace-dead2");
        ("goal", `String "goal");
      ] in
      match KT.meta_of_json json with
      | Ok meta -> meta
      | Error err -> fail err)
  in
  Reg.mark_dead ~base_path:"/tmp" "dead2" ~at:100.0;
  let entry = Option.get (Reg.get ~base_path:"/tmp" "dead2") in
  check bool "ttl not exceeded" false
    (Sup.should_cleanup_dead ~now:200.0 ~dead_ttl_sec:3600.0 entry)

(* ── Test runner ────────────────────────────────────────── *)

let () =
  run "keeper_supervisor" [
    "backoff", [
      test_case "attempt 0 = base" `Quick test_backoff_delay_attempt_0;
      test_case "exponential growth" `Quick test_backoff_delay_exponential;
      test_case "cap at max" `Quick test_backoff_delay_cap;
    ];
    "keep_last_n", [
      test_case "under limit" `Quick test_keep_last_n_under_limit;
      test_case "at limit" `Quick test_keep_last_n_at_limit;
      test_case "over limit drops oldest" `Quick test_keep_last_n_over_limit;
    ];
    "fiber_health", [
      test_case "unknown for unregistered" `Quick test_fiber_health_unknown;
      test_case "registry count zero" `Quick test_registry_count_initially_zero;
      test_case "crash_log empty" `Quick test_crash_log_empty_for_unknown;
      test_case "should cleanup dead when ttl exceeded" `Quick test_should_cleanup_dead_true;
      test_case "should not cleanup dead when recent" `Quick test_should_cleanup_dead_false_when_recent;
    ];
  ]
