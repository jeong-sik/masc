(** Tests for Keeper_tool_affinity — trajectory-based tool pre-population. *)

module Affinity = Masc.Keeper_tool_affinity
module Trajectory = Trajectory
module Discovered = Keeper_discovered_tools

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

(* Environment configuration tests — using parameter injection *)

let test_configured_max_k_default () =
  (* Mock getenv that returns None to trigger default *)
  let mock_getenv _ = None in
  let k = Affinity.configured_max_k ~getenv:mock_getenv () in
  Alcotest.(check int) "default max_k is 5" 5 k

let test_configured_max_k_clamps_lower () =
  (* Negative values clamp to 0 *)
  let test_value value expected =
    let mock_getenv key =
      match key with
      | "MASC_KEEPER_TOOL_AFFINITY_K" -> Some value
      | _ -> None
    in
    let k = Affinity.configured_max_k ~getenv:mock_getenv () in
    Alcotest.(check int) (Printf.sprintf "%s clamps to %d" value expected) expected k
  in
  test_value "-1" 0

let test_configured_max_k_clamps_upper () =
  (* Values > 20 clamp to 20 *)
  let test_value value expected =
    let mock_getenv key =
      match key with
      | "MASC_KEEPER_TOOL_AFFINITY_K" -> Some value
      | _ -> None
    in
    let k = Affinity.configured_max_k ~getenv:mock_getenv () in
    Alcotest.(check int) (Printf.sprintf "%s clamps to %d" value expected) expected k
  in
  test_value "21" 20;
  test_value "999" 20

let test_configured_max_k_boundary_values () =
  (* Exact boundary values *)
  let test_value value expected =
    let mock_getenv key =
      match key with
      | "MASC_KEEPER_TOOL_AFFINITY_K" -> Some value
      | _ -> None
    in
    let k = Affinity.configured_max_k ~getenv:mock_getenv () in
    Alcotest.(check int) (Printf.sprintf "%s stays %d" value expected) expected k
  in
  test_value "0" 0;
  test_value "20" 20;
  test_value "10" 10

let test_configured_max_k_invalid_input () =
  (* Invalid strings fall back to default *)
  let test_value value expected_msg =
    let mock_getenv key =
      match key with
      | "MASC_KEEPER_TOOL_AFFINITY_K" -> Some value
      | _ -> None
    in
    let k = Affinity.configured_max_k ~getenv:mock_getenv () in
    Alcotest.(check int) expected_msg 5 k
  in
  test_value "abc" "non-numeric 'abc' → default 5";
  test_value "1.5" "float '1.5' → default 5";
  test_value "" "empty string → default 5"

let test_configured_lookback_days_default () =
  (* Mock getenv that returns None to trigger default *)
  let mock_getenv _ = None in
  let days = Affinity.configured_lookback_days ~getenv:mock_getenv () in
  Alcotest.(check int) "default lookback_days is 7" 7 days

let test_configured_lookback_days_clamps_lower () =
  (* Values < 1 clamp to 1 *)
  let test_value value expected =
    let mock_getenv key =
      match key with
      | "MASC_KEEPER_TOOL_AFFINITY_LOOKBACK_DAYS" -> Some value
      | _ -> None
    in
    let days = Affinity.configured_lookback_days ~getenv:mock_getenv () in
    Alcotest.(check int) (Printf.sprintf "%s clamps to %d" value expected) expected days
  in
  test_value "0" 1;
  test_value "-1" 1

let test_configured_lookback_days_clamps_upper () =
  (* Values > 30 clamp to 30 *)
  let test_value value expected =
    let mock_getenv key =
      match key with
      | "MASC_KEEPER_TOOL_AFFINITY_LOOKBACK_DAYS" -> Some value
      | _ -> None
    in
    let days = Affinity.configured_lookback_days ~getenv:mock_getenv () in
    Alcotest.(check int) (Printf.sprintf "%s clamps to %d" value expected) expected days
  in
  test_value "31" 30;
  test_value "99" 30

let test_configured_lookback_days_boundary_values () =
  (* Exact boundary values *)
  let test_value value expected =
    let mock_getenv key =
      match key with
      | "MASC_KEEPER_TOOL_AFFINITY_LOOKBACK_DAYS" -> Some value
      | _ -> None
    in
    let days = Affinity.configured_lookback_days ~getenv:mock_getenv () in
    Alcotest.(check int) (Printf.sprintf "%s stays %d" value expected) expected days
  in
  test_value "1" 1;
  test_value "30" 30;
  test_value "14" 14

let test_configured_lookback_days_invalid_input () =
  (* Invalid strings fall back to default *)
  let test_value value expected_msg =
    let mock_getenv key =
      match key with
      | "MASC_KEEPER_TOOL_AFFINITY_LOOKBACK_DAYS" -> Some value
      | _ -> None
    in
    let days = Affinity.configured_lookback_days ~getenv:mock_getenv () in
    Alcotest.(check int) expected_msg 7 days
  in
  test_value "abc" "non-numeric 'abc' → default 7";
  test_value "2.5" "float '2.5' → default 7";
  test_value "" "empty string → default 7"

