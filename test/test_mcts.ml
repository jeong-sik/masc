(** Tests for Mcts_tree — UCB1 tree search for speculative execution.

    Covers: construction, expansion, UCB1 selection, simulation recording,
    backpropagation, best-path extraction, pruning, and serialization.

    @since 2.80.0 *)

open Masc_mcp.Mcts_tree

(* ================================================================ *)
(* Test Helpers                                                     *)
(* ================================================================ *)

let pass_count = ref 0
let fail_count = ref 0

let check label cond =
  if cond then begin
    incr pass_count;
    Printf.printf "  ✓ %s\n%!" label
  end else begin
    incr fail_count;
    Printf.printf "  ✗ %s\n%!" label
  end

let run_test name f =
  Printf.printf "\n─── %s ───\n%!" name;
  (try f () with exn ->
    incr fail_count;
    Printf.printf "  ✗ EXCEPTION: %s\n%!" (Printexc.to_string exn))

let make_sim ?(output = "test output") ?(latency = 10.0)
    ?(model = "test-model") verdict =
  { output; verdict; latency_ms = latency; model_used = model }

(* ================================================================ *)
(* Tests: Construction                                              *)
(* ================================================================ *)

let test_create () =
  let t = create ~root_label:"root task" () in
  check "root label" (t.root.label = "root task");
  check "node_count = 1" (t.node_count = 1);
  check "exploration_constant = sqrt(2)" (abs_float (t.exploration_constant -. sqrt 2.0) < 0.001);
  check "root has no children" (t.root.children = []);
  check "root visit_count = 0" (t.root.visit_count = 0);
  check "root parent_id = None" (t.root.parent_id = None);
  check "metrics zeroed" (t.total_simulations = 0 && t.total_selections = 0)

let test_create_custom_c () =
  let t = create ~exploration_constant:1.0 ~root_label:"custom" () in
  check "custom C = 1.0" (abs_float (t.exploration_constant -. 1.0) < 0.001)

(* ================================================================ *)
(* Tests: Expansion                                                 *)
(* ================================================================ *)

let test_expand () =
  let t = create ~root_label:"task" () in
  match expand t t.root.id ~labels:["approach A"; "approach B"; "approach C"] with
  | Error msg -> failwith msg
  | Ok children ->
    check "3 children created" (List.length children = 3);
    check "node_count = 4" (t.node_count = 4);
    check "root has 3 children" (List.length t.root.children = 3);
    check "children have parent_id" (
      List.for_all (fun c -> c.parent_id = Some t.root.id) children);
    check "total_expansions = 1" (t.total_expansions = 1)

let test_expand_already_expanded () =
  let t = create ~root_label:"task" () in
  let _ = expand t t.root.id ~labels:["A"; "B"] in
  match expand t t.root.id ~labels:["C"] with
  | Error msg -> check "double expand rejected" (String.length msg > 0)
  | Ok _ -> check "should have failed" false

let test_expand_not_found () =
  let t = create ~root_label:"task" () in
  match expand t "nonexistent" ~labels:["A"] with
  | Error _ -> check "not found error" true
  | Ok _ -> check "should have failed" false

let test_add_child () =
  let t = create ~root_label:"task" () in
  let _ = expand t t.root.id ~labels:["A"] in
  match add_child t t.root.id ~label:"B (progressive)" with
  | Error msg -> failwith msg
  | Ok child ->
    check "child added" (child.label = "B (progressive)");
    check "root now has 2 children" (List.length t.root.children = 2);
    check "node_count = 3" (t.node_count = 3)

(* ================================================================ *)
(* Tests: UCB1 Selection                                            *)
(* ================================================================ *)

let test_ucb1_unvisited_first () =
  let t = create ~root_label:"task" () in
  let _ = expand t t.root.id ~labels:["A"; "B"; "C"] in
  (* All unvisited → UCB1 = infinity, first child selected *)
  match select_child t t.root with
  | None -> check "should have children" false
  | Some child ->
    check "unvisited child selected" (child.visit_count = 0);
    check "total_selections = 1" (t.total_selections = 1)

