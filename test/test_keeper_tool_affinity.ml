(** Tests for Keeper_tool_affinity — trajectory-based tool pre-population. *)

module Affinity = Masc_mcp.Keeper_tool_affinity
module Trajectory = Masc_mcp.Trajectory
module Discovered = Masc_mcp.Keeper_discovered_tools

(* Helper: build a tool_stat record *)
let stat ?(successes = 5) ?(failures = 0) ?(last = "2026-04-06T12:00:00Z") name =
  let count = successes + failures in
  { Trajectory.name;
    call_count = count;
    success_count = successes;
    failure_count = failures;
    avg_duration_ms = 100;
    p95_duration_ms = 200;
    max_duration_ms = 300;
    total_cost_usd = 0.01;
    last_used_at = last }

(* now = 2026-04-06T14:00:00Z in Unix time (approx) *)
let now = 1775397600.0

let test_empty_stats () =
  let result = Affinity.compute_affinity ~tool_stats:[] ~now ~max_k:5 in
  Alcotest.(check int) "empty stats → empty result" 0 (List.length result)

let test_filters_low_success () =
  let stats = [
    stat ~successes:1 ~failures:9 "bad_tool";   (* 10% success *)
    stat ~successes:8 ~failures:2 "good_tool";  (* 80% success *)
  ] in
  let result = Affinity.compute_affinity ~tool_stats:stats ~now ~max_k:5 in
  Alcotest.(check int) "only good_tool passes" 1 (List.length result);
  Alcotest.(check string) "good_tool selected"
    "good_tool" (List.hd result).tool_name

let test_respects_max_k () =
  let stats = List.init 10 (fun i ->
    stat ~successes:(10 - i) (Printf.sprintf "tool_%d" i)
  ) in
  let result = Affinity.compute_affinity ~tool_stats:stats ~now ~max_k:3 in
  Alcotest.(check int) "max_k=3 returns 3" 3 (List.length result)

let test_score_ordering () =
  let stats = [
    stat ~successes:2 ~failures:0 "low_count";    (* 2 calls, 100% *)
    stat ~successes:10 ~failures:0 "high_count";   (* 10 calls, 100% *)
    stat ~successes:5 ~failures:0 "mid_count";     (* 5 calls, 100% *)
  ] in
  let result = Affinity.compute_affinity ~tool_stats:stats ~now ~max_k:10 in
  let names = List.map (fun (e : Affinity.affinity_entry) -> e.tool_name) result in
  Alcotest.(check (list string)) "ordered by score desc"
    [ "high_count"; "mid_count"; "low_count" ] names

let test_recency_decay () =
  let stats = [
    (* 1 hour ago *)
    stat ~successes:5 ~last:"2026-04-06T13:00:00Z" "recent_tool";
    (* 7 days ago *)
    stat ~successes:5 ~last:"2026-03-30T12:00:00Z" "old_tool";
  ] in
  let result = Affinity.compute_affinity ~tool_stats:stats ~now ~max_k:10 in
  Alcotest.(check int) "both pass" 2 (List.length result);
  Alcotest.(check string) "recent_tool ranked first"
    "recent_tool" (List.hd result).tool_name;
  Alcotest.(check bool) "recent has higher score"
    true ((List.hd result).score > (List.nth result 1).score)

let test_max_k_zero () =
  let stats = [ stat "some_tool" ] in
  let result = Affinity.compute_affinity ~tool_stats:stats ~now ~max_k:0 in
  Alcotest.(check int) "max_k=0 → empty" 0 (List.length result)

let test_populates_discovered () =
  let discovered = Discovered.create ~decay_turns:5 in
  let stats = [
    stat ~successes:5 "keeper_board_post";
    stat ~successes:3 "keeper_board_comment";
  ] in
  (* Simulate pre_populate_from_history logic inline
     (can't call pre_populate_from_history without real trajectory files) *)
  let affinity = Affinity.compute_affinity ~tool_stats:stats ~now ~max_k:5 in
  let names = List.map (fun (e : Affinity.affinity_entry) -> e.tool_name) affinity in
  Discovered.add discovered ~turn:0 ~names;
  let active = Discovered.active_names discovered ~turn:0 in
  Alcotest.(check int) "2 tools in discovered" 2 (List.length active);
  Alcotest.(check bool) "board_post present" true
    (List.mem "keeper_board_post" active);
  Alcotest.(check bool) "board_comment present" true
    (List.mem "keeper_board_comment" active)

let test_configured_max_k_default () =
  (* Without env var, should return default 5 *)
  let k = Affinity.configured_max_k () in
  Alcotest.(check bool) "default max_k in [0,20]" true (k >= 0 && k <= 20)

let () =
  Alcotest.run "Keeper tool affinity" [
    ("compute_affinity", [
      Alcotest.test_case "empty stats" `Quick test_empty_stats;
      Alcotest.test_case "filters low success rate" `Quick test_filters_low_success;
      Alcotest.test_case "respects max_k" `Quick test_respects_max_k;
      Alcotest.test_case "score ordering" `Quick test_score_ordering;
      Alcotest.test_case "recency decay" `Quick test_recency_decay;
      Alcotest.test_case "max_k=0 disables" `Quick test_max_k_zero;
    ]);
    ("integration", [
      Alcotest.test_case "populates discovered" `Quick test_populates_discovered;
      Alcotest.test_case "configured_max_k default" `Quick test_configured_max_k_default;
    ]);
  ]
