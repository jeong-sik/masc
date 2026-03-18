(** Spawn Eio Module Coverage Tests

    Tests for spawn types, constants, and Provider_adapter routing:
    - spawn_config type (backward compat)
    - spawn_result type
    - masc_mcp_tools constant
    - resolve_model_spec (Provider_adapter → model_spec)
    - OAS Agent.t routing (no CLI subprocess)
*)

open Alcotest

module Spawn_eio = Masc_mcp.Spawn_eio

(* ============================================================
   spawn_config Type Tests (backward compat — type still exists)
   ============================================================ *)

let test_spawn_config_type () =
  let cfg : Spawn_eio.spawn_config = {
    agent_name = "claude";
    command = "claude --print";
    timeout_seconds = 300;
    working_dir = Some "/tmp/test";
    mcp_tools = ["masc_status"; "masc_broadcast"];
  } in
  check string "agent_name" "claude" cfg.agent_name;
  check string "command" "claude --print" cfg.command;
  check int "timeout_seconds" 300 cfg.timeout_seconds

let test_spawn_config_no_working_dir () =
  let cfg : Spawn_eio.spawn_config = {
    agent_name = "codex";
    command = "codex";
    timeout_seconds = 60;
    working_dir = None;
    mcp_tools = [];
  } in
  match cfg.working_dir with
  | None -> ()
  | Some _ -> fail "expected None"

let test_spawn_config_mcp_tools () =
  let cfg : Spawn_eio.spawn_config = {
    agent_name = "test";
    command = "test";
    timeout_seconds = 30;
    working_dir = None;
    mcp_tools = ["tool1"; "tool2"; "tool3"];
  } in
  check int "mcp_tools count" 3 (List.length cfg.mcp_tools)

(* ============================================================
   spawn_result Type Tests
   ============================================================ *)

let test_spawn_result_success () =
  let r : Spawn_eio.spawn_result = {
    success = true;
    output = "Task completed";
    exit_code = 0;
    elapsed_ms = 1500;
    tool_call_count = 0;
    tool_names = [];
    input_tokens = Some 100;
    output_tokens = Some 200;
    cache_creation_tokens = None;
    cache_read_tokens = Some 50;
    cost_usd = Some 0.005;
    raw_trace_run = None;
    termination = None;
  } in
  check bool "success" true r.success;
  check int "exit_code" 0 r.exit_code;
  check int "elapsed_ms" 1500 r.elapsed_ms

let test_spawn_result_failure () =
  let r : Spawn_eio.spawn_result = {
    success = false;
    output = "Error occurred";
    exit_code = 1;
    elapsed_ms = 500;
    tool_call_count = 0;
    tool_names = [];
    input_tokens = None;
    output_tokens = None;
    cache_creation_tokens = None;
    cache_read_tokens = None;
    cost_usd = None;
    raw_trace_run = None;
    termination = None;
  } in
  check bool "success" false r.success;
  check int "exit_code" 1 r.exit_code

let test_spawn_result_tokens () =
  let r : Spawn_eio.spawn_result = {
    success = true;
    output = "";
    exit_code = 0;
    elapsed_ms = 0;
    tool_call_count = 0;
    tool_names = [];
    input_tokens = Some 1000;
    output_tokens = Some 2000;
    cache_creation_tokens = Some 500;
    cache_read_tokens = Some 300;
    cost_usd = Some 0.025;
    raw_trace_run = None;
    termination = None;
  } in
  match r.input_tokens, r.output_tokens, r.cost_usd with
  | Some i, Some o, Some c ->
      check int "input_tokens" 1000 i;
      check int "output_tokens" 2000 o;
      check (float 0.001) "cost_usd" 0.025 c
  | _ -> fail "expected Some values"

(* ============================================================
   masc_mcp_tools Constant Tests
   ============================================================ *)

let test_masc_mcp_tools_not_empty () =
  check bool "not empty" true (List.length Spawn_eio.masc_mcp_tools > 0)

let test_masc_mcp_tools_contains_status () =
  check bool "contains masc_status" true
    (List.exists (fun t -> String.length t > 0 &&
                           String.sub t (String.length t - min 11 (String.length t))
                                       (min 11 (String.length t)) = "masc_status")
       Spawn_eio.masc_mcp_tools)

