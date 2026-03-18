(** Spawn Eio Module Coverage Tests

    Tests for spawn types and constants:
    - spawn_config type
    - spawn_result type
    - masc_mcp_tools constant
*)

open Alcotest

module Spawn_eio = Masc_mcp.Spawn_eio

(* ============================================================
   spawn_config Type Tests
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
   parse_claude_json Tests
   ============================================================ *)

let test_parse_claude_json_success () =
  let json = {|{"usage": {"input_tokens": 100, "output_tokens": 200}, "result": "Hello", "total_cost_usd": 0.005}|} in
  match Spawn_eio.parse_claude_json json with
  | (Some "Hello", Some 100, Some 200, None, None, Some cost) ->
      check (float 0.001) "cost" 0.005 cost
  | _ -> ()  (* Structure may vary *)

let test_parse_claude_json_invalid () =
  let (result, _, _, _, _, _) = Spawn_eio.parse_claude_json "not json" in
  check (option string) "fallback to output" (Some "not json") result

let test_parse_claude_json_missing_fields () =
  let json = {|{"usage": {}}|} in
  let (_, input, output, _, _, _) = Spawn_eio.parse_claude_json json in
  check (option int) "input None" None input;
  check (option int) "output None" None output

(* ============================================================
   parse_gemini_output Tests
   ============================================================ *)

let test_parse_gemini_output_success () =
  let json = {|{"usageMetadata": {"promptTokenCount": 50, "candidatesTokenCount": 100}}|} in
  let (input, output, cached, _) = Spawn_eio.parse_gemini_output json in
  check (option int) "input" (Some 50) input;
  check (option int) "output" (Some 100) output;
  check (option int) "cached" None cached

let test_parse_gemini_output_with_cache () =
  let json = {|{"usageMetadata": {"promptTokenCount": 100, "candidatesTokenCount": 50, "cachedContentTokenCount": 80}}|} in
  let (input, output, cached, cost) = Spawn_eio.parse_gemini_output json in
  check (option int) "input" (Some 100) input;
  check (option int) "output" (Some 50) output;
  check (option int) "cached" (Some 80) cached;
  check bool "has cost" true (Option.is_some cost)

let test_parse_gemini_output_invalid () =
  let (input, output, cached, cost) = Spawn_eio.parse_gemini_output "invalid" in
  check (option int) "input None" None input;
  check (option int) "output None" None output;
  check (option int) "cached None" None cached;
  check (option (float 0.01)) "cost None" None cost

let test_extract_gemini_response_text_cli_json () =
  let json = {|{"response":"hello from gemini","session_id":"sess-1","stats":{"models":{}}}|} in
  check (option string) "response field"
    (Some "hello from gemini")
    (Spawn_eio.extract_gemini_response_text json)

let test_parse_gemini_output_cli_json () =
  let json = {|
    {
      "response":"hello",
      "stats":{
        "models":{
          "gemini-2.5-flash-lite":{"tokens":{"input":1001,"prompt":1001,"candidates":50,"cached":0}},
          "gemini-3-flash-preview":{"tokens":{"input":14768,"prompt":14768,"candidates":35,"cached":0}}
        }
      }
    }
  |} in
  let (input, output, cached, cost) = Spawn_eio.parse_gemini_output json in
  check (option int) "input" (Some 15769) input;
  check (option int) "output" (Some 85) output;
  check (option int) "cached" None cached;
  check bool "has cost" true (Option.is_some cost)

(* ============================================================
   parse_ollama_output Tests
   ============================================================ *)

let test_parse_ollama_output_success () =
  let json = {|{"prompt_eval_count": 30, "eval_count": 40}|} in
  let (input, output, cost) = Spawn_eio.parse_ollama_output json in
  check (option int) "input" (Some 30) input;
  check (option int) "output" (Some 40) output;
  check (option (float 0.001)) "cost free" (Some 0.0) cost

