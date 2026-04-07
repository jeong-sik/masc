(** test_keeper_trace_validate — unit tests for JSONL trace validator. *)

open Alcotest
module TV = Masc_mcp.Keeper_trace_validate
module IC = Masc_mcp.Keeper_invariant_check

(* ── Helpers ───────────────────────────────────────────── *)

let make_step_json ~seq ~phase ~fiber_alive ~heartbeat_healthy ~turn_healthy
    ~stop_requested ~drain_complete ~restart_budget_remaining
    ~restart_count =
  Printf.sprintf
    {|{"seq":%d,"ts_unix":1000.0,"event":"test","prev_phase":"running","new_phase":"%s","conditions_after":{"fiber_alive":%b,"heartbeat_healthy":%b,"turn_healthy":%b,"context_within_budget":true,"context_handoff_needed":false,"compaction_active":false,"handoff_active":false,"operator_paused":false,"stop_requested":%b,"restart_budget_remaining":%b,"backoff_elapsed":false,"guardrail_triggered":false,"drain_complete":%b},"restart_count":%d}|}
    seq phase fiber_alive heartbeat_healthy turn_healthy
    stop_requested restart_budget_remaining drain_complete restart_count

let running_step seq =
  make_step_json ~seq ~phase:"running" ~fiber_alive:true
    ~heartbeat_healthy:true ~turn_healthy:true
    ~stop_requested:false ~drain_complete:false
    ~restart_budget_remaining:true ~restart_count:0

let failing_step seq =
  make_step_json ~seq ~phase:"failing" ~fiber_alive:true
    ~heartbeat_healthy:false ~turn_healthy:true
    ~stop_requested:false ~drain_complete:false
    ~restart_budget_remaining:true ~restart_count:0

let stopped_step seq =
  make_step_json ~seq ~phase:"stopped" ~fiber_alive:true
    ~heartbeat_healthy:true ~turn_healthy:true
    ~stop_requested:true ~drain_complete:true
    ~restart_budget_remaining:true ~restart_count:0

(* ── Test: valid trace ─────────────────────────────────── *)

let test_valid_trace () =
  let trace = String.concat "\n" [
    running_step 1;
    failing_step 2;
    running_step 3;
    stopped_step 4;
  ] in
  let tmp = Filename.temp_file "trace_valid" ".jsonl" in
  let oc = open_out tmp in
  output_string oc trace;
  close_out oc;
  (match TV.validate_trace_file tmp with
   | Ok violations ->
     check int "no violations" 0 (List.length violations)
   | Error msg ->
     fail (Printf.sprintf "unexpected error: %s" msg));
  Sys.remove tmp

(* ── Test: DeadIsForever violation ─────────────────────── *)

let test_dead_is_forever_violation () =
  let dead_step = make_step_json ~seq:2 ~phase:"dead"
      ~fiber_alive:false ~heartbeat_healthy:true ~turn_healthy:true
      ~stop_requested:false ~drain_complete:false
      ~restart_budget_remaining:false ~restart_count:0 in
  let trace = String.concat "\n" [
    dead_step;
    running_step 3;  (* violation: Dead -> Running *)
  ] in
  let tmp = Filename.temp_file "trace_dead" ".jsonl" in
  let oc = open_out tmp in
  output_string oc trace;
  close_out oc;
  (match TV.validate_trace_file tmp with
   | Ok violations ->
     check bool "has violations" true (List.length violations > 0);
     let has_dead_forever = List.exists
       (fun (v : TV.located_violation) -> v.violation.IC.property = "DeadIsForever")
       violations in
     check bool "DeadIsForever violated" true has_dead_forever
   | Error msg ->
     fail (Printf.sprintf "unexpected error: %s" msg));
  Sys.remove tmp

(* ── Test: RestartCountMonotonic violation ─────────────── *)

let test_restart_count_monotonic_violation () =
  let step1 = make_step_json ~seq:1 ~phase:"running"
      ~fiber_alive:true ~heartbeat_healthy:true ~turn_healthy:true
      ~stop_requested:false ~drain_complete:false
      ~restart_budget_remaining:true ~restart_count:3 in
  let step2 = make_step_json ~seq:2 ~phase:"running"
      ~fiber_alive:true ~heartbeat_healthy:true ~turn_healthy:true
      ~stop_requested:false ~drain_complete:false
      ~restart_budget_remaining:true ~restart_count:1 in
  let trace = String.concat "\n" [ step1; step2 ] in
  let tmp = Filename.temp_file "trace_restart" ".jsonl" in
  let oc = open_out tmp in
  output_string oc trace;
  close_out oc;
  (match TV.validate_trace_file tmp with
   | Ok violations ->
     let has_monotonic = List.exists
       (fun (v : TV.located_violation) -> v.violation.IC.property = "RestartCountMonotonic")
       violations in
     check bool "RestartCountMonotonic violated" true has_monotonic
   | Error msg ->
     fail (Printf.sprintf "unexpected error: %s" msg));
  Sys.remove tmp

(* ── Test: RunningRequiresFiber violation ──────────────── *)

let test_running_requires_fiber_violation () =
  let bad_step = make_step_json ~seq:2 ~phase:"running"
      ~fiber_alive:false ~heartbeat_healthy:true ~turn_healthy:true
      ~stop_requested:false ~drain_complete:false
      ~restart_budget_remaining:true ~restart_count:0 in
  let trace = String.concat "\n" [
    running_step 1;
    bad_step;
  ] in
  let tmp = Filename.temp_file "trace_fiber" ".jsonl" in
  let oc = open_out tmp in
  output_string oc trace;
  close_out oc;
  (match TV.validate_trace_file tmp with
   | Ok violations ->
     let has_fiber = List.exists
       (fun (v : TV.located_violation) -> v.violation.IC.property = "RunningRequiresFiber")
       violations in
     check bool "RunningRequiresFiber violated" true has_fiber
   | Error msg ->
     fail (Printf.sprintf "unexpected error: %s" msg));
  Sys.remove tmp

(* ── Test: parse_step ──────────────────────────────────── *)

let test_parse_step_valid () =
  match TV.parse_step (running_step 42) with
  | Ok step ->
    check int "seq" 42 step.seq;
    check bool "fiber_alive" true step.conditions.fiber_alive
  | Error msg ->
    fail (Printf.sprintf "parse error: %s" msg)

let test_parse_step_invalid () =
  match TV.parse_step "not json" with
  | Ok _ -> fail "expected error"
  | Error _ -> ()

(* ── Runner ────────────────────────────────────────────── *)

let () =
  run "keeper_trace_validate" [
    "valid", [
      test_case "valid trace passes" `Quick test_valid_trace;
      test_case "parse valid step" `Quick test_parse_step_valid;
      test_case "parse invalid step" `Quick test_parse_step_invalid;
    ];
    "violations", [
      test_case "DeadIsForever" `Quick test_dead_is_forever_violation;
      test_case "RestartCountMonotonic" `Quick test_restart_count_monotonic_violation;
      test_case "RunningRequiresFiber" `Quick test_running_requires_fiber_violation;
    ];
  ]