let test_ucb1_exploitation () =
  let t = create ~exploration_constant:0.0 ~root_label:"task" () in
  let _ = expand t t.root.id ~labels:["A"; "B"; "C"] in
  (* Give B higher reward *)
  let children = t.root.children in
  let b = List.nth children 1 in
  b.visit_count <- 10;
  b.total_reward <- 9.0;  (* avg = 0.9 *)
  let a = List.nth children 0 in
  a.visit_count <- 10;
  a.total_reward <- 3.0;  (* avg = 0.3 *)
  let c = List.nth children 2 in
  c.visit_count <- 10;
  c.total_reward <- 5.0;  (* avg = 0.5 *)
  t.root.visit_count <- 30;
  match select_child t t.root with
  | None -> check "should select" false
  | Some child ->
    check "B selected (highest avg)" (child.id = b.id)

let test_select_path () =
  let t = create ~root_label:"root" () in
  let _ = expand t t.root.id ~labels:["L1-A"; "L1-B"] in
  let path = select_path t in
  check "path has 2 nodes" (List.length path = 2);
  check "path starts at root" ((List.hd path).label = "root")

(* ================================================================ *)
(* Tests: Simulation Recording                                      *)
(* ================================================================ *)

let test_record_simulation () =
  let t = create ~root_label:"task" () in
  let _ = expand t t.root.id ~labels:["A"] in
  let a = List.hd t.root.children in
  let sim = make_sim Pass in
  match record_simulation t a.id sim with
  | Error msg -> failwith msg
  | Ok reward ->
    check "pass reward = 1.0" (abs_float (reward -. 1.0) < 0.001);
    check "simulation recorded" (Option.is_some a.last_simulation);
    check "total_simulations = 1" (t.total_simulations = 1)

let test_record_warn_fail () =
  let t = create ~root_label:"task" () in
  let _ = expand t t.root.id ~labels:["A"; "B"] in
  let a = List.hd t.root.children in
  let b = List.nth t.root.children 1 in
  let _ = record_simulation t a.id (make_sim Warn) in
  let _ = record_simulation t b.id (make_sim Fail) in
  check "warn reward" (reward_of_verdict Warn = 0.5);
  check "fail reward" (reward_of_verdict Fail = 0.0);
  check "total_simulations = 2" (t.total_simulations = 2)

let test_record_not_found () =
  let t = create ~root_label:"task" () in
  match record_simulation t "ghost" (make_sim Pass) with
  | Error _ -> check "not found error" true
  | Ok _ -> check "should fail" false

(* ================================================================ *)
(* Tests: Backpropagation                                           *)
(* ================================================================ *)

let test_backpropagate () =
  let t = create ~root_label:"task" () in
  let _ = expand t t.root.id ~labels:["A"] in
  let a = List.hd t.root.children in
  backpropagate t a.id 1.0;
  check "leaf visit_count = 1" (a.visit_count = 1);
  check "leaf total_reward = 1.0" (abs_float (a.total_reward -. 1.0) < 0.001);
  check "root visit_count = 1" (t.root.visit_count = 1);
  check "root total_reward = 1.0" (abs_float (t.root.total_reward -. 1.0) < 0.001);
  check "backpropagations = 2" (t.total_backpropagations = 2)

let test_backpropagate_two_levels () =
  let t = create ~root_label:"root" () in
  let _ = expand t t.root.id ~labels:["L1"] in
  let l1 = List.hd t.root.children in
  let _ = expand t l1.id ~labels:["L2-A"; "L2-B"] in
  let l2a = List.hd l1.children in
  backpropagate t l2a.id 0.5;
  check "L2-A visits = 1" (l2a.visit_count = 1);
  check "L1 visits = 1" (l1.visit_count = 1);
  check "root visits = 1" (t.root.visit_count = 1);
  check "all rewards = 0.5" (
    abs_float (l2a.total_reward -. 0.5) < 0.001
    && abs_float (l1.total_reward -. 0.5) < 0.001
    && abs_float (t.root.total_reward -. 0.5) < 0.001)

(* ================================================================ *)
(* Tests: Best Path                                                 *)
(* ================================================================ *)

let test_best_path () =
  let t = create ~root_label:"root" () in
  let _ = expand t t.root.id ~labels:["A"; "B"] in
  let a = List.hd t.root.children in
  let b = List.nth t.root.children 1 in
  (* A: avg 0.9, B: avg 0.3 *)
  a.visit_count <- 10; a.total_reward <- 9.0;
  b.visit_count <- 10; b.total_reward <- 3.0;
  let path = best_path t in
  check "path length = 2" (List.length path = 2);
  check "best path goes through A" ((List.nth path 1).id = a.id)

let test_best_child_empty () =
  let t = create ~root_label:"leaf" () in
  match best_child_by_reward t.root with
  | None -> check "no children = None" true
  | Some _ -> check "should be None" false

