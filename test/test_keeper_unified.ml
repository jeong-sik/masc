open Alcotest

module WO = Masc_mcp.Keeper_world_observation
module UP = Masc_mcp.Keeper_unified_prompt
module UT = Masc_mcp.Keeper_unified_turn
module KAR = Masc_mcp.Keeper_agent_run
(* Keeper_autonomy module removed; autonomy_level is now a plain string *)
module AE = Masc_mcp.Agent_economy
module KC = Masc_mcp.Keeper_config
module HK = Masc_mcp.Keeper_hooks_oas

(* ---------- World Observation type tests ---------- *)

let base_observation : WO.world_observation =
  {
    pending_mentions = [];
    pending_board_events = [];
    idle_seconds = 0;
    active_goals = [];
    autonomy_level = "l1_reactive";
    continuity_summary = "";
    context_ratio = 0.0;
    economic_pressure = AE.Normal;
    unclaimed_task_count = 0;
    failed_task_count = 0;
    active_agent_count = 0;
    triage_triggers = "";
  }

let test_observation_defaults () =
  let obs = base_observation in
  check int "idle_seconds default" 0 obs.idle_seconds;
  check (float 0.001) "context_ratio default" 0.0 obs.context_ratio;
  check int "unclaimed default" 0 obs.unclaimed_task_count;
  check int "failed default" 0 obs.failed_task_count;
  check int "active_agents default" 0 obs.active_agent_count;
  check bool "no mentions" true (obs.pending_mentions = []);
  check bool "no goals" true (obs.active_goals = [])

let test_observation_with_mentions () =
  let obs =
    { base_observation with
      pending_mentions = [("alice", "hey keeper"); ("bob", "need help")]
    }
  in
  check int "mention count" 2 (List.length obs.pending_mentions)

let test_observation_with_goals () =
  let obs =
    { base_observation with
      active_goals = ["goal-1"; "goal-2"; "goal-3"]
    }
  in
  check int "goal count" 3 (List.length obs.active_goals)

let test_observation_autonomy_levels () =
  let levels = [
    "l1_reactive"; "l2_suggestive"; "l3_guided";
    "l4_autonomous"; "l5_independent"
  ] in
  List.iter
    (fun level ->
      let obs = { base_observation with autonomy_level = level } in
      check bool "observation created" true (obs.idle_seconds >= 0))
    levels

let test_observation_economic_modes () =
  let modes = [AE.Normal; AE.Frugal; AE.Hustle] in
  List.iter
    (fun mode ->
      let obs = { base_observation with economic_pressure = mode } in
      check bool "observation created" true (obs.idle_seconds >= 0))
    modes

(* ---------- Unified Prompt tests ---------- *)

let minimal_meta : Masc_mcp.Keeper_types.keeper_meta =
  let json = `Assoc [
    ("name", `String "test-keeper");
    ("trace_id", `String "test-trace-001");
    ("goal", `String "test goal");
  ] in
  match Masc_mcp.Keeper_types.meta_of_json json with
  | Ok m -> m
  | Error e -> failwith ("meta_of_json failed: " ^ e)

let test_prompt_contains_identity () =
  let sys, _user = UP.build_prompt ~meta:minimal_meta ~observation:base_observation in
  check bool "contains name" true (String.length sys > 0);
  check bool "contains keeper name" true
    (let has_name =
       try ignore (Str.search_forward (Str.regexp_string "test-keeper") sys 0); true
       with Not_found -> false
     in has_name)

let test_prompt_contains_goal () =
  let sys, _user = UP.build_prompt ~meta:minimal_meta ~observation:base_observation in
  check bool "contains goal" true
    (let has_goal =
       try ignore (Str.search_forward (Str.regexp_string "test goal") sys 0); true
       with Not_found -> false
     in has_goal)

let test_prompt_omits_empty_sections () =
  let _sys, user = UP.build_prompt ~meta:minimal_meta ~observation:base_observation in
  check bool "no mention section" true
    (not (let found =
       try ignore (Str.search_forward (Str.regexp_string "Pending Mentions") user 0); true
       with Not_found -> false
     in found));
  check bool "no goals section" true
    (not (let found =
       try ignore (Str.search_forward (Str.regexp_string "Active Goals") user 0); true
       with Not_found -> false
     in found))

