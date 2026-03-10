(** test_mdal_swarm.ml — Unit tests for Mdal_swarm module.

    Tests cover:
    - Worker spec serialization round-trip
    - Swarm config serialization round-trip
    - Aggregate evaluation (All/Any/Average)
    - Swarm status variants
    - Result JSON output structure

    @since 2.80.0 *)

open Masc_mcp

(* ================================================================ *)
(* Helpers                                                          *)
(* ================================================================ *)

let dummy_worker_spec ?(id = "w1") ?(label = "Component A")
    ?(metric_fn = "echo 0.9") ?(goal = "metric >= 0.95")
    ?(agent = "default") ?(max_iter = 5) () : Mdal_swarm.worker_spec =
  { worker_id = id; label; metric_fn; goal_expr = goal;
    agent; max_iterations = max_iter }

let dummy_worker_result ?(id = "w1") ?(label = "Component A")
    ?(metric = 0.96) ?(iterations = 3) ?(goal_met = true)
    ?(error = None) () : Mdal_swarm.worker_result =
  { worker_id = id; label; final_metric = metric;
    iterations_used = iterations; goal_met; error }

(* ================================================================ *)
(* Serialization tests                                              *)
(* ================================================================ *)

let test_worker_spec_roundtrip () =
  let spec = dummy_worker_spec () in
  let json = Mdal_swarm.worker_spec_to_yojson spec in
  match Mdal_swarm.worker_spec_of_yojson json with
  | Ok restored ->
      Alcotest.(check string) "worker_id" spec.worker_id restored.worker_id;
      Alcotest.(check string) "label" spec.label restored.label;
      Alcotest.(check string) "metric_fn" spec.metric_fn restored.metric_fn;
      Alcotest.(check int) "max_iterations" spec.max_iterations restored.max_iterations
  | Error e -> Alcotest.fail (Printf.sprintf "worker_spec deser failed: %s" e)

let test_swarm_config_roundtrip () =
  let config : Mdal_swarm.swarm_config = {
    swarm_id = "swarm-test";
    title = "Test Swarm";
    workers = [dummy_worker_spec ~id:"w1" (); dummy_worker_spec ~id:"w2" ()];
    aggregate_strategy = Average;
    aggregate_goal_expr = "metric >= 0.95";
    max_wall_time_sec = Some 60.0;
  } in
  let json = Mdal_swarm.swarm_config_to_yojson config in
  match Mdal_swarm.swarm_config_of_yojson json with
  | Ok restored ->
      Alcotest.(check string) "swarm_id" config.swarm_id restored.swarm_id;
      Alcotest.(check string) "title" config.title restored.title;
      Alcotest.(check int) "worker count" 2 (List.length restored.workers)
  | Error e -> Alcotest.fail (Printf.sprintf "swarm_config deser failed: %s" e)

let test_worker_result_roundtrip () =
  let result = dummy_worker_result () in
  let json = Mdal_swarm.worker_result_to_yojson result in
  match Mdal_swarm.worker_result_of_yojson json with
  | Ok restored ->
      Alcotest.(check string) "worker_id" result.worker_id restored.worker_id;
      Alcotest.(check (float 0.001)) "metric" result.final_metric restored.final_metric;
      Alcotest.(check bool) "goal_met" true restored.goal_met
  | Error e -> Alcotest.fail (Printf.sprintf "worker_result deser failed: %s" e)

(* ================================================================ *)
(* Aggregate evaluation                                             *)
(* ================================================================ *)

let test_evaluate_aggregate_all () =
  let metrics = [(0.96, true); (0.97, true)] in
  let (avg, met) = Mdal_swarm.evaluate_aggregate All
      ~aggregate_goal_expr:"metric >= 0.95" metrics in
  Alcotest.(check bool) "all met" true met;
  Alcotest.(check bool) "avg > 0.96" true (avg > 0.96);

  let metrics2 = [(0.96, true); (0.93, false)] in
  let (_avg, met2) = Mdal_swarm.evaluate_aggregate All
      ~aggregate_goal_expr:"metric >= 0.95" metrics2 in
  Alcotest.(check bool) "not all met" false met2

let test_evaluate_aggregate_any () =
  let metrics = [(0.93, false); (0.96, true)] in
  let (_avg, met) = Mdal_swarm.evaluate_aggregate Any
      ~aggregate_goal_expr:"metric >= 0.95" metrics in
  Alcotest.(check bool) "any met" true met

let test_evaluate_aggregate_average () =
  let metrics = [(0.93, false); (0.97, true)] in
  let (avg, met) = Mdal_swarm.evaluate_aggregate Average
      ~aggregate_goal_expr:"metric >= 0.95" metrics in
  Alcotest.(check (float 0.001)) "avg" 0.95 avg;
  Alcotest.(check bool) "average meets" true met

