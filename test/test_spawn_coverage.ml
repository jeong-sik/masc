(** Spawn Module Coverage Tests

    Tests for MASC Spawn - Agent subprocess management:
    - spawn_config type
    - spawn_result type
    - masc_mcp_tools list
    - masc_lifecycle_suffix
*)

open Alcotest

module Spawn = Masc_mcp.Spawn

(* ============================================================
   spawn_config Tests
   ============================================================ *)

let test_spawn_config_creation () =
  let cfg : Spawn.spawn_config = {
    agent_name = "test-agent";
    command = "claude -p";
    timeout_seconds = 60;
    working_dir = Some "/tmp";
    mcp_tools = ["tool1"; "tool2"]; parse_output = Spawn.parse_raw_output; stdin_prompt = true;
  } in
  check string "agent_name" "test-agent" cfg.agent_name;
  check string "command" "claude -p" cfg.command;
  check int "timeout" 60 cfg.timeout_seconds;
  check bool "stdin_prompt" true cfg.stdin_prompt;
  check string "parse_output" "hello" (cfg.parse_output "hello").text

let test_spawn_config_no_working_dir () =
  let cfg : Spawn.spawn_config = {
    agent_name = "agent";
    command = "cmd";
    timeout_seconds = 30;
    working_dir = None;
    mcp_tools = []; parse_output = Spawn.parse_raw_output; stdin_prompt = true;
  } in
  match cfg.working_dir with
  | None -> ()
  | Some _ -> fail "expected None"

let test_spawn_config_empty_tools () =
  let cfg : Spawn.spawn_config = {
    agent_name = "a";
    command = "c";
    timeout_seconds = 1;
    working_dir = None;
    mcp_tools = []; parse_output = Spawn.parse_raw_output; stdin_prompt = true;
  } in
  check int "empty tools" 0 (List.length cfg.mcp_tools)

(* ============================================================
   spawn_result Tests
   ============================================================ *)

let test_spawn_result_success () =
  let res : Spawn.spawn_result = {
    success = true;
    output = "done";
    exit_code = 0;
    elapsed_ms = 100;
    input_tokens = Some 500;
    output_tokens = Some 200;
    cache_creation_tokens = None;
    cache_read_tokens = None;
    cost_usd = Some 0.01;
  } in
  check bool "success" true res.success;
  check int "exit code" 0 res.exit_code

let test_spawn_result_failure () =
  let res : Spawn.spawn_result = {
    success = false;
    output = "error";
    exit_code = 1;
    elapsed_ms = 50;
    input_tokens = None;
    output_tokens = None;
    cache_creation_tokens = None;
    cache_read_tokens = None;
    cost_usd = None;
  } in
  check bool "not success" false res.success;
  check int "exit code" 1 res.exit_code

let test_spawn_result_tokens () =
  let res : Spawn.spawn_result = {
    success = true;
    output = "ok";
    exit_code = 0;
    elapsed_ms = 200;
    input_tokens = Some 1000;
    output_tokens = Some 500;
    cache_creation_tokens = Some 100;
    cache_read_tokens = Some 200;
    cost_usd = Some 0.05;
  } in
  match res.input_tokens, res.output_tokens with
  | Some i, Some o ->
    check int "input tokens" 1000 i;
    check int "output tokens" 500 o
  | _ -> fail "expected Some tokens"

(* ============================================================
   masc_mcp_tools Tests
   ============================================================ *)

let test_masc_mcp_tools_not_empty () =
  check bool "not empty" true (List.length Spawn.masc_mcp_tools > 0)

let test_masc_mcp_tools_has_status () =
  check bool "has status" true (List.mem "mcp__masc__masc_status" Spawn.masc_mcp_tools)

let test_masc_mcp_tools_has_join () =
  check bool "has join" true (List.mem "mcp__masc__masc_join" Spawn.masc_mcp_tools)

let test_masc_mcp_tools_has_leave () =
  check bool "has leave" true (List.mem "mcp__masc__masc_leave" Spawn.masc_mcp_tools)

let test_masc_mcp_tools_has_broadcast () =
  check bool "has broadcast" true (List.mem "mcp__masc__masc_broadcast" Spawn.masc_mcp_tools)

let test_masc_mcp_tools_omits_claim () =
  check bool "omits claim" false
    (List.mem "mcp__masc__masc_claim" Spawn.masc_mcp_tools)