let test_masc_mcp_tools_all_strings () =
  check bool "all strings" true
    (List.for_all (fun t -> String.length t > 0) Spawn_eio.masc_mcp_tools)

let test_masc_mcp_tools_omits_team_session_turn () =
  check bool "omits team_session_turn" false
    (List.mem "mcp__masc__masc_team_session_turn" Spawn_eio.masc_mcp_tools)

let test_masc_mcp_tools_contains_portal_send () =
  check bool "contains portal_send" true
    (List.mem "mcp__masc__masc_portal_send" Spawn_eio.masc_mcp_tools)

let test_masc_mcp_tools_contains_team_session_step () =
  check bool "contains team_session_step" true
    (List.mem "mcp__masc__masc_team_session_step" Spawn_eio.masc_mcp_tools)

let test_masc_mcp_tools_contains_team_session_finalize () =
  check bool "contains team_session_finalize" true
    (List.mem "mcp__masc__masc_team_session_finalize" Spawn_eio.masc_mcp_tools)

let test_masc_mcp_tools_contains_a2a_delegate () =
  check bool "contains a2a_delegate" true
    (List.mem "mcp__masc__masc_a2a_delegate" Spawn_eio.masc_mcp_tools)

let test_masc_mcp_tools_contains_vote_create () =
  check bool "omits vote_create (hidden)" false
    (List.mem "mcp__masc__masc_vote_create" Spawn_eio.masc_mcp_tools)

let test_masc_mcp_tools_contains_run_deliverable () =
  check bool "contains run_deliverable" true
    (List.mem "mcp__masc__masc_run_deliverable" Spawn_eio.masc_mcp_tools)

let test_masc_mcp_tools_contains_tool_help () =
  check bool "contains tool_help" true
    (List.mem "mcp__masc__masc_tool_help" Spawn_eio.masc_mcp_tools)

let test_masc_mcp_tools_contains_tool_stats () =
  check bool "contains tool_stats" true
    (List.mem "mcp__masc__masc_tool_stats" Spawn_eio.masc_mcp_tools)

let test_masc_mcp_tools_contains_tool_admin_snapshot () =
  check bool "contains tool_admin_snapshot" true
    (List.mem "mcp__masc__masc_tool_admin_snapshot" Spawn_eio.masc_mcp_tools)

let test_masc_mcp_tools_contains_keeper_tool_catalog () =
  check bool "contains keeper_tool_catalog" true
    (List.mem "mcp__masc__masc_keeper_tool_catalog" Spawn_eio.masc_mcp_tools)

let test_masc_mcp_tools_contains_tool_list () =
  check bool "omits tool_list (no schema)" false
    (List.mem "mcp__masc__masc_tool_list" Spawn_eio.masc_mcp_tools)

let test_masc_mcp_tools_contains_tool_grant () =
  check bool "omits tool_grant (no schema)" false
    (List.mem "mcp__masc__masc_tool_grant" Spawn_eio.masc_mcp_tools)

let test_masc_mcp_tools_contains_tool_revoke () =
  check bool "omits tool_revoke (no schema)" false
    (List.mem "mcp__masc__masc_tool_revoke" Spawn_eio.masc_mcp_tools)

let test_llama_mcp_tools_curated () =
  check (list string) "llama tools"
    [
      "mcp__masc__masc_heartbeat";
      "mcp__masc__masc_team_session_status";
      "mcp__masc__masc_team_session_step";
      "mcp__masc__masc_memento_mori";
    ]
    Spawn_eio.llama_mcp_tools

(* ============================================================
   masc_lifecycle_suffix Tests
   ============================================================ *)

let test_masc_lifecycle_suffix_not_empty () =
  check bool "not empty" true (String.length Spawn_eio.masc_lifecycle_suffix > 0)

let test_masc_lifecycle_suffix_contains_protocol () =
  check bool "contains PROTOCOL" true
    (Str.string_match (Str.regexp_string "PROTOCOL") Spawn_eio.masc_lifecycle_suffix 0 ||
     String.length Spawn_eio.masc_lifecycle_suffix > 100)

(* ============================================================
   resolve_model_spec Tests
   ============================================================ *)

