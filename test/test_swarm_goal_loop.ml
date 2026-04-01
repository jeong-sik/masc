(** test_swarm_goal_loop.ml — Unit tests for Swarm_goal_loop module.

    Tests cover:
    - Goal expression parsing (all 6 operators + error cases)
    - Goal evaluation logic
    - Aggregate strategy evaluation (All/Any/Average)

    @since 2.80.0 *)

open Masc_mcp

(* ================================================================ *)
(* Goal expression parsing                                          *)
(* ================================================================ *)

let test_parse_gte () =
  match Swarm_goal_loop.parse_goal_expr "metric >= 0.95" with
  | Some (op, target) ->
      Alcotest.(check (float 0.001)) "target" 0.95 target;
      Alcotest.(check bool) "gte passes" true
        (Swarm_goal_loop.evaluate_goal op target 0.96);
      Alcotest.(check bool) "gte exact" true
        (Swarm_goal_loop.evaluate_goal op target 0.95);
      Alcotest.(check bool) "gte fails" false
        (Swarm_goal_loop.evaluate_goal op target 0.94)
  | None -> Alcotest.fail "failed to parse >= expr"

let test_parse_lte () =
  match Swarm_goal_loop.parse_goal_expr "errors <= 0" with
  | Some (op, target) ->
      Alcotest.(check (float 0.001)) "target" 0.0 target;
      Alcotest.(check bool) "lte passes" true
        (Swarm_goal_loop.evaluate_goal op target 0.0);
      Alcotest.(check bool) "lte fails" false
        (Swarm_goal_loop.evaluate_goal op target 1.0)
  | None -> Alcotest.fail "failed to parse <= expr"

let test_parse_gt () =
  match Swarm_goal_loop.parse_goal_expr "score > 80" with
  | Some (op, target) ->
      Alcotest.(check (float 0.001)) "target" 80.0 target;
      Alcotest.(check bool) "gt passes" true
        (Swarm_goal_loop.evaluate_goal op target 81.0);
      Alcotest.(check bool) "gt exact fails" false
        (Swarm_goal_loop.evaluate_goal op target 80.0)
  | None -> Alcotest.fail "failed to parse > expr"

let test_parse_lt () =
  match Swarm_goal_loop.parse_goal_expr "latency < 100" with
  | Some (op, target) ->
      Alcotest.(check (float 0.001)) "target" 100.0 target;
      Alcotest.(check bool) "lt passes" true
        (Swarm_goal_loop.evaluate_goal op target 99.0);
      Alcotest.(check bool) "lt exact fails" false
        (Swarm_goal_loop.evaluate_goal op target 100.0)
  | None -> Alcotest.fail "failed to parse < expr"

let test_parse_eq () =
  match Swarm_goal_loop.parse_goal_expr "count == 42" with
  | Some (op, target) ->
      Alcotest.(check (float 0.001)) "target" 42.0 target;
      Alcotest.(check bool) "eq passes" true
        (Swarm_goal_loop.evaluate_goal op target 42.0);
      Alcotest.(check bool) "eq fails" false
        (Swarm_goal_loop.evaluate_goal op target 41.0)
  | None -> Alcotest.fail "failed to parse == expr"

let test_parse_neq () =
  match Swarm_goal_loop.parse_goal_expr "errors != 0" with
  | Some (op, target) ->
      Alcotest.(check (float 0.001)) "target" 0.0 target;
      Alcotest.(check bool) "neq passes" true
        (Swarm_goal_loop.evaluate_goal op target 1.0);
      Alcotest.(check bool) "neq fails" false
        (Swarm_goal_loop.evaluate_goal op target 0.0)
  | None -> Alcotest.fail "failed to parse != expr"

let test_parse_invalid () =
  Alcotest.(check bool) "empty" true
    (Option.is_none (Swarm_goal_loop.parse_goal_expr ""));
  Alcotest.(check bool) "no operator" true
    (Option.is_none (Swarm_goal_loop.parse_goal_expr "just a string"));
  Alcotest.(check bool) "bad number" true
    (Option.is_none (Swarm_goal_loop.parse_goal_expr "metric >= abc"))