let test_prompt_includes_mentions_section () =
  let obs =
    { base_observation with
      pending_mentions = [("alice", "hello keeper")]
    }
  in
  let _sys, user = UP.build_prompt ~meta:minimal_meta ~observation:obs in
  check bool "has mention section" true
    (let found =
       try ignore (Str.search_forward (Str.regexp_string "Pending Mentions") user 0); true
       with Not_found -> false
     in found);
  check bool "has mention content" true
    (let found =
       try ignore (Str.search_forward (Str.regexp_string "@alice") user 0); true
       with Not_found -> false
     in found)

let test_prompt_includes_goals_section () =
  let obs =
    { base_observation with
      active_goals = ["goal-abc"]
    }
  in
  let _sys, user = UP.build_prompt ~meta:minimal_meta ~observation:obs in
  check bool "has goals section" true
    (let found =
       try ignore (Str.search_forward (Str.regexp_string "Active Goals") user 0); true
       with Not_found -> false
     in found)

let test_prompt_includes_context_ratio () =
  let obs = { base_observation with context_ratio = 0.75 } in
  let _sys, user = UP.build_prompt ~meta:minimal_meta ~observation:obs in
  check bool "has context percentage" true
    (let found =
       try ignore (Str.search_forward (Str.regexp_string "75%") user 0); true
       with Not_found -> false
     in found)

let test_prompt_includes_idle () =
  let obs = { base_observation with idle_seconds = 300 } in
  let _sys, user = UP.build_prompt ~meta:minimal_meta ~observation:obs in
  check bool "has idle seconds" true
    (let found =
       try ignore (Str.search_forward (Str.regexp_string "300s") user 0); true
       with Not_found -> false
     in found)

let test_prompt_frugal_economy () =
  let obs = { base_observation with economic_pressure = AE.Frugal } in
  let _sys, user = UP.build_prompt ~meta:minimal_meta ~observation:obs in
  check bool "has frugal warning" true
    (let found =
       try ignore (Str.search_forward (Str.regexp_string "Frugal") user 0); true
       with Not_found -> false
     in found)

let test_prompt_hustle_economy () =
  let obs = { base_observation with economic_pressure = AE.Hustle } in
  let _sys, user = UP.build_prompt ~meta:minimal_meta ~observation:obs in
  check bool "has hustle warning" true
    (let found =
       try ignore (Str.search_forward (Str.regexp_string "Hustle") user 0); true
       with Not_found -> false
     in found)

let test_prompt_includes_triage_triggers () =
  let obs =
    { base_observation with
      triage_triggers = "direct_mention,idle_timeout"
    }
  in
  let _sys, user = UP.build_prompt ~meta:minimal_meta ~observation:obs in
  check bool "has triage section" true
    (let found =
       try ignore (Str.search_forward (Str.regexp_string "Triage Triggers") user 0); true
       with Not_found -> false
     in found)

let test_prompt_skips_skip_triage () =
  let obs = { base_observation with triage_triggers = "skip:no_triggers" } in
  let _sys, user = UP.build_prompt ~meta:minimal_meta ~observation:obs in
  check bool "no triage section for skip" true
    (not (let found =
       try ignore (Str.search_forward (Str.regexp_string "Triage Triggers") user 0); true
       with Not_found -> false
     in found))

let test_prompt_room_state_section () =
  let obs =
    { base_observation with
      unclaimed_task_count = 3;
      failed_task_count = 1;
      active_agent_count = 5;
    }
  in
  let _sys, user = UP.build_prompt ~meta:minimal_meta ~observation:obs in
  check bool "has room state" true
    (let found =
       try ignore (Str.search_forward (Str.regexp_string "Room State") user 0); true
       with Not_found -> false
     in found)

let test_prompt_autonomy_description () =
  let obs = { base_observation with autonomy_level = "l3_guided" } in
  let sys, _user = UP.build_prompt ~meta:minimal_meta ~observation:obs in
  check bool "has L3 description" true
    (let found =
       try ignore (Str.search_forward (Str.regexp_string "L3 Guided") sys 0); true
       with Not_found -> false
     in found)

(* ---------- Hooks: autonomy tool filter tests ---------- *)

