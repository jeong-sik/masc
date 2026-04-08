(** Tests for Keeper_telemetry_feedback — behavioral stats computation
    and prompt block rendering. *)

module TF = Masc_mcp.Keeper_telemetry_feedback

let () =
  (* -- empty_stats -- *)
  let stats = TF.empty_stats ~window_hours:24 in
  assert (stats.total_turns = 0);
  assert (stats.silent_ratio = 0.0);
  assert (stats.window_hours = 24);
  assert (stats.unique_tools_used = []);
  Printf.printf "PASS: empty_stats\n";

  (* -- compute_stats on missing file -- *)
  let stats =
    TF.compute_stats
      ~decision_log_path:"/nonexistent/path.jsonl"
      ~window_hours:24
  in
  assert (stats.total_turns = 0);
  assert (stats.silent_ratio = 0.0);
  Printf.printf "PASS: compute_stats on missing file\n";

  (* -- render_feedback_block with empty stats -- *)
  let block = TF.render_feedback_block ~stats in
  assert (String.length block > 0);
  assert (
    try
      let _ = String.index block '#' in true
    with Not_found -> false);
  Printf.printf "PASS: render_feedback_block with empty stats\n";

  (* -- render_feedback_block with non-zero stats -- *)
  let stats =
    { TF.window_hours = 24
    ; total_turns = 10
    ; silent_turns = 7
    ; silent_ratio = 0.7
    ; tool_use_turns = 2
    ; text_response_turns = 1
    ; unique_tools_used = ["keeper_board_list"; "keeper_shell_readonly"]
    ; tool_utilization_rate = 0.9
    ; last_visible_action_age_sec = 3600
    ; pr_workflow_attempts = 0
    ; work_discovery_count = 0
    }
  in
  let block = TF.render_feedback_block ~stats in
  assert (String.length block > 0);
  let contains s sub =
    try
      let _ = Re.Str.search_forward (Re.Str.regexp_string sub) s 0 in
      true
    with Not_found -> false
  in
  assert (contains block "70.0%");
  assert (contains block "PR workflow attempts: 0");
  assert (contains block "1h 0m");
  Printf.printf "PASS: render_feedback_block with data\n";

  (* -- compute_stats with actual JSONL data -- *)
  let now = Unix.gettimeofday () in
  let tmp_path = Filename.temp_file "test_decisions_" ".jsonl" in
  let oc = open_out tmp_path in
  (* 3 entries in window: 1 silent, 1 with tools, 1 text-only *)
  Printf.fprintf oc
    {|{"timestamp_unix":%.1f,"outcome":"proactive_silent","tool_call_count":0,"tools_used":[]}|}
    (now -. 100.0);
  output_char oc '\n';
  Printf.fprintf oc
    {|{"timestamp_unix":%.1f,"outcome":"tool_use","tool_call_count":2,"tools_used":["keeper_board_list","keeper_pr_workflow"]}|}
    (now -. 50.0);
  output_char oc '\n';
  Printf.fprintf oc
    {|{"timestamp_unix":%.1f,"outcome":"text_response","tool_call_count":0,"tools_used":[]}|}
    (now -. 10.0);
  output_char oc '\n';
  (* 1 entry outside window (48h ago) — should be filtered out *)
  Printf.fprintf oc
    {|{"timestamp_unix":%.1f,"outcome":"proactive_silent","tool_call_count":0,"tools_used":[]}|}
    (now -. 200000.0);
  output_char oc '\n';
  close_out oc;
  let stats = TF.compute_stats ~decision_log_path:tmp_path ~window_hours:24 in
  assert (stats.total_turns = 3);
  assert (stats.silent_turns = 1);
  assert (stats.tool_use_turns = 1);
  assert (stats.text_response_turns = 1);
  assert (stats.pr_workflow_attempts = 1);
  assert (List.length stats.unique_tools_used = 2);
  assert (List.mem "keeper_board_list" stats.unique_tools_used);
  assert (List.mem "keeper_pr_workflow" stats.unique_tools_used);
  (* silent_ratio = 1/3 ≈ 0.333 *)
  assert (stats.silent_ratio > 0.33 && stats.silent_ratio < 0.34);
  Sys.remove tmp_path;
  Printf.printf "PASS: compute_stats with actual data\n";

  (* -- window filtering: 1h window should exclude entries > 1h ago -- *)
  let tmp_path2 = Filename.temp_file "test_decisions_window_" ".jsonl" in
  let oc2 = open_out tmp_path2 in
  Printf.fprintf oc2
    {|{"timestamp_unix":%.1f,"outcome":"tool_use","tool_call_count":1,"tools_used":["keeper_shell_readonly"]}|}
    (now -. 1800.0);  (* 30min ago — inside 1h window *)
  output_char oc2 '\n';
  Printf.fprintf oc2
    {|{"timestamp_unix":%.1f,"outcome":"tool_use","tool_call_count":1,"tools_used":["keeper_shell_readonly"]}|}
    (now -. 7200.0);  (* 2h ago — outside 1h window *)
  output_char oc2 '\n';
  close_out oc2;
  let stats2 = TF.compute_stats ~decision_log_path:tmp_path2 ~window_hours:1 in
  assert (stats2.total_turns = 1);
  Sys.remove tmp_path2;
  Printf.printf "PASS: compute_stats window filtering\n";

  (* -- Cache miss: get_cached_stats before any refresh returns window_hours:0 -- *)
  Eio_main.run (fun _env ->
    let stats_miss =
      TF.get_cached_stats ~keeper_name:"test-keeper-no-refresh"
    in
    assert (stats_miss.window_hours = 0);
    assert (stats_miss.total_turns = 0);
    assert (TF.get_cache_age_sec ~keeper_name:"test-keeper-no-refresh" = None);
    Printf.printf "PASS: cache miss returns empty_stats with window_hours=0\n");

  (* -- Cache hit: refresh_stats updates cache, get_cached_stats returns data -- *)
  let tmp_path3 = Filename.temp_file "test_decisions_cache_" ".jsonl" in
  let oc3 = open_out tmp_path3 in
  Printf.fprintf oc3
    {|{"timestamp_unix":%.1f,"outcome":"tool_use","tool_call_count":1,"tools_used":["keeper_shell_readonly"]}|}
    (now -. 300.0);
  output_char oc3 '\n';
  close_out oc3;
  Eio_main.run (fun _env ->
    TF.refresh_stats
      ~keeper_name:"test-keeper-cache"
      ~decision_log_path:tmp_path3
      ~window_hours:24;
    let cached = TF.get_cached_stats ~keeper_name:"test-keeper-cache" in
    assert (cached.total_turns = 1);
    assert (cached.window_hours = 24);
    assert (cached.tool_use_turns = 1);
    let age = TF.get_cache_age_sec ~keeper_name:"test-keeper-cache" in
    assert (age <> None);
    assert (Option.get age < 5.0);
    Printf.printf "PASS: refresh_stats populates cache, get_cached_stats returns data\n");
  Sys.remove tmp_path3;

  Printf.printf "All telemetry feedback tests passed.\n"
