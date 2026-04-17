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

(* Environment configuration tests *)
let test_configured_max_k_default () =
  (* Unset env var to test default *)
  Unix.unsetenv "MASC_KEEPER_TOOL_AFFINITY_K";
  let k = Affinity.configured_max_k () in
  Alcotest.(check int) "default max_k is 5" 5 k

let test_configured_max_k_clamps_lower () =
  (* Negative values clamp to 0 *)
  Unix.putenv "MASC_KEEPER_TOOL_AFFINITY_K" "-1";
  let k = Affinity.configured_max_k () in
  Alcotest.(check int) "-1 clamps to 0" 0 k

let test_configured_max_k_clamps_upper () =
  (* Values > 20 clamp to 20 *)
  Unix.putenv "MASC_KEEPER_TOOL_AFFINITY_K" "21";
  let k = Affinity.configured_max_k () in
  Alcotest.(check int) "21 clamps to 20" 20 k;

  Unix.putenv "MASC_KEEPER_TOOL_AFFINITY_K" "999";
  let k = Affinity.configured_max_k () in
  Alcotest.(check int) "999 clamps to 20" 20 k

let test_configured_max_k_boundary_values () =
  (* Exact boundary values *)
  Unix.putenv "MASC_KEEPER_TOOL_AFFINITY_K" "0";
  let k = Affinity.configured_max_k () in
  Alcotest.(check int) "0 stays 0" 0 k;

  Unix.putenv "MASC_KEEPER_TOOL_AFFINITY_K" "20";
  let k = Affinity.configured_max_k () in
  Alcotest.(check int) "20 stays 20" 20 k;

  Unix.putenv "MASC_KEEPER_TOOL_AFFINITY_K" "10";
  let k = Affinity.configured_max_k () in
  Alcotest.(check int) "10 stays 10" 10 k

let test_configured_max_k_invalid_input () =
  (* Invalid strings fall back to default *)
  Unix.putenv "MASC_KEEPER_TOOL_AFFINITY_K" "abc";
  let k = Affinity.configured_max_k () in
  Alcotest.(check int) "non-numeric 'abc' → default 5" 5 k;

  Unix.putenv "MASC_KEEPER_TOOL_AFFINITY_K" "1.5";
  let k = Affinity.configured_max_k () in
  Alcotest.(check int) "float '1.5' → default 5" 5 k;

  Unix.putenv "MASC_KEEPER_TOOL_AFFINITY_K" "";
  let k = Affinity.configured_max_k () in
  Alcotest.(check int) "empty string → default 5" 5 k

let test_configured_lookback_days_default () =
  (* Unset env var to test default *)
  Unix.unsetenv "MASC_KEEPER_TOOL_AFFINITY_LOOKBACK_DAYS";
  let days = Affinity.configured_lookback_days () in
  Alcotest.(check int) "default lookback_days is 7" 7 days

let test_configured_lookback_days_clamps_lower () =
  (* Values < 1 clamp to 1 *)
  Unix.putenv "MASC_KEEPER_TOOL_AFFINITY_LOOKBACK_DAYS" "0";
  let days = Affinity.configured_lookback_days () in
  Alcotest.(check int) "0 clamps to 1" 1 days;

  Unix.putenv "MASC_KEEPER_TOOL_AFFINITY_LOOKBACK_DAYS" "-1";
  let days = Affinity.configured_lookback_days () in
  Alcotest.(check int) "-1 clamps to 1" 1 days

let test_configured_lookback_days_clamps_upper () =
  (* Values > 30 clamp to 30 *)
  Unix.putenv "MASC_KEEPER_TOOL_AFFINITY_LOOKBACK_DAYS" "31";
  let days = Affinity.configured_lookback_days () in
  Alcotest.(check int) "31 clamps to 30" 30 days;

  Unix.putenv "MASC_KEEPER_TOOL_AFFINITY_LOOKBACK_DAYS" "99";
  let days = Affinity.configured_lookback_days () in
  Alcotest.(check int) "99 clamps to 30" 30 days

let test_configured_lookback_days_boundary_values () =
  (* Exact boundary values *)
  Unix.putenv "MASC_KEEPER_TOOL_AFFINITY_LOOKBACK_DAYS" "1";
  let days = Affinity.configured_lookback_days () in
  Alcotest.(check int) "1 stays 1" 1 days;

  Unix.putenv "MASC_KEEPER_TOOL_AFFINITY_LOOKBACK_DAYS" "30";
  let days = Affinity.configured_lookback_days () in
  Alcotest.(check int) "30 stays 30" 30 days;

  Unix.putenv "MASC_KEEPER_TOOL_AFFINITY_LOOKBACK_DAYS" "14";
  let days = Affinity.configured_lookback_days () in
  Alcotest.(check int) "14 stays 14" 14 days

let test_configured_lookback_days_invalid_input () =
  (* Invalid strings fall back to default *)
  Unix.putenv "MASC_KEEPER_TOOL_AFFINITY_LOOKBACK_DAYS" "abc";
  let days = Affinity.configured_lookback_days () in
  Alcotest.(check int) "non-numeric 'abc' → default 7" 7 days;

  Unix.putenv "MASC_KEEPER_TOOL_AFFINITY_LOOKBACK_DAYS" "2.5";
  let days = Affinity.configured_lookback_days () in
  Alcotest.(check int) "float '2.5' → default 7" 7 days;

  Unix.putenv "MASC_KEEPER_TOOL_AFFINITY_LOOKBACK_DAYS" "";
  let days = Affinity.configured_lookback_days () in
  Alcotest.(check int) "empty string → default 7" 7 days

(* Cleanup: unset env vars after each test *)
let cleanup () =
  Unix.unsetenv "MASC_KEEPER_TOOL_AFFINITY_K";
  Unix.unsetenv "MASC_KEEPER_TOOL_AFFINITY_LOOKBACK_DAYS"

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
    ]);
    ("environment_configuration", [
      Alcotest.test_case "configured_max_k default" `Quick (fun () -> test_configured_max_k_default (); cleanup ());
      Alcotest.test_case "configured_max_k clamps lower" `Quick (fun () -> test_configured_max_k_clamps_lower (); cleanup ());
      Alcotest.test_case "configured_max_k clamps upper" `Quick (fun () -> test_configured_max_k_clamps_upper (); cleanup ());
      Alcotest.test_case "configured_max_k boundary values" `Quick (fun () -> test_configured_max_k_boundary_values (); cleanup ());
      Alcotest.test_case "configured_max_k invalid input" `Quick (fun () -> test_configured_max_k_invalid_input (); cleanup ());
      Alcotest.test_case "configured_lookback_days default" `Quick (fun () -> test_configured_lookback_days_default (); cleanup ());
      Alcotest.test_case "configured_lookback_days clamps lower" `Quick (fun () -> test_configured_lookback_days_clamps_lower (); cleanup ());
      Alcotest.test_case "configured_lookback_days clamps upper" `Quick (fun () -> test_configured_lookback_days_clamps_upper (); cleanup ());
      Alcotest.test_case "configured_lookback_days boundary values" `Quick (fun () -> test_configured_lookback_days_boundary_values (); cleanup ());
      Alcotest.test_case "configured_lookback_days invalid input" `Quick (fun () -> test_configured_lookback_days_invalid_input (); cleanup ());
    ]);
  ]
