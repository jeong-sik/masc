open Alcotest

module Keeper_types = Masc_mcp.Keeper_types
module Keeper_memory = Masc_mcp.Keeper_memory
module Keeper_exec_status = Masc_mcp.Keeper_exec_status
module Keeper_exec_tools = Masc_mcp.Keeper_exec_tools

let keeper_meta ?(name = "sangsu") ?(goal = "keep continuity")
    ?(models = [ "custom:model-a"; "custom:model-b" ])
    ?(allowed_models = [])
    ?(active_model = "") ?(last_model_used = "")
    ?(mention_targets = [ "sangsu" ]) () =
  let json =
    `Assoc
      [
        ("name", `String name);
        ("trace_id", `String "trace-1");
        ("goal", `String goal);
        ("models", `List (List.map (fun model -> `String model) models));
        ( "allowed_models",
          `List (List.map (fun model -> `String model) allowed_models) );
        ("active_model", `String active_model);
        ("last_model_used", `String last_model_used);
        ( "mention_targets",
          `List (List.map (fun target -> `String target) mention_targets) );
      ]
  in
  match Keeper_types.meta_of_json json with
  | Ok meta -> meta
  | Error err -> fail ("failed to build keeper meta: " ^ err)

let metrics_field_int json key =
  Yojson.Safe.Util.(json |> member key |> to_int)

let metrics_field_float json key =
  Yojson.Safe.Util.(json |> member key |> to_float)

let test_active_model_prefers_active_model () =
  let meta =
    keeper_meta ~active_model:"custom:active" ~last_model_used:"custom:last" ()
  in
  check string "active model wins" "custom:active"
    (Keeper_exec_status.active_model_of_meta meta)

let test_active_model_falls_back_to_last_model () =
  let meta = keeper_meta ~last_model_used:"custom:last" () in
  check string "last model fallback" "custom:last"
    (Keeper_exec_status.active_model_of_meta meta)

let test_next_model_hint_prefers_alternate_model () =
  let meta =
    keeper_meta ~allowed_models:[ "custom:active"; "custom:next"; "custom:next" ]
      ~active_model:"custom:active" ()
  in
  check (option string) "alternate next model" (Some "custom:next")
    (Keeper_exec_status.next_model_hint_of_meta meta)

let test_next_model_hint_falls_back_to_current_model () =
  let meta = keeper_meta ~models:[ "custom:solo" ] ~active_model:"custom:solo" () in
  check (option string) "falls back to current when pool exhausted"
    (Some "custom:solo")
    (Keeper_exec_status.next_model_hint_of_meta meta)

let test_summarize_metrics_lines_counts_channels_and_memory () =
  let lines =
    [
      {|{"channel":"turn","generation":3,"memory_check":{"performed":true,"passed":true,"final_score":0.4,"correction_applied":true,"correction_success":true},"repetition_risk":0.2,"goal_alignment":0.8,"response_alignment":0.6,"goal_drift":0.1}|};
      {|{"channel":"proactive","generation":3,"auto_reflect":true,"auto_plan":true,"compacted":true,"compaction_before_tokens":120,"compaction_after_tokens":90,"guardrail_stop":true,"drift":{"applied":true},"handoff":{"performed":true,"to_model":"custom:model-b","prev_trace_id":"trace-1","new_trace_id":"trace-2"}}|};
      {|{"channel":"heartbeat","generation":3}|};
    ]
  in
  let summary =
    Keeper_exec_status.summarize_metrics_lines lines ~default_generation:3
    |> Keeper_exec_status.metrics_summary_to_json
  in
  check int "sample points" 3 (metrics_field_int summary "sample_points");
  check int "turn points" 1 (metrics_field_int summary "turn_points");
  check int "proactive points" 1 (metrics_field_int summary "proactive_points");
  check int "heartbeat points" 1 (metrics_field_int summary "heartbeat_points");
  check int "memory checks" 1 (metrics_field_int summary "memory_checks");
  check int "memory passed" 1 (metrics_field_int summary "memory_passed");
  check int "auto reflect count" 1 (metrics_field_int summary "auto_reflect_count");
  check int "auto plan count" 1 (metrics_field_int summary "auto_plan_count");
  check int "compaction events" 1 (metrics_field_int summary "compaction_events");
  check int "saved tokens" 30 (metrics_field_int summary "compaction_saved_tokens");
  check int "handoff count" 1 (metrics_field_int summary "handoff_count");
  check int "guardrail stop count" 1
    (metrics_field_int summary "guardrail_stop_count");
  check int "drift applied count" 1
    (metrics_field_int summary "drift_applied_count");
  check (float 0.0001) "memory avg score" 0.4
    (metrics_field_float summary "memory_avg_score")

let test_keeper_reply_snapshot_awaiting_reply () =
  let history_items =
    [
      `Assoc
        [
          ("role", `String "user");
          ("ts_unix", `Float 20.0);
          ("content", `String "latest question");
        ];
    ]
  in
  let status, at_json, preview_json =
    Keeper_exec_status.keeper_reply_snapshot_of_history history_items
  in
  check string "awaiting status" "awaiting_reply"
    Yojson.Safe.Util.(status |> to_string);
  check bool "no reply timestamp" true (at_json = `Null);
  check bool "no preview" true (preview_json = `Null)

