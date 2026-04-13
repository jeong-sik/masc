(** Admission Queue Coverage Tests

    Tests for MASC inference admission queue (passthrough mode).
    Provider-level throttling is handled by OAS cascade, not MASC.
    These tests verify the passthrough contract: with_permit and
    try_with_permit always run the callback immediately. *)

open Alcotest

module AQ = Masc_mcp.Admission_queue

(* ============================================================
   Passthrough Contract
   ============================================================ *)

let test_with_permit_runs () =
  Eio_main.run (fun _env ->
    let result = AQ.with_permit ~priority:Interactive
      ~keeper_name:"test" ~cascade_name:"test" (fun () -> 42) in
    check int "runs and returns" 42 result)

let test_with_permit_propagates_exception () =
  Eio_main.run (fun _env ->
    (try AQ.with_permit ~priority:Interactive
       ~keeper_name:"test" ~cascade_name:"test"
       (fun () -> failwith "boom")
     with Failure msg -> check string "exception propagates" "boom" msg))

let test_try_always_succeeds () =
  Eio_main.run (fun _env ->
    let result = AQ.try_with_permit ~priority:Interactive
      ~keeper_name:"test" ~cascade_name:"test" (fun () -> 42) in
    check (option int) "always Some" (Some 42) result)

let test_concurrent_all_run () =
  Eio_main.run (fun _env ->
    let count = Atomic.make 0 in
    let run_one name =
      AQ.with_permit ~priority:Proactive
        ~keeper_name:name ~cascade_name:"test"
        (fun () ->
          ignore (Atomic.fetch_and_add count 1);
          Eio.Fiber.yield ())
    in
    Eio.Fiber.all [
      (fun () -> run_one "k1");
      (fun () -> run_one "k2");
      (fun () -> run_one "k3");
      (fun () -> run_one "k4");
    ];
    check int "all 4 ran" 4 (Atomic.get count))

(* ============================================================
   Configuration (env parsing still works)
   ============================================================ *)

let test_initial_max_concurrent_default () =
  check int "default" 3 (AQ.initial_max_concurrent_of_env (fun _ -> None))

let test_initial_max_concurrent_prefers_masc_env () =
  let getenv = function
    | "MASC_ADMISSION_MAX_CONCURRENT" -> Some "8"
    | _ -> None
  in
  check int "uses explicit MASC env" 8 (AQ.initial_max_concurrent_of_env getenv)

let test_initial_max_concurrent_ignores_ollama_parallel () =
  let getenv = function
    | "OLLAMA_NUM_PARALLEL" -> Some "1"
    | _ -> None
  in
  check int "ollama env ignored" 3 (AQ.initial_max_concurrent_of_env getenv)

let test_initial_max_concurrent_clamps_min_one () =
  let getenv = function
    | "MASC_ADMISSION_MAX_CONCURRENT" -> Some "0"
    | _ -> None
  in
  check int "clamped" 1 (AQ.initial_max_concurrent_of_env getenv)

let test_wait_timeout_no_leak () =
  Eio_main.run (fun env ->
    AQ.reset_for_test ~max_slots:1;
    Eio_context.set_clock (Eio.Stdenv.clock env);
    let hold, release_hold = Eio.Promise.create () in
    let timeout_seen = ref None in
    Eio.Fiber.both
      (fun () ->
        AQ.with_permit ~priority:Interactive
          ~keeper_name:"blocker" ~cascade_name:"test"
          (fun () -> Eio.Promise.await hold))
      (fun () ->
        Eio.Fiber.yield ();
        (try
           AQ.with_permit ~wait_timeout_sec:0.01 ~priority:Background
             ~keeper_name:"timed-out" ~cascade_name:"test"
             (fun () -> ())
         with AQ.Wait_timeout wait_ms ->
           timeout_seen := Some wait_ms);
        Eio.Promise.resolve release_hold ());
    check bool "wait timeout raised" true (Option.is_some !timeout_seen);
    let s = AQ.snapshot () in
    check int "no leaked slots" 0 s.active;
    check int "queue cleared" 0 s.queue_depth)

(* ============================================================
   Configuration Tests
   ============================================================ *)

let test_set_max_concurrent () =
  Eio_main.run (fun _env ->
    AQ.reset_for_test ~max_slots:4;
    AQ.set_max_concurrent 8;
    check int "updated" 8 (AQ.max_concurrent ());
    AQ.set_max_concurrent 4)

let test_max_concurrent_metric_tracks_capacity () =
  Eio_main.run (fun _env ->
    AQ.reset_for_test ~max_slots:3;
    let initial =
      Masc_mcp.Prometheus.metric_value_or_zero
        "masc_inference_queue_max_concurrent" ()
    in
    check (float 0.1) "metric initialized" 3.0 initial;
    AQ.set_max_concurrent 5;
    let updated =
      Masc_mcp.Prometheus.metric_value_or_zero
        "masc_inference_queue_max_concurrent" ()
    in
    check (float 0.1) "metric updated" 5.0 updated)

let test_set_max_concurrent_rejects_zero () =
  try AQ.set_max_concurrent 0; fail "should raise"
  with Invalid_argument _ -> ()

let test_snapshot_json_shape () =
  Eio_main.run (fun _env ->
    let json = AQ.snapshot_json () in
    match json with
    | `Assoc fields ->
      check bool "has max_concurrent" true
        (List.mem_assoc "max_concurrent" fields);
      check bool "has queue_depth" true
        (List.mem_assoc "queue_depth" fields);
      check bool "has waiters" true
        (List.mem_assoc "waiters" fields)
    | _ -> fail "expected Assoc")

(* ============================================================
   Runner
   ============================================================ *)

let () =
  run "Admission_queue" [
    "passthrough", [
      test_case "with_permit runs" `Quick test_with_permit_runs;
      test_case "propagates exception" `Quick test_with_permit_propagates_exception;
      test_case "try always succeeds" `Quick test_try_always_succeeds;
      test_case "concurrent all run" `Quick test_concurrent_all_run;
      test_case "wait timeout no leak" `Quick test_wait_timeout_no_leak;
    ];
    "config", [
      test_case "initial default" `Quick test_initial_max_concurrent_default;
      test_case "initial prefers masc env" `Quick
        test_initial_max_concurrent_prefers_masc_env;
      test_case "initial ignores ollama env" `Quick
        test_initial_max_concurrent_ignores_ollama_parallel;
      test_case "initial clamps min one" `Quick
        test_initial_max_concurrent_clamps_min_one;
      test_case "set_max_concurrent" `Quick test_set_max_concurrent;
      test_case "max_concurrent metric tracks capacity" `Quick
        test_max_concurrent_metric_tracks_capacity;
      test_case "rejects zero" `Quick test_set_max_concurrent_rejects_zero;
      test_case "snapshot_json shape" `Quick test_snapshot_json_shape;
    ];
  ]