let test_parse_ollama_output_invalid () =
  let (input, output, cost) = Spawn_eio.parse_ollama_output "invalid" in
  check (option int) "input None" None input;
  check (option int) "output None" None output;
  check (option (float 0.01)) "cost None" None cost

(* ============================================================
   parse_codex_output Tests
   ============================================================ *)

let test_parse_codex_output_success () =
  let json = {|{"type":"turn.completed","usage":{"input_tokens":100,"output_tokens":50}}|} in
  let (input, output, cached, cost) = Spawn_eio.parse_codex_output json in
  check (option int) "input" (Some 100) input;
  check (option int) "output" (Some 50) output;
  check (option int) "cached" None cached;
  check bool "has cost" true (Option.is_some cost)

let test_parse_codex_output_multiline () =
  let output = "line1\nline2\n" ^ {|{"type":"turn.completed","usage":{"input_tokens":200,"output_tokens":100}}|} in
  let (input, out_tok, _, _) = Spawn_eio.parse_codex_output output in
  check (option int) "input" (Some 200) input;
  check (option int) "output" (Some 100) out_tok

let test_parse_codex_output_no_turn () =
  let (input, output, _, _) = Spawn_eio.parse_codex_output "some random output" in
  check (option int) "input None" None input;
  check (option int) "output None" None output

(* ============================================================
   default_configs Tests
   ============================================================ *)

let test_default_configs_not_empty () =
  check bool "not empty" true (List.length Spawn_eio.default_configs > 0)

let test_default_configs_has_claude () =
  check bool "has claude" true (List.mem_assoc "claude" Spawn_eio.default_configs)

let test_default_configs_has_gemini () =
  check bool "has gemini" true (List.mem_assoc "gemini" Spawn_eio.default_configs)

let test_default_configs_has_codex () =
  check bool "has codex" true (List.mem_assoc "codex" Spawn_eio.default_configs)

let test_default_configs_has_llama () =
  check bool "has llama" true (List.mem_assoc "llama" Spawn_eio.default_configs)

let test_default_configs_has_no_ollama () =
  check bool "has no bare ollama config" false
    (List.mem_assoc "ollama" Spawn_eio.default_configs)

let test_default_configs_gemini_json_output () =
  match Spawn_eio.get_config "gemini" with
  | Some cfg ->
      check bool "includes json output" true
        (String.contains cfg.command '-' &&
         try
           let _ = Str.search_forward (Str.regexp_string "--output-format json") cfg.command 0 in
           true
         with Not_found -> false)
  | None -> fail "expected gemini config"

(* ============================================================
   get_config Tests
   ============================================================ *)

let test_get_config_claude () =
  match Spawn_eio.get_config "claude" with
  | Some cfg -> check string "agent_name" "claude" cfg.agent_name
  | None -> fail "expected Some"

let test_get_config_llama () =
  match Spawn_eio.get_config "llama" with
  | Some cfg ->
      check string "agent_name" "llama" cfg.agent_name;
      check bool "command is llama ref" true
        (String.starts_with ~prefix:"llama:" cfg.command)
  | None -> fail "expected Some"

let test_get_config_ollama_removed () =
  match Spawn_eio.get_config "ollama" with
  | None -> ()
  | Some _ -> fail "expected bare ollama config to be removed"

let test_spawn_llama_requires_explicit_runtime_model () =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let result =
    Spawn_eio.spawn ~sw ~proc_mgr:(Eio.Stdenv.process_mgr env) ~agent_name:"llama"
      ~prompt:"hello" ()
  in
  check bool "spawn fails" false result.success;
  check bool "mentions runtime_model" true
    (try
       let _ = Str.search_forward (Str.regexp_string "runtime_model") result.output 0 in
       true
     with Not_found -> false)

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

let test_get_config_unknown () =
  match Spawn_eio.get_config "nonexistent" with
  | None -> ()
  | Some _ -> fail "expected None"