let test_masc_mcp_tools_omits_done () =
  check bool "omits done" false
    (List.mem "mcp__masc__masc_done" Spawn.masc_mcp_tools)

let test_masc_mcp_tools_has_heartbeat () =
  check bool "has heartbeat" true (List.mem "mcp__masc__masc_heartbeat" Spawn.masc_mcp_tools)

let test_masc_mcp_tools_has_tasks () =
  check bool "has tasks" true (List.mem "mcp__masc__masc_tasks" Spawn.masc_mcp_tools)

let test_masc_mcp_tools_has_worktree () =
  check bool "has worktree" true (List.mem "mcp__masc__masc_worktree_create" Spawn.masc_mcp_tools)

let test_masc_mcp_tools_has_handover () =
  check bool "has handover" true (List.mem "mcp__masc__masc_handover_create" Spawn.masc_mcp_tools)

let test_masc_mcp_tools_omits_relay_status () =
  check bool "omits relay_status" false
    (List.mem "mcp__masc__masc_relay_status" Spawn.masc_mcp_tools)

let test_masc_mcp_tools_has_team_session_step () =
  check bool "has team_session_step" true
    (List.mem "mcp__masc__masc_team_session_step" Spawn.masc_mcp_tools)

let test_masc_mcp_tools_has_team_session_finalize () =
  check bool "has team_session_finalize" true
    (List.mem "mcp__masc__masc_team_session_finalize" Spawn.masc_mcp_tools)

let test_masc_mcp_tools_omits_a2a_delegate () =
  check bool "omits a2a_delegate" false
    (List.mem "mcp__masc__masc_a2a_delegate" Spawn.masc_mcp_tools)

let test_masc_mcp_tools_has_run_deliverable () =
  check bool "omits run_deliverable" false
    (List.mem "mcp__masc__masc_run_deliverable" Spawn.masc_mcp_tools)

let test_masc_mcp_tools_has_tool_help () =
  check bool "has tool_help" true
    (List.mem "mcp__masc__masc_tool_help" Spawn.masc_mcp_tools)

let test_masc_mcp_tools_has_tool_stats () =
  check bool "omits tool_stats" false
    (List.mem "mcp__masc__masc_tool_stats" Spawn.masc_mcp_tools)

let test_masc_mcp_tools_has_tool_admin_snapshot () =
  check bool "omits tool_admin_snapshot" false
    (List.mem "mcp__masc__masc_tool_admin_snapshot" Spawn.masc_mcp_tools)

let test_masc_mcp_tools_omits_keeper_tool_catalog () =
  check bool "omits keeper_tool_catalog" false
    (List.mem "mcp__masc__masc_keeper_tool_catalog" Spawn.masc_mcp_tools)

let test_masc_mcp_tools_has_tool_list () =
  check bool "omits tool_list (no schema)" false
    (List.mem "mcp__masc__masc_tool_list" Spawn.masc_mcp_tools)

let test_masc_mcp_tools_has_tool_grant () =
  check bool "omits tool_grant (no schema)" false
    (List.mem "mcp__masc__masc_tool_grant" Spawn.masc_mcp_tools)

let test_masc_mcp_tools_has_tool_revoke () =
  check bool "omits tool_revoke (no schema)" false
    (List.mem "mcp__masc__masc_tool_revoke" Spawn.masc_mcp_tools)

(* ============================================================
   masc_lifecycle_suffix Tests
   ============================================================ *)

let test_lifecycle_suffix_not_empty () =
  check bool "not empty" true (String.length Spawn.masc_lifecycle_suffix > 0)

let test_lifecycle_suffix_has_protocol () =
  check bool "has protocol" true
    (try let _ = Str.search_forward (Str.regexp_string "MASC LIFECYCLE") Spawn.masc_lifecycle_suffix 0 in true
     with Not_found -> false)

let test_lifecycle_suffix_has_join () =
  check bool "has join" true
    (try let _ = Str.search_forward (Str.regexp_string "masc_join") Spawn.masc_lifecycle_suffix 0 in true
     with Not_found -> false)

let test_lifecycle_suffix_has_heartbeat () =
  check bool "has heartbeat" true
    (try let _ = Str.search_forward (Str.regexp_string "heartbeat") Spawn.masc_lifecycle_suffix 0 in true
     with Not_found -> false)