let test_keeper_diagnostic_json_marks_offline_recoverable () =
  let meta =
    {
      (keeper_meta ()) with
      total_turns = 1;
      last_turn_ts = 0.0;
      proactive_enabled = true;
    }
  in
  let diagnostic =
    Keeper_exec_status.keeper_diagnostic_json ~meta
      ~agent_status:(`Assoc [ ("exists", `Bool false) ])
      ~keepalive_running:false ~history_items:[] ~now_ts:1000.0
  in
  check string "health state" "offline"
    Yojson.Safe.Util.(diagnostic |> member "health_state" |> to_string);
  check string "next action path" "recover"
    Yojson.Safe.Util.(diagnostic |> member "next_action_path" |> to_string);
  check bool "recoverable" true
    Yojson.Safe.Util.(diagnostic |> member "recoverable" |> to_bool)

let test_select_recall_candidate_prefers_oldest_for_first_question () =
  let selected =
    Keeper_exec_tools.select_recall_candidate
      ~user_message:"What was my first question?"
      ~expected_topic:(Some "first_question") ~best_match:None
      [ "latest"; "middle"; "oldest" ]
  in
  check (option string) "oldest selected" (Some "oldest") selected

let test_select_recall_candidate_prefers_weather_candidate () =
  let selected =
    Keeper_exec_tools.select_recall_candidate
      ~user_message:"날씨 관련 질문 기억나?"
      ~expected_topic:(Some "weather") ~best_match:(Some "just chatted")
      [ "방금 한 말"; "오늘 날씨 어때?" ]
  in
  check (option string) "weather selected" (Some "오늘 날씨 어때?") selected

let test_keeper_tool_loop_system_prompt_embeds_context () =
  let prompt =
    Keeper_exec_tools.keeper_tool_loop_system_prompt
      ~character_context:"Stay in character."
  in
  check bool "includes character context" true
    (String.contains prompt 'S');
  check bool "includes tool loop instructions" true
    (String.contains prompt 'T')

let test_keeper_tool_followup_prompt_write_done_blocks_more_tools () =
  let prompt =
    Keeper_exec_tools.keeper_tool_followup_prompt
      ~user_message:"post this"
      ~draft_reply:"done"
      ~tool_outputs:
        [ ({ Masc_mcp.Llm_client.call_name = "keeper_board_post";
             call_id = "1";
             call_arguments = "{}"; }, "{\"ok\":true}") ]
      ~already_executed:[ "keeper_board_post" ]
  in
  check bool "write rule present" true
    (String.contains prompt 'A');
  check bool "done rule mentions no more tools" true
    (String.contains prompt 'D')

let test_memory_prompts_include_grounding_evidence () =
  let correction =
    Keeper_exec_tools.memory_correction_prompt
      ~user_message:"what was my first question?"
      ~first_reply:"I forgot"
      ~candidate_user_msgs:[ "latest"; "first" ]
      ~expected_topic:(Some "first_question")
  in
  let forced =
    Keeper_exec_tools.memory_forced_grounding_prompt
      ~user_message:"what was my first question?"
      ~first_reply:"I forgot"
      ~candidate_user_msgs:[ "latest"; "first" ]
      ~expected_topic:(Some "first_question")
  in
  check bool "correction prompt mentions evidence" true
    (String.contains correction '1');
  check bool "forced prompt keeps state instruction" true
    (String.contains forced '[')

let test_keyword_helpers_detect_recent_and_weather_queries () =
  check bool "recent ko" true
    (Keeper_exec_tools.is_recent_question_query "방금 내가 뭐라고 했지?");
  check bool "recent en" true
    (Keeper_exec_tools.is_recent_question_query "what was my last question?");
  check bool "weather ko" true
    (Keeper_exec_tools.has_weather_keyword "오늘 날씨 어때?");
  check bool "weather en" true
    (Keeper_exec_tools.has_weather_keyword "how is the weather?");
  check bool "korean text" true
    (Keeper_exec_tools.contains_korean_text "상수처럼 대화해")

let test_recall_fallback_reply_formats_state_block () =
  let reply =
    Keeper_exec_tools.recall_fallback_reply
      ~meta:(keeper_meta ~goal:"remember" ())
      ~user_message:"what was my previous question?"
      ~selected_question:"where are we meeting?"
      ~expected_topic:None
  in
  check bool "reply includes quoted question" true
    (String.contains reply '"');
  check bool "reply includes state block" true
    (String.contains reply '[')