let test_hooks_allowed_tools_l1 () =
  let allowed = HK.allowed_tools_for_autonomy_level "l1_reactive" in
  match allowed with
  | None -> fail "L1 should have an allow list"
  | Some tools ->
      check bool "keeper_board_get allowed" true (List.mem "keeper_board_get" tools);
      check bool "keeper_bash NOT allowed" true (not (List.mem "keeper_bash" tools))

let test_hooks_allowed_tools_l4 () =
  let allowed = HK.allowed_tools_for_autonomy_level "l4_autonomous" in
  match allowed with
  | None -> fail "L4 should have an allow list"
  | Some tools ->
      check bool "keeper_bash allowed for L4" true (List.mem "keeper_bash" tools);
      check bool "keeper_board_get allowed" true (List.mem "keeper_board_get" tools)

let test_hooks_allowed_tools_l5 () =
  let allowed = HK.allowed_tools_for_autonomy_level "l5_independent" in
  check bool "L5 returns None (AllowAll)" true (allowed = None)

(* ---------- Config tests ---------- *)

let test_unified_turn_runtime_defaults () =
  check (float 0.01) "unified temp default" 0.4
    (KC.keeper_unified_temperature ());
  check int "unified max_tokens default" 2048
    (KC.keeper_unified_max_tokens ());
  check int "unified max_turns default" 10
    (KC.keeper_unified_max_turns ())

(* ---------- Metrics observation tests ---------- *)

let make_run_result ~text ~tools ~model ~input_tok ~output_tok
    : Masc_mcp.Keeper_agent_run.run_result =
  {
    response_text = text;
    model_used = model;
    turn_count = 1;
    tool_calls_made = List.length tools;
    usage = { input_tokens = input_tok; output_tokens = output_tok; cache_creation_input_tokens = 0; cache_read_input_tokens = 0 };
    tools_used = tools;
  }

let test_metrics_text_response () =
  let result =
    make_run_result ~text:"I checked the board." ~tools:[]
      ~model:"test-model" ~input_tok:100 ~output_tok:50
  in
  let updated =
    UT.update_metrics_from_result minimal_meta ~latency_ms:200 result
  in
  check int "total_turns +1" (minimal_meta.total_turns + 1) updated.total_turns;
  check int "proactive_count +1"
    (minimal_meta.proactive_count_total + 1) updated.proactive_count_total;
  check int "no autonomous action" minimal_meta.autonomous_action_count
    updated.autonomous_action_count;
  check int "input tokens" (minimal_meta.total_input_tokens + 100) updated.total_input_tokens;
  check int "output tokens" (minimal_meta.total_output_tokens + 50) updated.total_output_tokens

let test_metrics_tool_response () =
  let result =
    make_run_result ~text:"" ~tools:["keeper_board_post"; "keeper_board_comment"]
      ~model:"test-model" ~input_tok:200 ~output_tok:80
  in
  let updated =
    UT.update_metrics_from_result minimal_meta ~latency_ms:500 result
  in
  check int "proactive_count +1" (minimal_meta.proactive_count_total + 1)
    updated.proactive_count_total;
  check int "autonomous_action +2" (minimal_meta.autonomous_action_count + 2)
    updated.autonomous_action_count;
  check int "latency_ms" 500 updated.last_latency_ms

let test_metrics_noop_response () =
  let result =
    make_run_result ~text:"" ~tools:[]
      ~model:"test-model" ~input_tok:50 ~output_tok:10
  in
  let updated =
    UT.update_metrics_from_result minimal_meta ~latency_ms:100 result
  in
  check int "proactive_count unchanged" minimal_meta.proactive_count_total
    updated.proactive_count_total;
  check int "autonomous unchanged" minimal_meta.autonomous_action_count
    updated.autonomous_action_count;
  check int "total_turns +1" (minimal_meta.total_turns + 1) updated.total_turns

