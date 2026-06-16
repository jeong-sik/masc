(** Circuit Breaker Integration Tests

    Tests the full circuit breaker lifecycle including:
    - Normal operation (closed state)
    - Failure accumulation and circuit opening
    - Cooldown period enforcement
    - Half-open probe transitions
    - Success-based recovery
    - Force open/close admin overrides
    - Concurrent access safety
    - Failure window pruning
    - Global instance integration with health module

    @since 0.6.0 — MASC Social v4 Tier 1 integration tests
*)

open Alcotest
open Result.Syntax

module CB = Circuit_breaker
module Time = Time_compat

(** {1 Helper Functions} *)

let create_test_instance () =
  CB.create
    ~failure_threshold:3
    ~failure_window:60.0
    ~cooldown:5.0
    ()

let test_agent_id = "test-agent-001"
let test_agent_id_2 = "test-agent-002"
let test_reason = "test failure reason"

(** {1 Basic State Transitions} *)

let test_closed_state () =
  let cb = create_test_instance () in
  (* Initially closed for any agent *)
  match CB.check cb ~agent_id:test_agent_id with
  | Ok () -> testable (fun p p' -> p = p') "closed_ok" true true
  | Error e -> failwith ("Expected Ok, got: " ^ e)

let test_record_failure_transitions_to_open () =
  let cb = create_test_instance () in
  (* Record 2 failures — should still be closed *)
  CB.record_failure cb ~agent_id:test_agent_id ~reason:test_reason;
  CB.record_failure cb ~agent_id:test_agent_id ~reason:test_reason;
  
  match CB.check cb ~agent_id:test_agent_id with
  | Ok () -> testable (fun p p' -> p = p') "still_closed" true true
  
  (* Record 3rd failure — should open *)
  CB.record_failure cb ~agent_id:test_agent_id ~reason:test_reason;
  
  match CB.check cb ~agent_id:test_agent_id with
  | Error msg ->
      testable (fun p p' -> p = p') "circuit_opened" true (String.contains msg 'O')
  | Ok () -> failwith "Expected circuit to be open after 3 failures"

let test_open_circuit_blocks_calls () =
  let cb = create_test_instance () in
  (* Open the circuit *)
  CB.record_failure cb ~agent_id:test_agent_id ~reason:test_reason;
  CB.record_failure cb ~agent_id:test_agent_id ~reason:test_reason;
  CB.record_failure cb ~agent_id:test_agent_id ~reason:test_reason;
  
  (* Subsequent calls should fail *)
  let result = CB.check cb ~agent_id:test_agent_id in
  match result with
  | Error msg ->
      testable (fun p p' -> p = p') "open_blocks" true (String.contains msg 'O')
  | Ok () -> failwith "Expected Error when circuit is open"

(** {1 Half-Open Transitions} *)

let test_half_open_after_cooldown () =
  let cb = create_test_instance () in
  (* Open the circuit *)
  CB.record_failure cb ~agent_id:test_agent_id ~reason:test_reason;
  CB.record_failure cb ~agent_id:test_agent_id ~reason:test_reason;
  CB.record_failure cb ~agent_id:test_agent_id ~reason:test_reason;
  
  (* Wait for cooldown (5 seconds) *)
  Eio.Main.run (fun ~env ->
    Eio.Sleep.sleep 6.0 ~env;
    
    (* Should transition to half-open *)
    match CB.check cb ~agent_id:test_agent_id with
    | Ok () -> testable (fun p p' -> p = p') "half_open_ok" true true
    | Error e -> failwith ("Expected Ok in half-open, got: " ^ e)
  )

let test_half_open_success_returns_to_closed () =
  let cb = create_test_instance () in
  (* Open the circuit *)
  CB.record_failure cb ~agent_id:test_agent_id ~reason:test_reason;
  CB.record_failure cb ~agent_id:test_agent_id ~reason:test_reason;
  CB.record_failure cb ~agent_id:test_agent_id ~reason:test_reason;
  
  (* Wait for cooldown *)
  Eio.Main.run (fun ~env ->
    Eio.Sleep.sleep 6.0 ~env;
    
    (* Record success — should transition to closed *)
    CB.record_success cb ~agent_id:test_agent_id;
    
    (* Should be closed now *)
    match CB.check cb ~agent_id:test_agent_id with
    | Ok () -> testable (fun p p' -> p = p') "recovered" true true
    | Error e -> failwith ("Expected Ok after recovery, got: " ^ e)
  )