let test_deterministic_recall_fallback_returns_grounded_reply () =
  let meta = keeper_meta ~goal:"remember prior questions" () in
  let eval : Keeper_memory.memory_recall_eval =
    {
      performed = true;
      query_kind = "first_question";
      expected_topic = Some "first_question";
      candidate_count = 2;
      initial_score = 0.0;
      final_score = 0.0;
      threshold = 0.18;
      passed = false;
      best_match = None;
    }
  in
  match
    Keeper_exec_tools.deterministic_recall_fallback ~meta
      ~user_message:"what was my first question?" ~eval
      ~candidates:[ "latest question"; "first question" ]
  with
  | None -> fail "expected deterministic recall fallback"
  | Some (reply, eval2) ->
      check bool "reply includes selected question" true
        (String.contains reply '"');
      check bool "reply includes state block" true
        (String.contains reply '[');
      check bool "second eval performed" true eval2.performed

let test_keeper_allowed_tool_names_respects_policy_branches () =
  let learned_meta =
    {
      (keeper_meta ()) with
      policy_mode = "learned_offline_v1";
      policy_action_budget = "board";
      policy_voice_enabled = true;
      policy_shell_mode = "readonly";
    }
  in
  let heuristic_meta = { (keeper_meta ()) with policy_mode = "heuristic" } in
  let learned_tools = Keeper_exec_tools.keeper_allowed_tool_names learned_meta in
  let heuristic_tools =
    Keeper_exec_tools.keeper_allowed_tool_names ~write_done:true heuristic_meta
  in
  check bool "learned includes board tool" true
    (List.mem "keeper_board_post" learned_tools);
  check bool "learned includes shell readonly tool" true
    (List.mem "keeper_shell_readonly" learned_tools);
  check bool "heuristic write done blocks tools" true (heuristic_tools = [])

let test_execute_keeper_tool_call_readonly_branches () =
  let meta =
    { (keeper_meta ~goal:"remember continuity" ()) with continuity_summary = "steady" }
  in
  let ctx_work =
    let ctx =
      Masc_mcp.Context_manager.create ~system_prompt:"system" ~max_tokens:1024
    in
    let ctx =
      Masc_mcp.Context_manager.append ctx
        (Masc_mcp.Llm_client.user_msg "how is the weather today?")
    in
    Masc_mcp.Context_manager.append ctx
      (Masc_mcp.Llm_client.user_msg "where are we meeting?")
  in
  let config = Masc_mcp.Room.default_config (Filename.get_temp_dir_name ()) in
  let run call_name args =
    Keeper_exec_tools.execute_keeper_tool_call ~config ~meta ~ctx_work
      { Masc_mcp.Llm_client.call_id = "1"; call_name; call_arguments = args }
    |> Yojson.Safe.from_string
  in
  let now_json = run "keeper_time_now" "{}" in
  check bool "time tool has now_iso" true
    Yojson.Safe.Util.(now_json |> member "now_iso" <> `Null);
  let status_json = run "keeper_context_status" "{}" in
  check string "context status continuity summary" "steady"
    Yojson.Safe.Util.(status_json |> member "continuity_summary" |> to_string);
  let memory_json =
    run "keeper_memory_search"
      {|{"query":"weather","limit":2}|}
  in
  check int "memory search match count" 1
    Yojson.Safe.Util.(memory_json |> member "match_count" |> to_int)

let () =
  run "Keeper_exec helpers"
    [
      ( "status",
        [
          test_case "active model prefers active model" `Quick
            test_active_model_prefers_active_model;
          test_case "active model falls back to last used" `Quick
            test_active_model_falls_back_to_last_model;
          test_case "next model prefers alternate model" `Quick
            test_next_model_hint_prefers_alternate_model;
          test_case "next model falls back to current" `Quick
            test_next_model_hint_falls_back_to_current_model;
          test_case "summarize metrics lines counts signals" `Quick
            test_summarize_metrics_lines_counts_channels_and_memory;
          test_case "reply snapshot awaiting reply" `Quick
            test_keeper_reply_snapshot_awaiting_reply;
          test_case "diagnostic json marks offline recoverable" `Quick
            test_keeper_diagnostic_json_marks_offline_recoverable;
        ] );
      ( "tools",
        [
          test_case "select recall candidate oldest" `Quick
            test_select_recall_candidate_prefers_oldest_for_first_question;
          test_case "select recall candidate weather" `Quick
            test_select_recall_candidate_prefers_weather_candidate;
          test_case "tool loop prompt embeds context" `Quick
            test_keeper_tool_loop_system_prompt_embeds_context;
          test_case "tool followup write done blocks more tools" `Quick
            test_keeper_tool_followup_prompt_write_done_blocks_more_tools;
          test_case "memory prompts include grounding evidence" `Quick
            test_memory_prompts_include_grounding_evidence;
          test_case "keyword helpers detect recent and weather queries" `Quick
            test_keyword_helpers_detect_recent_and_weather_queries;
          test_case "recall fallback reply formats state block" `Quick
            test_recall_fallback_reply_formats_state_block;
          test_case "deterministic recall fallback grounded reply" `Quick
            test_deterministic_recall_fallback_returns_grounded_reply;
          test_case "allowed tool names respects policy branches" `Quick
            test_keeper_allowed_tool_names_respects_policy_branches;
          test_case "execute keeper tool call readonly branches" `Quick
            test_execute_keeper_tool_call_readonly_branches;
        ] );
    ]