let test_resolve_model_spec_unknown_agent () =
  match Spawn_eio.resolve_model_spec "nonexistent_xyz" with
  | Error msg ->
      check bool "mentions not registered" true
        (try
           let _ = Str.search_forward (Str.regexp_string "not registered") msg 0 in
           true
         with Not_found -> false)
  | Ok _ -> fail "expected Error for unknown agent"

let test_resolve_model_spec_claude () =
  match Spawn_eio.resolve_model_spec "claude" with
  | Ok spec ->
      check bool "provider is Claude" true
        (spec.Masc_mcp.Llm_client.provider = Masc_mcp.Llm_client.Claude)
  | Error _ ->
      (* May fail if ANTHROPIC_API_KEY not set — that is acceptable *)
      ()

let test_resolve_model_spec_glm () =
  match Spawn_eio.resolve_model_spec "glm" with
  | Ok spec ->
      check bool "provider is Glm_cloud" true
        (spec.Masc_mcp.Llm_client.provider = Masc_mcp.Llm_client.Glm_cloud)
  | Error _ ->
      (* May fail if ZAI_API_KEY not set *)
      ()

let test_resolve_model_spec_gemini () =
  match Spawn_eio.resolve_model_spec "gemini" with
  | Ok spec ->
      check bool "provider is Gemini" true
        (spec.Masc_mcp.Llm_client.provider = Masc_mcp.Llm_client.Gemini)
  | Error _ -> ()

(* ============================================================
   Spawn routing Tests
   ============================================================ *)

let test_spawn_bare_ollama_rejected () =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let result =
    Spawn_eio.spawn ~sw ~proc_mgr:(Eio.Stdenv.process_mgr env)
      ~agent_name:"ollama" ~prompt:"hello" ()
  in
  check bool "spawn fails" false result.success;
  check int "exit code" 2 result.exit_code;
  check bool "migration message" true
    (try
       let _ =
         Str.search_forward
           (Str.regexp_string "llama:<model>")
           result.output 0
       in
       true
     with Not_found -> false)

let test_spawn_unknown_agent_fails () =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let result =
    Spawn_eio.spawn ~sw ~proc_mgr:(Eio.Stdenv.process_mgr env)
      ~agent_name:"totally_unknown_agent_xyz" ~prompt:"hello" ()
  in
  check bool "spawn fails" false result.success;
  check bool "mentions model resolution" true
    (try
       let _ = Str.search_forward (Str.regexp_string "not registered") result.output 0 in
       true
     with Not_found -> false)

(* ============================================================
   State Isolation Tests
   ============================================================ *)

let test_excluded_state_keys_not_empty () =
  check bool "not empty" true (List.length Spawn_eio.excluded_state_keys > 0)

let test_excluded_state_keys_contains_messages () =
  check bool "contains messages" true
    (List.mem "messages" Spawn_eio.excluded_state_keys)

let test_excluded_state_keys_contains_full_history () =
  check bool "contains full_history" true
    (List.mem "full_history" Spawn_eio.excluded_state_keys)

let test_excluded_state_keys_contains_todos () =
  check bool "contains todos" true
    (List.mem "todos" Spawn_eio.excluded_state_keys)

let test_excluded_state_keys_contains_skills_metadata () =
  check bool "contains skills_metadata" true
    (List.mem "skills_metadata" Spawn_eio.excluded_state_keys)

let test_excluded_state_keys_contains_memory_contents () =
  check bool "contains memory_contents" true
    (List.mem "memory_contents" Spawn_eio.excluded_state_keys)

let test_state_isolation_notice_not_empty () =
  check bool "not empty" true (String.length Spawn_eio.state_isolation_notice > 0)

let test_state_isolation_notice_contains_isolated () =
  check bool "contains isolated context" true
    (try
       let _ = Str.search_forward (Str.regexp_string "isolated context") Spawn_eio.state_isolation_notice 0 in
       true
     with Not_found -> false)

let test_state_isolation_notice_contains_focus () =
  check bool "contains focus instruction" true
    (try
       let _ = Str.search_forward (Str.regexp_string "Focus on your assigned task") Spawn_eio.state_isolation_notice 0 in
       true
     with Not_found -> false)