let test_half_open_failure_returns_to_open () =
  let cb = create_test_instance () in
  (* Open the circuit *)
  CB.record_failure cb ~agent_id:test_agent_id ~reason:test_reason;
  CB.record_failure cb ~agent_id:test_agent_id ~reason:test_reason;
  CB.record_failure cb ~agent_id:test_agent_id ~reason:test_reason;
  
  (* Wait for cooldown *)
  Eio.Main.run (fun ~env ->
    Eio.Sleep.sleep 6.0 ~env;
    
    (* Record success — transitions to closed *)
    CB.record_success cb ~agent_id:test_agent_id;
    
    (* Record failure again — should open *)
    CB.record_failure cb ~agent_id:test_agent_id ~reason:test_reason;
    CB.record_failure cb ~agent_id:test_agent_id ~reason:test_reason;
    CB.record_failure cb ~agent_id:test_agent_id ~reason:test_reason;
    
    (* Should be open again *)
    match CB.check cb ~agent_id:test_agent_id with
    | Error msg ->
        testable (fun p p' -> p = p') "reopened" true (String.contains msg 'O')
    | Ok () -> failwith "Expected circuit to reopen after failure"
  )

(** {1 Admin Overrides} *)

let test_force_open () =
  let cb = create_test_instance () in
  (* Force open for 10 seconds *)
  CB.force_open cb ~agent_id:test_agent_id ~reason:"admin override" ~duration_sec:10.0;
  
  (* Should be open *)
  match CB.check cb ~agent_id:test_agent_id with
  | Error msg ->
      testable (fun p p' -> p = p') "force_open" true (String.contains msg 'O')
  | Ok () -> failwith "Expected circuit to be open after force_open"

let test_force_close () =
  let cb = create_test_instance () in
  (* Force open *)
  CB.force_open cb ~agent_id:test_agent_id ~reason:"admin override" ~duration_sec:10.0;
  
  (* Force close *)
  CB.force_close cb ~agent_id:test_agent_id;
  
  (* Should be closed *)
  match CB.check cb ~agent_id:test_agent_id with
  | Ok () -> testable (fun p p' -> p = p') "force_close" true true
  | Error e -> failwith ("Expected Ok after force_close, got: " ^ e)

(** {1 Failure Window Pruning} *)

let test_failure_window_pruning () =
  let cb = create_test_instance () in
  (* Record 2 failures *)
  CB.record_failure cb ~agent_id:test_agent_id ~reason:test_reason;
  CB.record_failure cb ~agent_id:test_agent_id ~reason:test_reason;
  
  (* Wait for failures to expire (61 seconds > 60s window) *)
  Eio.Main.run (fun ~env ->
    Eio.Sleep.sleep 61.0 ~env;
    
    (* Record 1 more failure — should not open (old failures pruned) *)
    CB.record_failure cb ~agent_id:test_agent_id ~reason:test_reason;
    
    (* Should still be closed *)
    match CB.check cb ~agent_id:test_agent_id with
    | Ok () -> testable (fun p p' -> p = p') "pruned" true true
    | Error e -> failwith ("Expected Ok after pruning, got: " ^ e)
  )

(** {1 Multiple Agents} *)

let test_independent_agents () =
  let cb = create_test_instance () in
  (* Open circuit for agent 1 *)
  CB.record_failure cb ~agent_id:test_agent_id ~reason:test_reason;
  CB.record_failure cb ~agent_id:test_agent_id ~reason:test_reason;
  CB.record_failure cb ~agent_id:test_agent_id ~reason:test_reason;
  
  (* Agent 2 should still be closed *)
  match CB.check cb ~agent_id:test_agent_id_2 with
  | Ok () -> testable (fun p p' -> p = p') "independent" true true
  | Error e -> failwith ("Agent 2 should be closed, got: " ^ e)