(* ================================================================ *)
(* Tests: Pruning                                                   *)
(* ================================================================ *)

let test_prune () =
  let t = create ~root_label:"root" () in
  let _ = expand t t.root.id ~labels:["good"; "bad"; "ok"] in
  let children = t.root.children in
  let good = List.nth children 0 in
  let bad = List.nth children 1 in
  let ok = List.nth children 2 in
  good.visit_count <- 10; good.total_reward <- 8.0;  (* avg 0.8 *)
  bad.visit_count <- 10; bad.total_reward <- 1.0;     (* avg 0.1 *)
  ok.visit_count <- 10; ok.total_reward <- 6.0;       (* avg 0.6 *)
  match prune t t.root.id ~min_avg_reward:0.5 with
  | Error msg -> failwith msg
  | Ok pruned ->
    check "1 subtree pruned" (pruned = 1);
    check "2 children remain" (List.length t.root.children = 2);
    check "node_count updated" (t.node_count = 3);
    let ids = List.map (fun c -> c.label) t.root.children in
    check "bad removed" (not (List.mem "bad" ids));
    check "good kept" (List.mem "good" ids);
    check "ok kept" (List.mem "ok" ids)

let test_prune_deep_subtree () =
  let t = create ~root_label:"root" () in
  let _ = expand t t.root.id ~labels:["branch"] in
  let branch = List.hd t.root.children in
  let _ = expand t branch.id ~labels:["sub1"; "sub2"] in
  branch.visit_count <- 5; branch.total_reward <- 0.5;  (* avg 0.1 *)
  check "node_count before = 4" (t.node_count = 4);
  match prune t t.root.id ~min_avg_reward:0.5 with
  | Error msg -> failwith msg
  | Ok pruned ->
    check "3 nodes pruned (branch + 2 subs)" (pruned = 3);
    check "node_count = 1 (root only)" (t.node_count = 1);
    check "root has no children" (t.root.children = [])

(* ================================================================ *)
(* Tests: Tree Navigation                                           *)
(* ================================================================ *)

let test_find_node () =
  let t = create ~root_label:"root" () in
  let _ = expand t t.root.id ~labels:["A"; "B"] in
  let a = List.hd t.root.children in
  match find_node t a.id with
  | Some found -> check "found node A" (found.label = "A")
  | None -> check "should find A" false

let test_find_node_missing () =
  let t = create ~root_label:"root" () in
  match find_node t "nonexistent" with
  | None -> check "not found returns None" true
  | Some _ -> check "should not find" false

let test_leaves () =
  let t = create ~root_label:"root" () in
  let _ = expand t t.root.id ~labels:["A"; "B"] in
  let ls = leaves t in
  check "2 leaves (A, B)" (List.length ls = 2)

let test_leaves_root_only () =
  let t = create ~root_label:"root" () in
  let ls = leaves t in
  check "root is leaf" (List.length ls = 1);
  check "leaf is root" ((List.hd ls).label = "root")

let test_depth () =
  let t = create ~root_label:"root" () in
  let _ = expand t t.root.id ~labels:["L1"] in
  let l1 = List.hd t.root.children in
  let _ = expand t l1.id ~labels:["L2"] in
  let l2 = List.hd l1.children in
  check "root depth = 0" (depth t t.root.id = 0);
  check "L1 depth = 1" (depth t l1.id = 1);
  check "L2 depth = 2" (depth t l2.id = 2)

(* ================================================================ *)
(* Tests: Verdict helpers                                           *)
(* ================================================================ *)

let test_verdict_helpers () =
  check "verdict_of_float 1.0 = Pass" (verdict_of_float 1.0 = Pass);
  check "verdict_of_float 0.5 = Warn" (verdict_of_float 0.5 = Warn);
  check "verdict_of_float 0.0 = Fail" (verdict_of_float 0.0 = Fail);
  check "verdict_of_float 0.95 = Pass" (verdict_of_float 0.95 = Pass);
  check "verdict_of_float 0.3 = Fail" (verdict_of_float 0.3 = Fail);
  check "verdict_to_string Pass" (verdict_to_string Pass = "PASS");
  check "verdict_to_string Warn" (verdict_to_string Warn = "WARN");
  check "verdict_to_string Fail" (verdict_to_string Fail = "FAIL")

let test_verdict_yojson_roundtrip () =
  let check_rt v =
    match verdict_of_yojson (verdict_to_yojson v) with
    | Ok v2 -> v = v2
    | Error _ -> false
  in
  check "Pass roundtrip" (check_rt Pass);
  check "Warn roundtrip" (check_rt Warn);
  check "Fail roundtrip" (check_rt Fail)