let test_lifecycle_suffix_has_handover_create () =
  check bool "has handover_create" true
    (try let _ = Str.search_forward (Str.regexp_string "handover_create") Spawn.masc_lifecycle_suffix 0 in true
     with Not_found -> false)

let test_lifecycle_suffix_omits_relay_checkpoint () =
  check bool "omits relay_checkpoint" false
    (try let _ = Str.search_forward (Str.regexp_string "relay_checkpoint") Spawn.masc_lifecycle_suffix 0 in true
     with Not_found -> false)

(* ============================================================
   default_configs Tests
   ============================================================ *)

let test_default_configs_not_empty () =
  check bool "not empty" true (List.length Spawn.default_configs > 0)

let test_default_configs_has_claude () =
  check bool "has claude" true (List.mem_assoc "claude" Spawn.default_configs)

let test_default_configs_has_gemini () =
  check bool "has gemini" true (List.mem_assoc "gemini" Spawn.default_configs)

let test_default_configs_has_codex () =
  check bool "has codex" true (List.mem_assoc "codex" Spawn.default_configs)

let test_default_configs_has_llama () =
  check bool "has llama" true (List.mem_assoc "llama" Spawn.default_configs)

let test_default_configs_has_no_ollama () =
  check bool "no bare ollama config" false (List.mem_assoc "ollama" Spawn.default_configs)

let test_default_configs_claude_command () =
  match List.assoc_opt "claude" Spawn.default_configs with
  | Some cfg -> check bool "has claude command" true
      (try let _ = Str.search_forward (Str.regexp "claude") cfg.command 0 in true
       with Not_found -> false)
  | None -> fail "claude config missing"

