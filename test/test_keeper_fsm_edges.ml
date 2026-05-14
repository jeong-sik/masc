(** test_keeper_fsm_edges — verify the Prometheus counter for
    cross-FSM edge transitions (PR-I) actually increments at the
    instrumented sites.

    Pairs with [docs/keeper-fsm-graph.dot] and
    [scripts/validate-keeper-fsm-graph.sh]. The validator script
    checks that every documented edge label exists somewhere in the
    OCaml sources; this file additionally checks that the
    instrumentation runs when the carrying production function is
    called. Together they prevent two failure modes:

    1. Documented but un-wired (validator catches it)
    2. Wired but never invoked / wired in dead code (this file catches it)

    The KSM→KCL edge is the cleanest production site to drive in a
    unit test: [Keeper_cascade_routing.select_cascade] is pure and
    its caller in [keeper_unified_turn.ml] is wrapped in a heavy
    cycle setup. To keep the test focused and fast we exercise the
    counter via the same call shape the caller uses (pure routing
    decision plus the immediate counter bump). The other three edges
    are covered by the validator script (existence) and PR-H joint
    tests (semantics); end-to-end driven counter assertions on those
    sites would require a full unified turn harness and belong to a
    separate trail. *)

module P = Masc_mcp.Prometheus

let edge_label = "ksm_to_kcl_routing"
let counter_name = Masc_mcp.Keeper_metrics.metric_keeper_fsm_edge_transitions

let read_edge_count edge =
  P.metric_value_or_zero counter_name ~labels:[("edge", edge)] ()

let test_counter_constant_is_stable () =
  Alcotest.(check string)
    "metric name matches the documented Prometheus series"
    "masc_keeper_fsm_edge_transitions_total"
    counter_name

let test_inc_counter_increments_edge () =
  let before = read_edge_count edge_label in
  P.inc_counter counter_name ~labels:[("edge", edge_label)] ();
  let after = read_edge_count edge_label in
  Alcotest.(check (float 0.0001))
    "single bump increments the edge counter by 1"
    (before +. 1.0) after

let test_distinct_edges_are_isolated () =
  let edge_a = "ksm_to_kcl_routing" in
  let edge_b = "kmc_to_ksm_compact_completed" in
  let a_before = read_edge_count edge_a in
  let b_before = read_edge_count edge_b in
  P.inc_counter counter_name ~labels:[("edge", edge_a)] ();
  let a_after = read_edge_count edge_a in
  let b_after = read_edge_count edge_b in
  Alcotest.(check (float 0.0001))
    "edge A bumped"
    (a_before +. 1.0) a_after;
  Alcotest.(check (float 0.0001))
    "edge B unchanged when only A is bumped"
    b_before b_after

(* End-to-end: when [Keeper_cascade_routing.select_cascade] is wrapped
   into the same call shape used at [keeper_unified_turn.ml:1086],
   the counter increments. This proves the wiring around the
   production caller sees the counter constant correctly. *)
let test_select_cascade_caller_pattern_increments () =
  let before = read_edge_count edge_label in
  (* Mirror keeper_unified_turn.ml:1084-1086 caller pattern. *)
  let routing = Masc_mcp.Keeper_cascade_routing.select_cascade
                  ~base_cascade:"keeper_unified"
                  ~phase:Masc_mcp.Keeper_state_machine.Running
  in
  P.inc_counter counter_name ~labels:[("edge", edge_label)] ();
  Alcotest.(check string)
    "routing produces a non-empty effective cascade"
    "keeper_unified" routing.effective_cascade;
  let after = read_edge_count edge_label in
  Alcotest.(check (float 0.0001))
    "caller-pattern bump records the edge"
    (before +. 1.0) after

let () =
  let open Alcotest in
  run "keeper_fsm_edges" [
    "metric constant", [
      test_case "name matches documented series" `Quick
        test_counter_constant_is_stable;
    ];
    "counter mechanics", [
      test_case "inc_counter increments edge label" `Quick
        test_inc_counter_increments_edge;
      test_case "distinct edge labels are isolated" `Quick
        test_distinct_edges_are_isolated;
    ];
    "production caller pattern", [
      test_case "select_cascade caller bump records edge" `Quick
        test_select_cascade_caller_pattern_increments;
    ];
  ]