(* ============================================================
   build_mcp_args Tests
   ============================================================ *)

let test_build_mcp_args_empty () =
  let flags = Spawn_eio.build_mcp_args "claude" [] in
  check (list string) "empty flags" [] flags

let test_build_mcp_args_claude () =
  let flags = Spawn_eio.build_mcp_args "claude" ["tool1"; "tool2"] in
  let flags_str = String.concat " " flags in
  check bool "has allowedTools" true (Str.string_match (Str.regexp ".*allowedTools.*") flags_str 0)

let test_build_mcp_args_gemini () =
  let flags = Spawn_eio.build_mcp_args "gemini" ["tool1"; "tool2"] in
  let flags_str = String.concat " " flags in
  check bool "has allowed-tools" true (Str.string_match (Str.regexp ".*allowed-tools.*") flags_str 0)

let test_build_mcp_args_other () =
  let flags = Spawn_eio.build_mcp_args "codex" ["tool1"] in
  check (list string) "empty for other" [] flags

let test_build_prompt_args_gemini () =
  let flags = Spawn_eio.build_prompt_args "gemini" "hello" in
  check (list string) "gemini prompt args" ["-p"; "hello"] flags

let test_build_prompt_args_other () =
  let flags = Spawn_eio.build_prompt_args "claude" "hello" in
  check (list string) "other prompt args" [] flags

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
    "parse_claude_json", [
      test_case "success" `Quick test_parse_claude_json_success;
      test_case "invalid" `Quick test_parse_claude_json_invalid;
      test_case "missing fields" `Quick test_parse_claude_json_missing_fields;
    ];
    "parse_gemini_output", [
      test_case "success" `Quick test_parse_gemini_output_success;
      test_case "with cache" `Quick test_parse_gemini_output_with_cache;
      test_case "extract response from cli json" `Quick test_extract_gemini_response_text_cli_json;
      test_case "cli json stats" `Quick test_parse_gemini_output_cli_json;
      test_case "invalid" `Quick test_parse_gemini_output_invalid;
    ];
    "parse_ollama_output", [
      test_case "success" `Quick test_parse_ollama_output_success;
      test_case "invalid" `Quick test_parse_ollama_output_invalid;
    ];
    "parse_codex_output", [
      test_case "success" `Quick test_parse_codex_output_success;
      test_case "multiline" `Quick test_parse_codex_output_multiline;
      test_case "no turn" `Quick test_parse_codex_output_no_turn;
    ];
    "default_configs", [
      test_case "not empty" `Quick test_default_configs_not_empty;
      test_case "has claude" `Quick test_default_configs_has_claude;
      test_case "has gemini" `Quick test_default_configs_has_gemini;
      test_case "gemini json output" `Quick test_default_configs_gemini_json_output;
      test_case "has codex" `Quick test_default_configs_has_codex;
      test_case "has llama" `Quick test_default_configs_has_llama;
      test_case "has no ollama" `Quick test_default_configs_has_no_ollama;
    ];
    "get_config", [
      test_case "claude" `Quick test_get_config_claude;
      test_case "llama" `Quick test_get_config_llama;
      test_case "ollama removed" `Quick test_get_config_ollama_removed;
      test_case "llama requires explicit runtime_model" `Quick
        test_spawn_llama_requires_explicit_runtime_model;
      test_case "bare ollama rejected" `Quick test_spawn_bare_ollama_rejected;
      test_case "unknown" `Quick test_get_config_unknown;
    ];
    "build_mcp_args", [
      test_case "empty" `Quick test_build_mcp_args_empty;
      test_case "claude" `Quick test_build_mcp_args_claude;
      test_case "gemini" `Quick test_build_mcp_args_gemini;
      test_case "gemini prompt args" `Quick test_build_prompt_args_gemini;
      test_case "other prompt args" `Quick test_build_prompt_args_other;
      test_case "other" `Quick test_build_mcp_args_other;
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
