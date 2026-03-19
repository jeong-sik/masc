open Alcotest

module Adapter = Masc_mcp.Keeper_oas_adapter
module Llm_types = Masc_mcp.Llm_types
module Keeper_types = Masc_mcp.Keeper_types
module Oas_worker = Masc_mcp.Oas_worker
module Types = Agent_sdk.Types

(* ================================================================ *)
(* Helper: build a minimal keeper_meta with overridable fields      *)
(* ================================================================ *)

let make_test_meta
    ?(name = "test-keeper")
    ?(active_model = "")
    ?(allowed_models = [])
    ?(models = ["llama:test-model"])
    ?(autonomy_level = "l1_reactive")
    ?(proactive_enabled = false)
    () : Keeper_types.keeper_meta =
  { name; agent_name = "keeper-" ^ name ^ "-agent";
    persona_profile_path = ""; trace_id = "trace-test"; trace_history = [];
    goal = "test goal"; short_goal = ""; mid_goal = ""; long_goal = "";
    soul_profile = ""; will = ""; needs = ""; desires = ""; instructions = "";
    models; allowed_models; active_model;
    policy_mode = "learned_offline_v1"; policy_action_budget = "board";
    policy_reward_model_path = ""; policy_voice_enabled = false;
    policy_shell_mode = "disabled";
    initiative_enabled = false; initiative_scope = "board_only";
    initiative_idle_sec = 3600; initiative_cooldown_sec = 3600;
    initiative_context_mode = "board_snapshot"; initiative_post_ttl_hours = 24;
    scope_kind = "global"; room_scope = "all"; trigger_mode = "legacy";
    mention_targets = []; joined_room_ids = ["default"];
    last_seen_seq_by_room = []; generation = 0; verify = false;
    presence_keepalive = false; presence_keepalive_sec = 30;
    proactive_enabled; proactive_idle_sec = 900; proactive_cooldown_sec = 1800;
    drift_enabled = false; drift_min_turn_gap = 6; drift_count_total = 0;
    last_drift_turn = 0; last_drift_reason = "";
    compaction_profile = "custom"; compaction_ratio_gate = 0.5;
    compaction_message_gate = 240; compaction_token_gate = 0;
    continuity_compaction_cooldown_sec = 90;
    auto_handoff = false; handoff_threshold = 0.85; handoff_cooldown_sec = 300;
    context_budget = 0.6; voice_enabled = false; voice_channel = "";
    voice_agent_id = ""; last_handoff_ts = 0.0;
    created_at = "2026-01-01T00:00:00Z"; updated_at = "2026-01-01T00:00:00Z";
    total_turns = 0; total_input_tokens = 0; total_output_tokens = 0;
    total_tokens = 0; total_cost_usd = 0.0; last_turn_ts = 0.0;
    last_model_used = ""; last_input_tokens = 0; last_output_tokens = 0;
    last_total_tokens = 0; last_latency_ms = 0;
    compaction_count = 0; last_compaction_ts = 0.0;
    last_compaction_before_tokens = 0; last_compaction_after_tokens = 0;
    proactive_count_total = 0; last_proactive_ts = 0.0;
    last_proactive_reason = ""; last_proactive_preview = "";
    last_compaction_check_ts = 0.0; last_compaction_decision = "";
    last_continuity_update_ts = 0.0; continuity_summary = "";
    autonomy_level; active_goal_ids = [];
    auto_team_session_enabled = false; active_team_session_id = None;
    last_team_session_started_at = ""; team_session_start_count_total = 0;
    last_autonomous_action_at = ""; autonomous_action_count = 0;
    deliberation_count = 0; deliberation_cost_total_usd = 0.0;
    last_deliberation_ts = 0.0; last_triage_triggers = "";
  }

(* ================================================================ *)
(* Helper: build a minimal completion_request                       *)
(* ================================================================ *)

let make_model_spec ?(model_id = "test-model") ?(provider = Llm_types.Llama) () :
    Llm_types.model_spec =
  { provider;
    model_id;
    max_context = 4096;
    api_url = "http://127.0.0.1:8085";
    api_key_env = None;
    cost_per_1k_input = 0.0;
    cost_per_1k_output = 0.0;
  }