(* ================================================================ *)
(* Append-time aggregate: equivalence + rebuild fallback             *)
(* ================================================================ *)

(* Build a raw trajectory entry. [ts] drives windowing/day-bucketing;
   [iso] drives recency weighting — both paths read the same values. *)
let entry ?(err = None) ?(gate = Trajectory.Pass) ~ts ~iso name :
    Trajectory.tool_call_entry =
  { Trajectory.ts; ts_iso = iso; turn = 1; round = 0; tool_name = name;
    args_json = "{}"; gate_decision = gate; result = Some "ok";
    duration_ms = 10; error = err; cost_usd = 0.0; execution_id = None }

let filter_allowed_core ~allowed ~core stats =
  let allowed_set = Hashtbl.create 8 in
  List.iter (fun n -> Hashtbl.replace allowed_set n ()) allowed;
  let core_set = Hashtbl.create 8 in
  List.iter (fun n -> Hashtbl.replace core_set n ()) core;
  List.filter
    (fun (s : Trajectory.tool_stat) ->
      Hashtbl.mem allowed_set s.Trajectory.name
      && not (Hashtbl.mem core_set s.Trajectory.name))
    stats

(* Golden equivalence: the append-time aggregate windowed to [since]
   produces the SAME compute_affinity result as the legacy scan-time path
   ([filter ts>=since] then [aggregate_tool_stats]). Fixtures are placed
   clearly inside/outside the window (>1 day past [since]) so the
   day-aligned boundary never diverges from the per-second cutoff. *)
let test_snapshot_equivalence_with_scan () =
  let now = 1_775_000_000.0 in
  let day = 86400.0 in
  let since = now -. (7.0 *. day) in
  let entries = [
    (* keeper_board_post: 5 ok + 1 failure, in window *)
    entry ~ts:(now -. 3600.) ~iso:"2026-04-06T12:00:00Z" "keeper_board_post";
    entry ~ts:(now -. 3700.) ~iso:"2026-04-06T12:00:00Z" "keeper_board_post";
    entry ~ts:(now -. 3800.) ~iso:"2026-04-06T12:00:00Z" "keeper_board_post";
    entry ~ts:(now -. 3900.) ~iso:"2026-04-06T12:00:00Z" "keeper_board_post";
    entry ~ts:(now -. 4000.) ~iso:"2026-04-06T12:00:00Z" "keeper_board_post";
    entry ~err:(Some "boom") ~ts:(now -. 4100.) ~iso:"2026-04-06T12:00:00Z"
      "keeper_board_post";
    (* keeper_board_comment: 3 ok, in window *)
    entry ~ts:(now -. 7200.) ~iso:"2026-04-06T11:00:00Z" "keeper_board_comment";
    entry ~ts:(now -. 7300.) ~iso:"2026-04-06T11:00:00Z" "keeper_board_comment";
    entry ~ts:(now -. 7400.) ~iso:"2026-04-06T11:00:00Z" "keeper_board_comment";
    (* tool_execute: core tool → filtered out in both paths *)
    entry ~ts:(now -. 100.) ~iso:"2026-04-06T13:00:00Z" "tool_execute";
    (* stale_tool: only out of window (10 days ago) → excluded by both *)
    entry ~ts:(now -. (10.0 *. day)) ~iso:"2026-03-27T12:00:00Z" "stale_tool";
    entry ~ts:(now -. (10.0 *. day) -. 100.) ~iso:"2026-03-27T12:00:00Z" "stale_tool";
  ] in
  let allowed =
    [ "keeper_board_post"; "keeper_board_comment"; "stale_tool"; "tool_execute" ]
  in
  let core = [ "tool_execute" ] in
  (* Path A: legacy scan-time aggregation. *)
  let scan_affinity =
    List.filter (fun (e : Trajectory.tool_call_entry) -> e.Trajectory.ts >= since) entries
    |> Trajectory.aggregate_tool_stats
    |> filter_allowed_core ~allowed ~core
    |> fun stats -> Affinity.compute_affinity ~tool_stats:stats ~now ~max_k:5
  in
  (* Path B: append-time aggregate, windowed read. *)
  let agg = Trajectory.build_tool_affinity_aggregate ~keeper_name:"equiv" ~now entries in
  let agg_affinity =
    Trajectory.windowed_affinity_tool_stats agg ~since
    |> filter_allowed_core ~allowed ~core
    |> fun stats -> Affinity.compute_affinity ~tool_stats:stats ~now ~max_k:5
  in
  let names a = List.map (fun (e : Affinity.affinity_entry) -> e.tool_name) a in
  Alcotest.(check (list string)) "same tool selection + order"
    (names scan_affinity) (names agg_affinity);
  Alcotest.(check int) "same number of entries"
    (List.length scan_affinity) (List.length agg_affinity);
  List.iter2
    (fun (x : Affinity.affinity_entry) (y : Affinity.affinity_entry) ->
      Alcotest.(check int)
        (Printf.sprintf "call_count[%s]" x.tool_name) x.call_count y.call_count;
      Alcotest.(check (float 1e-9))
        (Printf.sprintf "score[%s]" x.tool_name) x.score y.score)
    scan_affinity agg_affinity