(* ================================================================ *)
(* Status variants                                                  *)
(* ================================================================ *)

let test_status_serialization () =
  let statuses = [
    Mdal_swarm.Running; Completed; PartialSuccess; Failed; TimedOut
  ] in
  List.iter (fun status ->
    let json = Mdal_swarm.swarm_status_to_yojson status in
    match Mdal_swarm.swarm_status_of_yojson json with
    | Ok restored ->
        Alcotest.(check bool) "status round-trip" true
          (Mdal_swarm.swarm_status_to_yojson restored = json)
    | Error e ->
        Alcotest.fail (Printf.sprintf "status deser failed: %s" e)
  ) statuses

(* ================================================================ *)
(* Result JSON                                                      *)
(* ================================================================ *)

let test_result_to_json () =
  let result : Mdal_swarm.swarm_result = {
    swarm_id = "swarm-test";
    title = "Test";
    status = Completed;
    aggregate_metric = 0.96;
    aggregate_goal_met = true;
    started_at = "2026-01-01T00:00:00Z";
    completed_at = "2026-01-01T00:01:00Z";
    worker_results = [dummy_worker_result ()];
    total_iterations = 3;
  } in
  let json = Mdal_swarm.result_to_json result in
  let open Yojson.Safe.Util in
  Alcotest.(check string) "swarm_id"
    "swarm-test" (json |> member "swarm_id" |> to_string);
  Alcotest.(check bool) "aggregate_goal_met"
    true (json |> member "aggregate_goal_met" |> to_bool);
  Alcotest.(check int) "total_iterations"
    3 (json |> member "total_iterations" |> to_int);
  let workers = json |> member "worker_results" |> to_list in
  Alcotest.(check int) "worker count" 1 (List.length workers)

(* ================================================================ *)
(* Runner edge cases                                                *)
(* ================================================================ *)

let test_run_empty_workers_fails () =
  Eio_main.run @@ fun env ->
  let config : Mdal_swarm.swarm_config = {
    swarm_id = "swarm-empty";
    title = "Empty Swarm";
    workers = [];
    aggregate_strategy = All;
    aggregate_goal_expr = "metric >= 0.95";
    max_wall_time_sec = Some 1.0;
  } in
  let result = Mdal_swarm.run ~clock:(Eio.Stdenv.clock env) config in
  Alcotest.(check bool) "goal not met" false result.aggregate_goal_met;
  Alcotest.(check int) "no workers" 0 (List.length result.worker_results);
  match result.status with
  | Mdal_swarm.Failed -> ()
  | _ -> Alcotest.fail "expected failed status for empty worker set"

let test_run_timeout_marks_timed_out () =
  Eio_main.run @@ fun env ->
  Process_eio.init
    ~cwd_default:(Eio.Stdenv.cwd env)
    ~proc_mgr:(Eio.Stdenv.process_mgr env)
    ~clock:(Eio.Stdenv.clock env);
  let config : Mdal_swarm.swarm_config = {
    swarm_id = "swarm-timeout";
    title = "Timeout Swarm";
    workers = [
      dummy_worker_spec
        ~metric_fn:"python3 -c 'import time; time.sleep(0.2); print(1.0)'"
        ~goal:"metric >= 1.0"
        ~max_iter:1
        ()
    ];
    aggregate_strategy = All;
    aggregate_goal_expr = "metric >= 1.0";
    max_wall_time_sec = Some 0.05;
  } in
  let result = Mdal_swarm.run ~clock:(Eio.Stdenv.clock env) config in
  match result.status with
  | Mdal_swarm.TimedOut -> ()
  | _ -> Alcotest.fail "expected timeout status"

(* ================================================================ *)
(* Runner                                                           *)
(* ================================================================ *)

let () =
  Alcotest.run "Mdal_swarm"
    [
      ( "serialization",
        [
          Alcotest.test_case "worker spec round-trip" `Quick test_worker_spec_roundtrip;
          Alcotest.test_case "swarm config round-trip" `Quick test_swarm_config_roundtrip;
          Alcotest.test_case "worker result round-trip" `Quick test_worker_result_roundtrip;
          Alcotest.test_case "status variants" `Quick test_status_serialization;
          Alcotest.test_case "result to json" `Quick test_result_to_json;
        ] );
      ( "aggregate",
        [
          Alcotest.test_case "strategy All" `Quick test_evaluate_aggregate_all;
          Alcotest.test_case "strategy Any" `Quick test_evaluate_aggregate_any;
          Alcotest.test_case "strategy Average" `Quick test_evaluate_aggregate_average;
        ] );
      ( "runner_edge_cases",
        [
          Alcotest.test_case "empty workers fail" `Quick test_run_empty_workers_fails;
          Alcotest.test_case "timeout marks timed_out" `Quick test_run_timeout_marks_timed_out;
        ] );
    ]