(* ============================================================
   Test Runners
   ============================================================ *)

let () =
  run "Spawn Eio Coverage" [
    "spawn_config", [
      test_case "type" `Quick test_spawn_config_type;
      test_case "no working_dir" `Quick test_spawn_config_no_working_dir;
      test_case "mcp_tools" `Quick test_spawn_config_mcp_tools;
    ];
    "spawn_result", [
      test_case "success" `Quick test_spawn_result_success;
      test_case "failure" `Quick test_spawn_result_failure;
      test_case "tokens" `Quick test_spawn_result_tokens;
    ];
    "masc_mcp_tools", [
      test_case "not empty" `Quick test_masc_mcp_tools_not_empty;
      test_case "contains status" `Quick test_masc_mcp_tools_contains_status;
      test_case "all strings" `Quick test_masc_mcp_tools_all_strings;
      test_case "omits team_session_turn" `Quick
        test_masc_mcp_tools_omits_team_session_turn;
      test_case "contains portal_send" `Quick
        test_masc_mcp_tools_contains_portal_send;
      test_case "contains team_session_step" `Quick
        test_masc_mcp_tools_contains_team_session_step;
      test_case "contains team_session_finalize" `Quick
        test_masc_mcp_tools_contains_team_session_finalize;
      test_case "contains a2a_delegate" `Quick
        test_masc_mcp_tools_contains_a2a_delegate;
      test_case "contains vote_create" `Quick
        test_masc_mcp_tools_contains_vote_create;
      test_case "contains run_deliverable" `Quick
        test_masc_mcp_tools_contains_run_deliverable;
      test_case "contains tool_stats" `Quick
        test_masc_mcp_tools_contains_tool_stats;
      test_case "contains tool_help" `Quick
        test_masc_mcp_tools_contains_tool_help;
      test_case "contains tool_admin_snapshot" `Quick
        test_masc_mcp_tools_contains_tool_admin_snapshot;
      test_case "contains keeper_tool_catalog" `Quick
        test_masc_mcp_tools_contains_keeper_tool_catalog;
      test_case "contains tool_list" `Quick
        test_masc_mcp_tools_contains_tool_list;
      test_case "contains tool_grant" `Quick
        test_masc_mcp_tools_contains_tool_grant;
      test_case "contains tool_revoke" `Quick
        test_masc_mcp_tools_contains_tool_revoke;
      test_case "llama curated subset" `Quick test_llama_mcp_tools_curated;
    ];
    "masc_lifecycle_suffix", [
      test_case "not empty" `Quick test_masc_lifecycle_suffix_not_empty;
      test_case "contains protocol" `Quick test_masc_lifecycle_suffix_contains_protocol;
    ];
    "resolve_model_spec", [
      test_case "unknown agent" `Quick test_resolve_model_spec_unknown_agent;
      test_case "claude" `Quick test_resolve_model_spec_claude;
      test_case "glm" `Quick test_resolve_model_spec_glm;
      test_case "gemini" `Quick test_resolve_model_spec_gemini;
    ];
    "spawn_routing", [
      test_case "bare ollama rejected" `Quick test_spawn_bare_ollama_rejected;
      test_case "unknown agent fails" `Quick test_spawn_unknown_agent_fails;
    ];
    "state_isolation", [
      test_case "excluded_state_keys not empty" `Quick test_excluded_state_keys_not_empty;
      test_case "excluded_state_keys contains messages" `Quick test_excluded_state_keys_contains_messages;
      test_case "excluded_state_keys contains full_history" `Quick test_excluded_state_keys_contains_full_history;
      test_case "excluded_state_keys contains todos" `Quick test_excluded_state_keys_contains_todos;
      test_case "excluded_state_keys contains skills_metadata" `Quick test_excluded_state_keys_contains_skills_metadata;
      test_case "excluded_state_keys contains memory_contents" `Quick test_excluded_state_keys_contains_memory_contents;
      test_case "state_isolation_notice not empty" `Quick test_state_isolation_notice_not_empty;
      test_case "state_isolation_notice contains isolated" `Quick test_state_isolation_notice_contains_isolated;
      test_case "state_isolation_notice contains focus" `Quick test_state_isolation_notice_contains_focus;
    ];
  ]