(* resolve_affinity_aggregate must call [rebuild] only when the snapshot
   read fails — never when it is present. Injected counting doubles. *)
let test_resolve_rebuilds_only_when_absent () =
  let rebuild_calls = ref 0 in
  let dummy = Trajectory.build_tool_affinity_aggregate ~keeper_name:"k" ~now:0.0 [] in
  let counting_rebuild ~masc_root:_ ~keeper_name:_ ~now:_ =
    incr rebuild_calls; dummy
  in
  let run read_snapshot =
    ignore
      (Affinity.resolve_affinity_aggregate ~read_snapshot ~rebuild:counting_rebuild
         ~masc_root:"/x" ~keeper_name:"k" ~now:1.0)
  in
  run (fun ~masc_root:_ ~keeper_name:_ -> Ok dummy);
  Alcotest.(check int) "no rebuild when snapshot present" 0 !rebuild_calls;
  run (fun ~masc_root:_ ~keeper_name:_ -> Error Trajectory.Aggregate_missing);
  Alcotest.(check int) "rebuild once when missing" 1 !rebuild_calls;
  run (fun ~masc_root:_ ~keeper_name:_ -> Error (Trajectory.Aggregate_corrupt "x"));
  Alcotest.(check int) "rebuild again when corrupt" 2 !rebuild_calls

(* End-to-end: a missing snapshot triggers exactly one rebuild (full scan),
   persists it, and a second resolve reads the snapshot without rescanning. *)
let test_rebuild_persists_then_no_rescan () =
  let dir =
    Filename.concat (Filename.get_temp_dir_name ())
      (Printf.sprintf "affinity_rebuild_%d" (Random.int 1_000_000))
  in
  (try Unix.mkdir dir 0o755 with _ -> ());
  Fun.protect
    ~finally:(fun () -> Fs_compat.remove_tree dir)
    (fun () ->
      let masc_root = dir and keeper = "reb" in
      let now = Unix.gettimeofday () in
      Trajectory.append_entry ~masc_root ~keeper_name:keeper ~trace_id:"t1"
        (entry ~ts:(now -. 100.) ~iso:"2026-04-06T12:00:00Z" "keeper_board_post");
      let scan_calls = ref 0 in
      let counting_rebuild ~masc_root ~keeper_name ~now =
        incr scan_calls;
        Trajectory.rebuild_tool_affinity_aggregate ~masc_root ~keeper_name ~now
      in
      let resolve () =
        ignore
          (Affinity.resolve_affinity_aggregate
             ~read_snapshot:Trajectory.read_aggregate_snapshot
             ~rebuild:counting_rebuild ~masc_root ~keeper_name:keeper ~now)
      in
      resolve ();
      Alcotest.(check int) "rebuild ran once (snapshot was missing)" 1 !scan_calls;
      Alcotest.(check bool) "snapshot persisted" true
        (Sys.file_exists (Trajectory.aggregate_snapshot_path masc_root keeper));
      resolve ();
      Alcotest.(check int) "second resolve does not rescan" 1 !scan_calls)

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
      Alcotest.test_case "configured_max_k default" `Quick test_configured_max_k_default;
      Alcotest.test_case "configured_max_k clamps lower" `Quick test_configured_max_k_clamps_lower;
      Alcotest.test_case "configured_max_k clamps upper" `Quick test_configured_max_k_clamps_upper;
      Alcotest.test_case "configured_max_k boundary values" `Quick test_configured_max_k_boundary_values;
      Alcotest.test_case "configured_max_k invalid input" `Quick test_configured_max_k_invalid_input;
      Alcotest.test_case "configured_lookback_days default" `Quick test_configured_lookback_days_default;
      Alcotest.test_case "configured_lookback_days clamps lower" `Quick test_configured_lookback_days_clamps_lower;
      Alcotest.test_case "configured_lookback_days clamps upper" `Quick test_configured_lookback_days_clamps_upper;
      Alcotest.test_case "configured_lookback_days boundary values" `Quick test_configured_lookback_days_boundary_values;
      Alcotest.test_case "configured_lookback_days invalid input" `Quick test_configured_lookback_days_invalid_input;
    ]);
    ("append_time_aggregate", [
      Alcotest.test_case "windowed aggregate == scan-time aggregate" `Quick
        test_snapshot_equivalence_with_scan;
      Alcotest.test_case "rebuild runs only on missing/corrupt snapshot" `Quick
        test_resolve_rebuilds_only_when_absent;
      Alcotest.test_case "rebuild persists then no rescan" `Quick
        test_rebuild_persists_then_no_rescan;
    ]);
  ]