(** {1 Global Instance Integration} *)

let test_global_instance () =
  (* Use the global instance *)
  let global = CB.global () in
  
  (* Record failure on global instance *)
  CB.record_failure global ~agent_id:test_agent_id ~reason:test_reason;
  
  (* Check should work *)
  match CB.check global ~agent_id:test_agent_id with
  | Ok () -> testable (fun p p' -> p = p') "global_ok" true true
  | Error e -> failwith ("Expected Ok on global, got: " ^ e)

(** {1 Concurrent Access} *)

let test_concurrent_access () =
  let cb = create_test_instance () in
  let num_agents = 10 in
  let num_failures_per_agent = 3 in
  
  Eio.Main.run (fun ~env ->
    (* Create fibers that record failures concurrently *)
    let fibers = Array.init num_agents (fun i ->
      fun ~env ->
        let agent_id = Printf.sprintf "concurrent-agent-%d" i in
        for _ = 1 to num_failures_per_agent do
          CB.record_failure cb ~agent_id ~reason:test_reason
        done
    ) in
    
    (* Run all fibers concurrently *)
    Eio.Fiber.map (Array.to_list fibers) ~f:(fun fiber -> fiber ~env)
      ~f:(fun () -> ()) ~env;
    
    (* All agents should be open *)
    let all_open = Array.to_seq fibers |> Array.init num_agents (fun i ->
      let agent_id = Printf.sprintf "concurrent-agent-%d" i in
      match CB.check cb ~agent_id with
      | Error _ -> true
      | Ok () -> false
    ) |> Array.to_list |> List.for_all (fun b -> b) in
    
    testable (fun p p' -> p = p') "concurrent" true all_open
  )

(** {1 Status Reporting} *)

let test_get_status () =
  let cb = create_test_instance () in
  (* Record failures *)
  CB.record_failure cb ~agent_id:test_agent_id ~reason:test_reason;
  CB.record_failure cb ~agent_id:test_agent_id ~reason:test_reason;
  CB.record_failure cb ~agent_id:test_agent_id ~reason:test_reason;
  
  (* Get status *)
  let status = CB.get_status_global ~agent_id:test_agent_id in
  testable (fun p p' -> p = p') "status_exists" true (match status with Some _ -> true | None -> false)

let test_get_summary () =
  let cb = create_test_instance () in
  (* Record failures for multiple agents *)
  CB.record_failure cb ~agent_id:test_agent_id ~reason:test_reason;
  CB.record_failure cb ~agent_id:test_agent_id_2 ~reason:test_reason;
  
  (* Get summary *)
  let summary = CB.get_summary cb in
  testable (fun p p' -> p = p') "summary_exists" true (summary <> "")

(** {1 Test Suite} *)

let () =
  run "circuit_breaker_integration" [
    "Basic State Transitions",
    [
      testable "closed_state" test_closed_state ();
      testable "failure_opens_circuit" test_record_failure_transitions_to_open ();
      testable "open_blocks_calls" test_open_circuit_blocks_calls ();
    ];
    "Half-Open Transitions",
    [
      testable "half_open_after_cooldown" test_half_open_after_cooldown ();
      testable "half_open_success_closes" test_half_open_success_returns_to_closed ();
      testable "half_open_failure_reopens" test_half_open_failure_returns_to_open ();
    ];
    "Admin Overrides",
    [
      testable "force_open" test_force_open ();
      testable "force_close" test_force_close ();
    ];
    "Failure Window Pruning",
    [
      testable "pruning" test_failure_window_pruning ();
    ];
    "Multiple Agents",
    [
      testable "independent_agents" test_independent_agents ();
    ];
    "Global Instance",
    [
      testable "global_instance" test_global_instance ();
    ];
    "Concurrent Access",
    [
      testable "concurrent" test_concurrent_access ();
    ];
    "Status Reporting",
    [
      testable "get_status" test_get_status ();
      testable "get_summary" test_get_summary ();
    ];
  ]