(* ================================================================ *)
(* Aggregate evaluation                                             *)
(* ================================================================ *)

let test_aggregate_all () =
  let metrics = [(0.96, true); (0.97, true); (0.95, true)] in
  let (avg, met) = Swarm_goal_loop.evaluate_aggregate
      Swarm_goal_loop.All ~aggregate_goal_expr:"metric >= 0.95" metrics in
  Alcotest.(check bool) "all met" true met;
  Alcotest.(check bool) "avg > 0.95" true (avg >= 0.95);

  let metrics2 = [(0.96, true); (0.93, false); (0.95, true)] in
  let (_avg2, met2) = Swarm_goal_loop.evaluate_aggregate
      Swarm_goal_loop.All ~aggregate_goal_expr:"metric >= 0.95" metrics2 in
  Alcotest.(check bool) "not all met" false met2

let test_aggregate_any () =
  let metrics = [(0.93, false); (0.94, false); (0.96, true)] in
  let (_avg, met) = Swarm_goal_loop.evaluate_aggregate
      Swarm_goal_loop.Any ~aggregate_goal_expr:"metric >= 0.95" metrics in
  Alcotest.(check bool) "any met" true met;

  let metrics2 = [(0.93, false); (0.94, false)] in
  let (_avg2, met2) = Swarm_goal_loop.evaluate_aggregate
      Swarm_goal_loop.Any ~aggregate_goal_expr:"metric >= 0.95" metrics2 in
  Alcotest.(check bool) "none met" false met2

let test_aggregate_average () =
  let metrics = [(0.90, false); (1.0, true); (0.96, true)] in
  let (avg, met) = Swarm_goal_loop.evaluate_aggregate
      Swarm_goal_loop.Average ~aggregate_goal_expr:"metric >= 0.95" metrics in
  Alcotest.(check bool) "average meets" true met;
  Alcotest.(check bool) "avg ~0.953" true (avg > 0.95);

  let metrics2 = [(0.90, false); (0.91, false); (0.92, false)] in
  let (_avg2, met2) = Swarm_goal_loop.evaluate_aggregate
      Swarm_goal_loop.Average ~aggregate_goal_expr:"metric >= 0.95" metrics2 in
  Alcotest.(check bool) "average fails" false met2

(* ================================================================ *)
(* Cancel token                                                     *)
(* ================================================================ *)

let test_cancel_token_default () =
  let ct = Swarm_goal_loop.make_cancel_token () in
  Alcotest.(check bool) "default not cancelled" false (Atomic.get ct.cancelled)

let test_cancel_token_set () =
  let ct = Swarm_goal_loop.make_cancel_token () in
  Atomic.set ct.cancelled true;
  Alcotest.(check bool) "cancelled after set" true (Atomic.get ct.cancelled)

(* ================================================================ *)
(* Runner                                                           *)
(* ================================================================ *)

let () =
  Alcotest.run "Swarm_goal_loop"
    [
      ( "goal_parsing",
        [
          Alcotest.test_case "parse >=" `Quick test_parse_gte;
          Alcotest.test_case "parse <=" `Quick test_parse_lte;
          Alcotest.test_case "parse >" `Quick test_parse_gt;
          Alcotest.test_case "parse <" `Quick test_parse_lt;
          Alcotest.test_case "parse ==" `Quick test_parse_eq;
          Alcotest.test_case "parse !=" `Quick test_parse_neq;
          Alcotest.test_case "parse invalid" `Quick test_parse_invalid;
        ] );
      ( "aggregate",
        [
          Alcotest.test_case "strategy All" `Quick test_aggregate_all;
          Alcotest.test_case "strategy Any" `Quick test_aggregate_any;
          Alcotest.test_case "strategy Average" `Quick test_aggregate_average;
        ] );
      ( "cancel_token",
        [
          Alcotest.test_case "default not cancelled" `Quick test_cancel_token_default;
          Alcotest.test_case "set cancellation" `Quick test_cancel_token_set;
        ] );
    ]