(* ================================================================ *)
(* Tests: Serialization                                             *)
(* ================================================================ *)

let test_to_yojson () =
  let t = create ~root_label:"root" () in
  let _ = expand t t.root.id ~labels:["A"] in
  let json = to_yojson t in
  match json with
  | `Assoc fields ->
    check "has root field" (List.mem_assoc "root" fields);
    check "has node_count" (List.mem_assoc "node_count" fields);
    check "has metrics" (List.mem_assoc "metrics" fields)
  | _ -> check "should be Assoc" false

let test_summary_yojson () =
  let t = create ~root_label:"root" () in
  let _ = expand t t.root.id ~labels:["A"; "B"] in
  let a = List.hd t.root.children in
  a.visit_count <- 5; a.total_reward <- 4.0;
  let json = summary_to_yojson t in
  match json with
  | `Assoc fields ->
    check "has best_path" (List.mem_assoc "best_path" fields);
    check "has node_count" (List.mem_assoc "node_count" fields);
    check "has leaf_count" (List.mem_assoc "leaf_count" fields)
  | _ -> check "should be Assoc" false

(* ================================================================ *)
(* Tests: Full MCTS Cycle                                           *)
(* ================================================================ *)

let test_full_mcts_cycle () =
  let t = create ~root_label:"Fix login bug" () in
  (* Expand: 3 candidate approaches *)
  let _ = expand t t.root.id
    ~labels:["Regex validation"; "Schema parse"; "Token refresh"] in
  (* Simulate each *)
  let children = t.root.children in
  let regex = List.nth children 0 in
  let schema = List.nth children 1 in
  let token = List.nth children 2 in
  (* Regex: FAIL *)
  let r1 = record_simulation t regex.id (make_sim Fail) in
  (match r1 with Ok r -> backpropagate t regex.id r | _ -> ());
  (* Schema: PASS *)
  let r2 = record_simulation t schema.id (make_sim Pass) in
  (match r2 with Ok r -> backpropagate t schema.id r | _ -> ());
  (* Token: WARN *)
  let r3 = record_simulation t token.id (make_sim Warn) in
  (match r3 with Ok r -> backpropagate t token.id r | _ -> ());
  (* Best path should go through schema (highest reward) *)
  let path = best_path t in
  check "best path length = 2" (List.length path = 2);
  let best_leaf = List.nth path 1 in
  check "best approach = Schema parse" (best_leaf.label = "Schema parse");
  check "root visited 3 times" (t.root.visit_count = 3);
  check "total_simulations = 3" (t.total_simulations = 3)

(* ================================================================ *)
(* Runner                                                           *)
(* ================================================================ *)

let () =
  Printf.printf "=== MCTS Tree Tests ===\n%!";

  run_test "create" test_create;
  run_test "create custom C" test_create_custom_c;

  run_test "expand" test_expand;
  run_test "expand already expanded" test_expand_already_expanded;
  run_test "expand not found" test_expand_not_found;
  run_test "add_child (progressive widening)" test_add_child;

  run_test "UCB1 unvisited first" test_ucb1_unvisited_first;
  run_test "UCB1 exploitation (C=0)" test_ucb1_exploitation;
  run_test "select_path" test_select_path;

  run_test "record simulation" test_record_simulation;
  run_test "record warn/fail" test_record_warn_fail;
  run_test "record not found" test_record_not_found;

  run_test "backpropagate" test_backpropagate;
  run_test "backpropagate two levels" test_backpropagate_two_levels;

  run_test "best path" test_best_path;
  run_test "best child empty" test_best_child_empty;

  run_test "prune" test_prune;
  run_test "prune deep subtree" test_prune_deep_subtree;

  run_test "find node" test_find_node;
  run_test "find node missing" test_find_node_missing;
  run_test "leaves" test_leaves;
  run_test "leaves root only" test_leaves_root_only;
  run_test "depth" test_depth;

  run_test "verdict helpers" test_verdict_helpers;
  run_test "verdict yojson roundtrip" test_verdict_yojson_roundtrip;

  run_test "to_yojson" test_to_yojson;
  run_test "summary_yojson" test_summary_yojson;

  run_test "full MCTS cycle" test_full_mcts_cycle;

  Printf.printf "\n=== Results: %d passed, %d failed ===\n%!" !pass_count !fail_count;
  if !fail_count > 0 then exit 1