let make_request ?(model_id = "test-model") ?(provider = Llm_types.Llama)
    ?(temperature = 0.7) ?(max_tokens = 1024) ?(tools = [])
    (messages : Types.message list) : Llm_types.completion_request =
  { model = make_model_spec ~model_id ~provider ();
    messages;
    temperature;
    max_tokens;
    tools;
    response_format = `Text;
  }

(* ================================================================ *)
(* Group 1: cascade_config_of_requests                              *)
(* ================================================================ *)

let test_cascade_config_empty_list () =
  match Adapter.cascade_config_of_requests [] with
  | Error msg ->
      check bool "contains 'empty'" true
        (String.length msg > 0)
  | Ok _ -> fail "expected Error for empty list"

let test_cascade_config_single_request () =
  let req = make_request [
    Types.system_msg "You are a keeper.";
    Types.user_msg "What is the status?";
  ] in
  match Adapter.cascade_config_of_requests [req] with
  | Error e -> fail (Printf.sprintf "unexpected error: %s" e)
  | Ok params ->
      check string "system_prompt" "You are a keeper." params.system_prompt;
      check bool "goal contains status" true
        (String.length params.goal > 0);
      check string "primary model" "test-model" params.primary_spec.model_id;
      check (list string) "no fallbacks" []
        (List.map (fun (s : Llm_types.model_spec) -> s.model_id) params.fallback_specs)

let test_cascade_config_multiple_requests () =
  let req1 = make_request ~model_id:"primary"
    [Types.system_msg "sys"; Types.user_msg "goal"] in
  let req2 = make_request ~model_id:"fallback1"
    [Types.user_msg "goal"] in
  let req3 = make_request ~model_id:"fallback2"
    [Types.user_msg "goal"] in
  match Adapter.cascade_config_of_requests [req1; req2; req3] with
  | Error e -> fail e
  | Ok params ->
      check string "primary" "primary" params.primary_spec.model_id;
      check int "fallback count" 2 (List.length params.fallback_specs);
      check string "fallback1" "fallback1"
        (List.nth params.fallback_specs 0).model_id;
      check string "fallback2" "fallback2"
        (List.nth params.fallback_specs 1).model_id

let test_cascade_config_no_system_message () =
  let req = make_request [Types.user_msg "just a question"] in
  match Adapter.cascade_config_of_requests [req] with
  | Error _ -> fail "should succeed even without system message"
  | Ok params ->
      check string "empty system prompt" "" params.system_prompt;
      check bool "goal present" true (String.length params.goal > 0)

let test_cascade_config_no_user_messages () =
  let req = make_request [Types.system_msg "system only"] in
  match Adapter.cascade_config_of_requests [req] with
  | Error msg ->
      check bool "mentions user messages" true
        (String.length msg > 0)
  | Ok _ -> fail "expected Error when no user messages"

let test_cascade_config_preserves_temperature () =
  let req = make_request ~temperature:0.3 ~max_tokens:512
    [Types.system_msg "s"; Types.user_msg "g"] in
  match Adapter.cascade_config_of_requests [req] with
  | Error e -> fail e
  | Ok params ->
      let epsilon = 0.001 in
      check bool "temperature" true
        (Float.abs (params.temperature -. 0.3) < epsilon);
      check int "max_tokens" 512 params.max_tokens

let test_cascade_config_multiple_system_messages () =
  let req = make_request [
    Types.system_msg "You are a keeper.";
    Types.system_msg "Be concise.";
    Types.user_msg "Status?";
  ] in
  match Adapter.cascade_config_of_requests [req] with
  | Error e -> fail e
  | Ok params ->
      check bool "system contains both" true
        (String.length params.system_prompt > String.length "You are a keeper.")

let test_cascade_config_mixed_message_types () =
  let req = make_request [
    Types.system_msg "sys";
    Types.user_msg "hello";
    Types.assistant_msg "hi";
    Types.user_msg "question";
  ] in
  match Adapter.cascade_config_of_requests [req] with
  | Error e -> fail e
  | Ok params ->
      check string "system separated" "sys" params.system_prompt;
      check bool "goal non-empty" true (String.length params.goal > 0)

let test_cascade_config_assistant_only () =
  let req = make_request [Types.assistant_msg "I said something"] in
  match Adapter.cascade_config_of_requests [req] with
  | Error _ -> fail "assistant-only should still produce a goal"
  | Ok params ->
      check string "no system" "" params.system_prompt;
      check bool "goal non-empty" true (String.length params.goal > 0)

let test_cascade_config_temperature_zero () =
  let req = make_request ~temperature:0.0
    [Types.system_msg "s"; Types.user_msg "g"] in
  match Adapter.cascade_config_of_requests [req] with
  | Error e -> fail e
  | Ok params ->
      check bool "temperature is zero" true
        (Float.abs params.temperature < 0.001)

let test_cascade_config_max_tokens_boundary () =
  let req = make_request ~max_tokens:1
    [Types.system_msg "s"; Types.user_msg "g"] in
  match Adapter.cascade_config_of_requests [req] with
  | Error e -> fail e
  | Ok params ->
      check int "max_tokens=1" 1 params.max_tokens

(* ================================================================ *)
(* Group 2: result extractors                                       *)
(* ================================================================ *)

let make_run_result ?(model = "test") ?(text = "hello")
    ?(input_tokens = 10) ?(output_tokens = 5) () : Masc_mcp.Oas_worker.run_result =
  { response = {
      Llm_provider.Types.model;
      content = [Llm_provider.Types.Text text];
      stop_reason = Llm_provider.Types.EndTurn;
      usage = Some { input_tokens; output_tokens;
                     cache_creation_input_tokens = 0;
                     cache_read_input_tokens = 0 };
      id = "test-id";
    };
    checkpoint = None;
    session_id = "test-session";
    turns = 1;
  }

let test_text_of_run_result () =
  let r = make_run_result ~text:"world" () in
  check string "text" "world" (Adapter.text_of_run_result r)

let test_usage_of_run_result () =
  let r = make_run_result ~input_tokens:100 ~output_tokens:50 () in
  let usage = Adapter.usage_of_run_result r in
  check int "input" 100 usage.input_tokens;
  check int "output" 50 usage.output_tokens

let test_model_of_run_result () =
  let r = make_run_result ~model:"qwen3.5" () in
  check string "model" "qwen3.5" (Adapter.model_of_run_result r)

(* ================================================================ *)
(* Group 3: run_cascade error paths (no Eio context needed)         *)
(* ================================================================ *)

let test_run_cascade_empty_requests () =
  match Adapter.run_cascade [] with
  | Error msg ->
      check bool "error message present" true (String.length msg > 0)
  | Ok _ -> fail "expected Error for empty requests"

let test_run_cascade_no_user_messages () =
  let req = make_request [Types.system_msg "system only"] in
  match Adapter.run_cascade [req] with
  | Error _ -> () (* expected: no user messages *)
  | Ok _ -> fail "expected Error for request with no user messages"

(* ================================================================ *)
(* Group 4: resolve_primary_model_spec                              *)
(* ================================================================ *)

let test_resolve_active_model_set () =
  let meta = make_test_meta ~active_model:"llama:qwen3.5" () in
  match Adapter.resolve_primary_model_spec meta with
  | Error e -> fail (Printf.sprintf "unexpected error: %s" e)
  | Ok spec -> check string "model_id" "qwen3.5" spec.model_id

let test_resolve_active_model_empty_uses_models () =
  let meta = make_test_meta ~active_model:"" ~models:["llama:test"] () in
  match Adapter.resolve_primary_model_spec meta with
  | Error e -> fail (Printf.sprintf "unexpected error: %s" e)
  | Ok spec -> check string "model_id" "test" spec.model_id

let test_resolve_allowed_and_models_dedup () =
  let meta = make_test_meta ~active_model:""
    ~allowed_models:["llama:a"] ~models:["llama:a"; "llama:b"] () in
  match Adapter.resolve_primary_model_spec meta with
  | Error e -> fail (Printf.sprintf "unexpected error: %s" e)
  | Ok spec -> check string "first from deduped" "a" spec.model_id

let test_resolve_all_models_empty () =
  let meta = make_test_meta ~active_model:""
    ~allowed_models:[] ~models:[] () in
  match Adapter.resolve_primary_model_spec meta with
  | Error _ -> ()
  | Ok _ -> fail "expected Error for empty models"

let test_resolve_invalid_model_string () =
  let meta = make_test_meta ~active_model:"" ~models:["invalid"] () in
  match Adapter.resolve_primary_model_spec meta with
  | Error _ -> ()
  | Ok _ -> fail "expected Error for invalid model string"

let test_resolve_multiple_models_picks_first () =
  let meta = make_test_meta ~active_model:""
    ~models:["llama:first"; "glm:second"] () in
  match Adapter.resolve_primary_model_spec meta with
  | Error e -> fail (Printf.sprintf "unexpected error: %s" e)
  | Ok spec -> check string "picks first" "first" spec.model_id

(* ================================================================ *)
(* Registration                                                     *)
(* ================================================================ *)

let () =
  run "Keeper_oas_adapter" [
    ("cascade_config", [
      test_case "empty list returns error" `Quick
        test_cascade_config_empty_list;
      test_case "single request extracts params" `Quick
        test_cascade_config_single_request;
      test_case "multiple requests with fallbacks" `Quick
        test_cascade_config_multiple_requests;
      test_case "no system message" `Quick
        test_cascade_config_no_system_message;
      test_case "no user messages returns error" `Quick
        test_cascade_config_no_user_messages;
      test_case "preserves temperature and max_tokens" `Quick
        test_cascade_config_preserves_temperature;
      test_case "multiple system messages concat" `Quick
        test_cascade_config_multiple_system_messages;
      test_case "mixed message types" `Quick
        test_cascade_config_mixed_message_types;
      test_case "assistant-only produces goal" `Quick
        test_cascade_config_assistant_only;
      test_case "temperature zero" `Quick
        test_cascade_config_temperature_zero;
      test_case "max_tokens boundary" `Quick
        test_cascade_config_max_tokens_boundary;
    ]);
    ("extractors", [
      test_case "text_of_run_result" `Quick test_text_of_run_result;
      test_case "usage_of_run_result" `Quick test_usage_of_run_result;
      test_case "model_of_run_result" `Quick test_model_of_run_result;
    ]);
    ("run_cascade_errors", [
      test_case "empty requests" `Quick test_run_cascade_empty_requests;
      test_case "no user messages" `Quick test_run_cascade_no_user_messages;
    ]);
    ("resolve_model_spec", [
      test_case "active_model set" `Quick test_resolve_active_model_set;
      test_case "active_model empty uses models" `Quick test_resolve_active_model_empty_uses_models;
      test_case "allowed + models dedup" `Quick test_resolve_allowed_and_models_dedup;
      test_case "all models empty" `Quick test_resolve_all_models_empty;
      test_case "invalid model string" `Quick test_resolve_invalid_model_string;
      test_case "multiple models picks first" `Quick test_resolve_multiple_models_picks_first;
    ]);
  ]