(* P2 #19: Test that default_configs use Env_config.Spawn.timeout_seconds *)
let test_default_configs_timeout_from_env_config () =
  let expected = Env_config.Spawn.timeout_seconds in
  List.iter (fun (name, cfg) ->
    check int (Printf.sprintf "%s timeout uses Env_config" name) expected cfg.Spawn.timeout_seconds
  ) Spawn.default_configs

let test_default_configs_timeout_is_600 () =
  (* All agents should use 600s (10 min) default timeout *)
  List.iter (fun (name, cfg) ->
    check int (Printf.sprintf "%s timeout is 600" name) 600 cfg.Spawn.timeout_seconds
  ) Spawn.default_configs

let test_default_configs_gemini_command () =
  match List.assoc_opt "gemini" Spawn.default_configs with
  | Some cfg -> check bool "has gemini command" true
      (try let _ = Str.search_forward (Str.regexp "gemini") cfg.command 0 in true
       with Not_found -> false)
  | None -> fail "no gemini config"

let test_default_configs_gemini_json_output () =
  match List.assoc_opt "gemini" Spawn.default_configs with
  | Some cfg ->
      check bool "has json output" true
        (try
           let _ = Str.search_forward (Str.regexp_string "--output-format json") cfg.command 0 in
           true
         with Not_found -> false)
  | None -> fail "no gemini config"

(* ============================================================
   get_config Tests
   ============================================================ *)

let test_get_config_claude () =
  match Spawn.get_config "claude" with
  | Some cfg -> check string "agent name" "claude" cfg.agent_name
  | None -> fail "expected Some"

let test_get_config_gemini () =
  match Spawn.get_config "gemini" with
  | Some cfg -> check string "agent name" "gemini" cfg.agent_name
  | None -> fail "expected Some"

let test_get_config_codex () =
  match Spawn.get_config "codex" with
  | Some cfg -> check string "agent name" "codex" cfg.agent_name
  | None -> fail "expected Some"

let test_get_config_llama () =
  match Spawn.get_config "llama" with
  | Some cfg -> check string "agent name" "llama" cfg.agent_name
  | None -> fail "expected Some"

let test_get_config_ollama_removed () =
  match Spawn.get_config "ollama" with
  | None -> ()
  | Some _ -> fail "expected bare ollama config to be removed"

let test_get_config_unknown () =
  match Spawn.get_config "unknown-agent" with
  | None -> ()
  | Some _ -> fail "expected None"

let test_spawn_bare_ollama_rejected () =
  if Masc_mcp.Provider_adapter.is_bare_ollama_label "ollama" then (
    let result = Spawn.spawn ~agent_name:"ollama" ~prompt:"test" () in
    check bool "spawn rejected" false result.Spawn.success;
    check int "exit code" 2 result.Spawn.exit_code;
    check bool "mentions migration" true
      (try
         let _ =
           Str.search_forward
             (Str.regexp_string "llama:<model>")
             result.Spawn.output 0
         in
         true
       with Not_found -> false))
  else
    Alcotest.skip ()

let test_spawn_empty_command_rejected () =
  let result = Spawn.spawn ~agent_name:"   " ~prompt:"test" () in
  check bool "spawn rejected" false result.Spawn.success;
  check int "exit code" 2 result.Spawn.exit_code;
  check bool "mentions empty command" true
    (try
       let _ =
         Str.search_forward
           (Str.regexp_string "spawn command is empty")
           result.Spawn.output 0
       in
       true
     with Not_found -> false)

(* ============================================================
   build_mcp_args Tests
   ============================================================ *)

let test_build_mcp_args_empty () =
  let flags = Spawn.build_mcp_args "claude" [] in
  check (list string) "empty flags" [] flags

let test_build_mcp_args_claude () =
  (* "claude" resolves via spawn_key to "claude" — MCP flags are passed *)
  let flags = Spawn.build_mcp_args "claude" ["tool1"; "tool2"] in
  check (list string) "claude allowed tools" ["--allowedTools"; "tool1,tool2"] flags

let test_build_mcp_args_gemini () =
  (* "gemini" resolves via spawn_key to "gemini" — MCP flags are passed *)
  let flags = Spawn.build_mcp_args "gemini" ["tool1"] in
  check (list string) "gemini allowed tools"
    ["--allowed-mcp-server-names"; "masc"; "--allowed-tools"; "tool1"] flags

let test_build_mcp_args_gemini_allowed_tools () =
  let flags = Spawn.build_mcp_args "gemini" ["tool1"; "tool2"] in
  check (list string) "gemini multi tools"
    ["--allowed-mcp-server-names"; "masc"; "--allowed-tools"; "tool1"; "tool2"] flags

let test_build_mcp_args_codex () =
  let flags = Spawn.build_mcp_args "codex" ["tool1"; "tool2"] in
  check (list string) "codex empty" [] flags

let test_build_mcp_args_llama () =
  let flags = Spawn.build_mcp_args "llama" ["tool1"] in
  check (list string) "llama empty" [] flags

let test_build_mcp_args_unknown () =
  let flags = Spawn.build_mcp_args "unknown" ["tool1"] in
  check (list string) "unknown empty" [] flags

let test_build_prompt_args_gemini () =
  (* "gemini" resolves via spawn_key to "gemini" — prompt args passed *)
  let flags = Spawn.build_prompt_args "gemini" "hello" in
  check (list string) "gemini prompt args" ["-p"; "hello"] flags

let test_build_prompt_args_other () =
  let flags = Spawn.build_prompt_args "claude" "hello" in
  check (list string) "other prompt args" [] flags

(* ============================================================
   parse_claude_output Tests
   ============================================================ *)

let test_parse_claude_output_valid () =
  let json_str = {|{"usage":{"input_tokens":100,"output_tokens":50},"total_cost_usd":0.01,"result":"done"}|} in
  let p = Spawn.parse_claude_output json_str in
  check string "result text" "done" p.text;
  check (option int) "input tokens" (Some 100) p.input_tokens;
  check (option int) "output tokens" (Some 50) p.output_tokens;
  check (option int) "cache creation" None p.cache_creation_tokens;
  check (option int) "cache read" None p.cache_read_tokens

let test_parse_claude_output_with_cache () =
  let json_str = {|{"usage":{"input_tokens":100,"output_tokens":50,"cache_creation_input_tokens":20,"cache_read_input_tokens":30},"total_cost_usd":0.02,"result":"ok"}|} in
  let p = Spawn.parse_claude_output json_str in
  check (option int) "cache creation" (Some 20) p.cache_creation_tokens;
  check (option int) "cache read" (Some 30) p.cache_read_tokens

let test_parse_claude_output_invalid () =
  let json_str = "not valid json" in
  let p = Spawn.parse_claude_output json_str in
  check string "returns raw" "not valid json" p.text;
  check (option int) "no input" None p.input_tokens;
  check (option int) "no output" None p.output_tokens;
  check (option int) "no cache c" None p.cache_creation_tokens;
  check (option int) "no cache r" None p.cache_read_tokens;
  check bool "no cost" true (p.cost_usd = None)

let test_parse_claude_output_missing_fields () =
  let json_str = {|{"usage":{}}|} in
  let p = Spawn.parse_claude_output json_str in
  check (option int) "no input" None p.input_tokens;
  check (option int) "no output" None p.output_tokens

(* ============================================================
   parse_gemini_output Tests
   ============================================================ *)

let test_parse_gemini_output_response_text () =
  let json = {|{"response":"hello from gemini","session_id":"sess-1","stats":{"models":{}}}|} in
  let p = Spawn.parse_gemini_output json in
  check string "response text" "hello from gemini" p.text

let test_parse_gemini_output_success () =
  let json = {|{"usageMetadata": {"promptTokenCount": 50, "candidatesTokenCount": 100}}|} in
  let p = Spawn.parse_gemini_output json in
  check (option int) "input" (Some 50) p.input_tokens;
  check (option int) "output" (Some 100) p.output_tokens;
  check (option int) "cached" None p.cache_read_tokens

let test_parse_gemini_output_with_cache () =
  let json = {|{"usageMetadata": {"promptTokenCount": 100, "candidatesTokenCount": 50, "cachedContentTokenCount": 80}}|} in
  let p = Spawn.parse_gemini_output json in
  check (option int) "input" (Some 100) p.input_tokens;
  check (option int) "output" (Some 50) p.output_tokens;
  check (option int) "cached" (Some 80) p.cache_read_tokens;
  (* cost_usd now requires explicit total_cost_usd in JSON; no hardcoded pricing *)
  check bool "no cost without total_cost_usd" true (p.cost_usd = None)

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
  let p = Spawn.parse_gemini_output json in
  check (option int) "input" (Some 15769) p.input_tokens;
  check (option int) "output" (Some 85) p.output_tokens;
  check (option int) "cached" None p.cache_read_tokens;
  (* cost_usd now requires explicit total_cost_usd in JSON; no hardcoded pricing *)
  check bool "no cost without total_cost_usd" true (p.cost_usd = None)

let test_parse_gemini_output_with_cost () =
  let json = {|{"usageMetadata": {"promptTokenCount": 200, "candidatesTokenCount": 80}, "total_cost_usd": 0.0042}|} in
  let p = Spawn.parse_gemini_output json in
  check (option int) "input" (Some 200) p.input_tokens;
  check (option int) "output" (Some 80) p.output_tokens;
  check bool "has cost" true (Option.is_some p.cost_usd);
  check (option (float 0.0001)) "cost value" (Some 0.0042) p.cost_usd

let test_parse_gemini_output_invalid () =
  let p = Spawn.parse_gemini_output "invalid" in
  check (option int) "input None" None p.input_tokens;
  check (option int) "output None" None p.output_tokens;
  check (option int) "cached None" None p.cache_read_tokens;
  check (option (float 0.01)) "cost None" None p.cost_usd

(* ============================================================
   int_opt_to_json / float_opt_to_json Tests
   ============================================================ *)

let test_int_opt_to_json_some () =
  let json = Spawn.int_opt_to_json (Some 42) in
  check string "int 42" "42" (Yojson.Safe.to_string json)

let test_int_opt_to_json_none () =
  let json = Spawn.int_opt_to_json None in
  check string "null" "null" (Yojson.Safe.to_string json)

let test_float_opt_to_json_some () =
  let json = Spawn.float_opt_to_json (Some 3.14) in
  let str = Yojson.Safe.to_string json in
  check bool "has 3.14" true
    (try let _ = Str.search_forward (Str.regexp "3.14") str 0 in true
     with Not_found -> false)

let test_float_opt_to_json_none () =
  let json = Spawn.float_opt_to_json None in
  check string "null" "null" (Yojson.Safe.to_string json)

(* ============================================================
   result_to_json Tests
   ============================================================ *)

let test_result_to_json_success () =
  let result : Spawn.spawn_result = {
    success = true;
    output = "test output";
    exit_code = 0;
    elapsed_ms = 100;
    input_tokens = Some 500;
    output_tokens = Some 200;
    cache_creation_tokens = None;
    cache_read_tokens = None;
    cost_usd = Some 0.01;
  } in
  let json = Spawn.result_to_json result in
  let str = Yojson.Safe.to_string json in
  check bool "has success" true
    (try let _ = Str.search_forward (Str.regexp "\"success\":true") str 0 in true
     with Not_found -> false);
  check bool "has output" true
    (try let _ = Str.search_forward (Str.regexp "test output") str 0 in true
     with Not_found -> false)

let test_result_to_json_failure () =
  let result : Spawn.spawn_result = {
    success = false;
    output = "error";
    exit_code = 1;
    elapsed_ms = 50;
    input_tokens = None;
    output_tokens = None;
    cache_creation_tokens = None;
    cache_read_tokens = None;
    cost_usd = None;
  } in
  let json = Spawn.result_to_json result in
  let str = Yojson.Safe.to_string json in
  check bool "has success false" true
    (try let _ = Str.search_forward (Str.regexp "\"success\":false") str 0 in true
     with Not_found -> false)

let test_result_to_json_with_cache () =
  let result : Spawn.spawn_result = {
    success = true;
    output = "ok";
    exit_code = 0;
    elapsed_ms = 200;
    input_tokens = Some 1000;
    output_tokens = Some 500;
    cache_creation_tokens = Some 100;
    cache_read_tokens = Some 200;
    cost_usd = Some 0.05;
  } in
  let json = Spawn.result_to_json result in
  let str = Yojson.Safe.to_string json in
  check bool "has cache_creation_tokens" true
    (try let _ = Str.search_forward (Str.regexp "cache_creation_tokens") str 0 in true
     with Not_found -> false)

(* ============================================================
   format_token_info Tests
   ============================================================ *)

let test_format_token_info_with_tokens () =
  let result : Spawn.spawn_result = {
    success = true;
    output = "";
    exit_code = 0;
    elapsed_ms = 100;
    input_tokens = Some 500;
    output_tokens = Some 200;
    cache_creation_tokens = None;
    cache_read_tokens = None;
    cost_usd = Some 0.01;
  } in
  let info = Spawn.format_token_info result in
  check bool "has tokens" true
    (try let _ = Str.search_forward (Str.regexp "Tokens") info 0 in true
     with Not_found -> false);
  check bool "has cost" true
    (try let _ = Str.search_forward (Str.regexp "Cost") info 0 in true
     with Not_found -> false)

let test_format_token_info_with_cache () =
  let result : Spawn.spawn_result = {
    success = true;
    output = "";
    exit_code = 0;
    elapsed_ms = 100;
    input_tokens = Some 500;
    output_tokens = Some 200;
    cache_creation_tokens = Some 50;
    cache_read_tokens = Some 100;
    cost_usd = Some 0.02;
  } in
  let info = Spawn.format_token_info result in
  check bool "has cache" true
    (try let _ = Str.search_forward (Str.regexp "cache") info 0 in true
     with Not_found -> false)

let test_format_token_info_no_tokens () =
  let result : Spawn.spawn_result = {
    success = true;
    output = "";
    exit_code = 0;
    elapsed_ms = 100;
    input_tokens = None;
    output_tokens = None;
    cache_creation_tokens = None;
    cache_read_tokens = None;
    cost_usd = None;
  } in
  let info = Spawn.format_token_info result in
  check string "empty" "" info

(* ============================================================
   result_to_string Tests
   ============================================================ *)

let test_result_to_string_success () =
  let result : Spawn.spawn_result = {
    success = true;
    output = "completed";
    exit_code = 0;
    elapsed_ms = 100;
    input_tokens = None;
    output_tokens = None;
    cache_creation_tokens = None;
    cache_read_tokens = None;
    cost_usd = None;
  } in
  let str = Spawn.result_to_string result in
  check bool "has checkmark" true
    (try let _ = Str.search_forward (Str.regexp "✅") str 0 in true
     with Not_found -> false)

let test_result_to_string_failure () =
  let result : Spawn.spawn_result = {
    success = false;
    output = "failed";
    exit_code = 1;
    elapsed_ms = 50;
    input_tokens = None;
    output_tokens = None;
    cache_creation_tokens = None;
    cache_read_tokens = None;
    cost_usd = None;
  } in
  let str = Spawn.result_to_string result in
  check bool "has x" true
    (try let _ = Str.search_forward (Str.regexp "❌") str 0 in true
     with Not_found -> false)

let test_result_to_string_has_elapsed () =
  let result : Spawn.spawn_result = {
    success = true;
    output = "";
    exit_code = 0;
    elapsed_ms = 12345;
    input_tokens = None;
    output_tokens = None;
    cache_creation_tokens = None;
    cache_read_tokens = None;
    cost_usd = None;
  } in
  let str = Spawn.result_to_string result in
  check bool "has elapsed" true
    (try let _ = Str.search_forward (Str.regexp "12345") str 0 in true
     with Not_found -> false)

let test_result_to_string_has_output () =
  let result : Spawn.spawn_result = {
    success = true;
    output = "unique_output_xyz";
    exit_code = 0;
    elapsed_ms = 100;
    input_tokens = None;
    output_tokens = None;
    cache_creation_tokens = None;
    cache_read_tokens = None;
    cost_usd = None;
  } in
  let str = Spawn.result_to_string result in
  check bool "has output" true
    (try let _ = Str.search_forward (Str.regexp "unique_output_xyz") str 0 in true
     with Not_found -> false)

(* ============================================================
   spawn_sync alias Tests
   ============================================================ *)

let test_spawn_sync_is_spawn () =
  (* Just verify spawn_sync is the same function as spawn (alias test) *)
  let _ : (agent_name:string -> prompt:string -> ?timeout_seconds:int -> ?working_dir:string -> unit -> Spawn.spawn_result) = Spawn.spawn_sync in
  ()

(* ============================================================
   Test Runners
   ============================================================ *)

let () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  Eio_guard.enable ();
  run "Spawn Coverage" [
    "spawn_config", [
      test_case "creation" `Quick test_spawn_config_creation;
      test_case "no working dir" `Quick test_spawn_config_no_working_dir;
      test_case "empty tools" `Quick test_spawn_config_empty_tools;
    ];
    "spawn_result", [
      test_case "success" `Quick test_spawn_result_success;
      test_case "failure" `Quick test_spawn_result_failure;
      test_case "tokens" `Quick test_spawn_result_tokens;
    ];
    "masc_mcp_tools", [
      test_case "not empty" `Quick test_masc_mcp_tools_not_empty;
      test_case "has status" `Quick test_masc_mcp_tools_has_status;
      test_case "has join" `Quick test_masc_mcp_tools_has_join;
      test_case "has leave" `Quick test_masc_mcp_tools_has_leave;
      test_case "has broadcast" `Quick test_masc_mcp_tools_has_broadcast;
      test_case "omits claim" `Quick test_masc_mcp_tools_omits_claim;
      test_case "omits done" `Quick test_masc_mcp_tools_omits_done;
      test_case "has heartbeat" `Quick test_masc_mcp_tools_has_heartbeat;
      test_case "has tasks" `Quick test_masc_mcp_tools_has_tasks;
      test_case "has worktree" `Quick test_masc_mcp_tools_has_worktree;
      test_case "has handover" `Quick test_masc_mcp_tools_has_handover;
      test_case "omits relay_status" `Quick test_masc_mcp_tools_omits_relay_status;
      test_case "has team_session_step" `Quick test_masc_mcp_tools_has_team_session_step;
      test_case "has team_session_finalize" `Quick test_masc_mcp_tools_has_team_session_finalize;
      test_case "omits a2a_delegate" `Quick test_masc_mcp_tools_omits_a2a_delegate;
      test_case "has run_deliverable" `Quick test_masc_mcp_tools_has_run_deliverable;
      test_case "omits tool_stats" `Quick test_masc_mcp_tools_has_tool_stats;
      test_case "has tool_help" `Quick test_masc_mcp_tools_has_tool_help;
      test_case "omits tool_admin_snapshot" `Quick
        test_masc_mcp_tools_has_tool_admin_snapshot;
      test_case "omits keeper_tool_catalog" `Quick
        test_masc_mcp_tools_omits_keeper_tool_catalog;
      test_case "has tool_list" `Quick test_masc_mcp_tools_has_tool_list;
      test_case "has tool_grant" `Quick test_masc_mcp_tools_has_tool_grant;
      test_case "has tool_revoke" `Quick test_masc_mcp_tools_has_tool_revoke;
    ];
    "lifecycle_suffix", [
      test_case "not empty" `Quick test_lifecycle_suffix_not_empty;
      test_case "has protocol" `Quick test_lifecycle_suffix_has_protocol;
      test_case "has join" `Quick test_lifecycle_suffix_has_join;
      test_case "has heartbeat" `Quick test_lifecycle_suffix_has_heartbeat;
      test_case "has handover_create" `Quick test_lifecycle_suffix_has_handover_create;
      test_case "omits relay_checkpoint" `Quick test_lifecycle_suffix_omits_relay_checkpoint;
    ];
    "default_configs", [
      test_case "not empty" `Quick test_default_configs_not_empty;
      test_case "has claude" `Quick test_default_configs_has_claude;
      test_case "has gemini" `Quick test_default_configs_has_gemini;
      test_case "has codex" `Quick test_default_configs_has_codex;
      test_case "has llama" `Quick test_default_configs_has_llama;
      test_case "has no ollama" `Quick test_default_configs_has_no_ollama;
      test_case "claude command" `Quick test_default_configs_claude_command;
      test_case "gemini command" `Quick test_default_configs_gemini_command;
      test_case "gemini json output" `Quick test_default_configs_gemini_json_output;
      test_case "timeout from env_config" `Quick test_default_configs_timeout_from_env_config;
      test_case "timeout is 600" `Quick test_default_configs_timeout_is_600;
    ];
    "get_config", [
      test_case "claude" `Quick test_get_config_claude;
      test_case "gemini" `Quick test_get_config_gemini;
      test_case "codex" `Quick test_get_config_codex;
      test_case "llama" `Quick test_get_config_llama;
      test_case "ollama removed" `Quick test_get_config_ollama_removed;
      test_case "unknown" `Quick test_get_config_unknown;
      test_case "bare ollama rejected" `Quick test_spawn_bare_ollama_rejected;
      test_case "empty command rejected" `Quick test_spawn_empty_command_rejected;
    ];
    "build_mcp_args", [
      test_case "empty" `Quick test_build_mcp_args_empty;
      test_case "claude" `Quick test_build_mcp_args_claude;
      test_case "gemini" `Quick test_build_mcp_args_gemini;
      test_case "gemini allowed tools" `Quick test_build_mcp_args_gemini_allowed_tools;
      test_case "gemini prompt args" `Quick test_build_prompt_args_gemini;
      test_case "other prompt args" `Quick test_build_prompt_args_other;
      test_case "codex" `Quick test_build_mcp_args_codex;
      test_case "llama" `Quick test_build_mcp_args_llama;
      test_case "unknown" `Quick test_build_mcp_args_unknown;
    ];
    "parse_claude_output", [
      test_case "valid" `Quick test_parse_claude_output_valid;
      test_case "with cache" `Quick test_parse_claude_output_with_cache;
      test_case "invalid" `Quick test_parse_claude_output_invalid;
      test_case "missing fields" `Quick test_parse_claude_output_missing_fields;
    ];
    "parse_gemini_output", [
      test_case "response text extraction" `Quick test_parse_gemini_output_response_text;
      test_case "success" `Quick test_parse_gemini_output_success;
      test_case "with cache" `Quick test_parse_gemini_output_with_cache;
      test_case "cli json stats" `Quick test_parse_gemini_output_cli_json;
      test_case "with explicit cost" `Quick test_parse_gemini_output_with_cost;
      test_case "invalid" `Quick test_parse_gemini_output_invalid;
    ];
    "int_opt_to_json", [
      test_case "some" `Quick test_int_opt_to_json_some;
      test_case "none" `Quick test_int_opt_to_json_none;
    ];
    "float_opt_to_json", [
      test_case "some" `Quick test_float_opt_to_json_some;
      test_case "none" `Quick test_float_opt_to_json_none;
    ];
    "result_to_json", [
      test_case "success" `Quick test_result_to_json_success;
      test_case "failure" `Quick test_result_to_json_failure;
      test_case "with cache" `Quick test_result_to_json_with_cache;
    ];
    "format_token_info", [
      test_case "with tokens" `Quick test_format_token_info_with_tokens;
      test_case "with cache" `Quick test_format_token_info_with_cache;
      test_case "no tokens" `Quick test_format_token_info_no_tokens;
    ];
    "result_to_string", [
      test_case "success" `Quick test_result_to_string_success;
      test_case "failure" `Quick test_result_to_string_failure;
      test_case "has elapsed" `Quick test_result_to_string_has_elapsed;
      test_case "has output" `Quick test_result_to_string_has_output;
    ];
    "spawn_sync", [
      test_case "alias" `Quick test_spawn_sync_is_spawn;
    ];
  ]
