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
    ; tool_success_rate = 0.9
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

  Printf.printf "All telemetry feedback tests passed.\n"