let test_metrics_mixed_response () =
  let result =
    make_run_result ~text:"Done." ~tools:["keeper_read"]
      ~model:"test-model" ~input_tok:150 ~output_tok:60
  in
  let updated =
    UT.update_metrics_from_result minimal_meta ~latency_ms:300 result
  in
  check int "proactive +1" (minimal_meta.proactive_count_total + 1)
    updated.proactive_count_total;
  check int "autonomous +1" (minimal_meta.autonomous_action_count + 1)
    updated.autonomous_action_count;
  check bool "proactive reason has unified" true
    (let found =
       try ignore (Str.search_forward (Str.regexp_string "unified:tools=") updated.last_proactive_reason 0); true
       with Not_found -> false
     in found)

let test_normalize_response_text_passthrough () =
  match KAR.normalize_response_text ~text:"All good." ~tool_names:[] with
  | Ok text -> check string "keeps text" "All good." text
  | Error e -> fail ("unexpected error: " ^ e)

let test_normalize_response_text_tool_only_synthesizes () =
  match KAR.normalize_response_text
          ~text:""
          ~tool_names:["keeper_board_post"; "keeper_board_comment"]
  with
  | Ok text ->
      check bool "mentions no textual reply" true
        (String.length text > 0
         && String.contains text 'T');
      check bool "mentions first tool" true
        (let found =
           try
             ignore
               (Str.search_forward
                  (Str.regexp_string "keeper_board_post")
                  text 0);
             true
           with Not_found -> false
         in
         found)
  | Error e -> fail ("unexpected error: " ^ e)

let test_normalize_response_text_empty_without_tools_errors () =
  match KAR.normalize_response_text ~text:"" ~tool_names:[] with
  | Ok text -> fail ("expected error, got: " ^ text)
  | Error e ->
      check bool "error mentions textual reply" true
        (let found =
           try
             ignore
               (Str.search_forward
                  (Str.regexp_string "no textual reply")
                  e 0);
             true
           with Not_found -> false
         in
         found)

(* ---------- Test runner ---------- *)

let () =
  run "Keeper Unified Turn"
    [
      ( "world_observation",
        [
          test_case "defaults" `Quick test_observation_defaults;
          test_case "with mentions" `Quick test_observation_with_mentions;
          test_case "with goals" `Quick test_observation_with_goals;
          test_case "autonomy levels" `Quick test_observation_autonomy_levels;
          test_case "economic modes" `Quick test_observation_economic_modes;
        ] );
      ( "unified_prompt",
        [
          test_case "contains identity" `Quick test_prompt_contains_identity;
          test_case "contains goal" `Quick test_prompt_contains_goal;
          test_case "omits empty sections" `Quick test_prompt_omits_empty_sections;
          test_case "includes mentions" `Quick test_prompt_includes_mentions_section;
          test_case "includes goals" `Quick test_prompt_includes_goals_section;
          test_case "includes context ratio" `Quick test_prompt_includes_context_ratio;
          test_case "includes idle" `Quick test_prompt_includes_idle;
          test_case "frugal economy" `Quick test_prompt_frugal_economy;
          test_case "hustle economy" `Quick test_prompt_hustle_economy;
          test_case "includes triage triggers" `Quick test_prompt_includes_triage_triggers;
          test_case "skips skip triage" `Quick test_prompt_skips_skip_triage;
          test_case "room state section" `Quick test_prompt_room_state_section;
          test_case "autonomy description" `Quick test_prompt_autonomy_description;
        ] );
      ( "hooks_autonomy_filter",
        [
          test_case "L1 allowed tools" `Quick test_hooks_allowed_tools_l1;
          test_case "L4 allowed tools" `Quick test_hooks_allowed_tools_l4;
          test_case "L5 allow all" `Quick test_hooks_allowed_tools_l5;
        ] );
      ( "config",
        [
          test_case "unified runtime defaults" `Quick
            test_unified_turn_runtime_defaults;
        ] );
      ( "metrics_observation",
        [
          test_case "text response" `Quick test_metrics_text_response;
          test_case "tool response" `Quick test_metrics_tool_response;
          test_case "noop response" `Quick test_metrics_noop_response;
          test_case "mixed response" `Quick test_metrics_mixed_response;
          test_case "normalize passthrough" `Quick
            test_normalize_response_text_passthrough;
          test_case "normalize tool only synthesizes" `Quick
            test_normalize_response_text_tool_only_synthesizes;
          test_case "normalize empty without tools errors" `Quick
            test_normalize_response_text_empty_without_tools_errors;
        ] );
    ]
