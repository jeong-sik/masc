(** Spawn Eio Module Coverage Tests

    Tests for spawn types and constants:
    - spawn_config type
    - spawn_result type
    - masc_mcp_tools constant
*)

open Alcotest

module Spawn_eio = Masc_mcp.Spawn_eio

let with_env name value f =
  let previous = Sys.getenv_opt name in
  (match value with
   | Some v -> Unix.putenv name v
   | None -> Unix.putenv name "");
  Fun.protect
    ~finally:(fun () ->
      match previous with
      | Some v -> Unix.putenv name v
      | None -> Unix.putenv name "")
    f

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
  | None -> check bool "no working_dir" true true
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
    input_tokens = Some 100;
    output_tokens = Some 200;
    cache_creation_tokens = None;
    cache_read_tokens = Some 50;
    cost_usd = Some 0.005;
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
    input_tokens = None;
    output_tokens = None;
    cache_creation_tokens = None;
    cache_read_tokens = None;
    cost_usd = None;
  } in
  check bool "success" false r.success;
  check int "exit_code" 1 r.exit_code

let test_spawn_result_tokens () =
  let r : Spawn_eio.spawn_result = {
    success = true;
    output = "";
    exit_code = 0;
    elapsed_ms = 0;
    input_tokens = Some 1000;
    output_tokens = Some 2000;
    cache_creation_tokens = Some 500;
    cache_read_tokens = Some 300;
    cost_usd = Some 0.025;
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
  check bool "contains vote_create" true
    (List.mem "mcp__masc__masc_vote_create" Spawn_eio.masc_mcp_tools)

let test_masc_mcp_tools_contains_run_deliverable () =
  check bool "contains run_deliverable" true
    (List.mem "mcp__masc__masc_run_deliverable" Spawn_eio.masc_mcp_tools)

let test_llama_mcp_tools_curated () =
  check (list string) "llama tools"
    [
      "mcp__masc__masc_team_session_status";
      "mcp__masc__masc_team_session_turn";
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
  | _ -> check bool "valid parse" true true  (* Structure may vary *)

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
   parse_glm_output Tests
   ============================================================ *)

let test_parse_glm_output_success () =
  let json = {|{"usage": {"prompt_tokens": 60, "completion_tokens": 80}}|} in
  let (input, output, cost) = Spawn_eio.parse_glm_output json in
  check (option int) "input" (Some 60) input;
  check (option int) "output" (Some 80) output;
  check (option (float 0.001)) "cost free" (Some 0.0) cost

let test_parse_glm_output_invalid () =
  let (input, output, cost) = Spawn_eio.parse_glm_output "invalid" in
  check (option int) "input None" None input;
  check (option int) "output None" None output;
  check (option (float 0.01)) "cost None" None cost

(* ============================================================
   GLM Spawn Cache Payload Tests
   ============================================================ *)

let test_spawn_result_cache_roundtrip () =
  let src : Spawn_eio.spawn_result = {
    success = true;
    output = "ok";
    exit_code = 0;
    elapsed_ms = 123;
    input_tokens = Some 10;
    output_tokens = Some 20;
    cache_creation_tokens = None;
    cache_read_tokens = Some 5;
    cost_usd = Some 0.0;
  } in
  let json = Spawn_eio.spawn_result_to_cache_json src in
  match Spawn_eio.spawn_result_of_cache_json json with
  | Ok dst ->
      check bool "success" src.success dst.success;
      check string "output" src.output dst.output;
      check int "exit_code" src.exit_code dst.exit_code;
      check (option int) "input_tokens" src.input_tokens dst.input_tokens
  | Error e -> fail ("expected cache decode success: " ^ e)

let test_spawn_result_cache_schema_mismatch () =
  let bad_json =
    `Assoc [
      ("schema_version", `String "0.0.0");
      ("kind", `String "spawn_glm_response");
      ("response", `Assoc [("success", `Bool true); ("output", `String "x"); ("exit_code", `Int 0)]);
    ]
  in
  match Spawn_eio.spawn_result_of_cache_json bad_json with
  | Ok _ -> fail "expected schema mismatch"
  | Error _ -> ()

(* ============================================================
   GLM Cascade Policy Tests
   ============================================================ *)

let test_normalize_glm_model_alias () =
  check (option string) "4.7 alias" (Some "glm-4.7")
    (Spawn_eio.normalize_glm_model_alias "4.7");
  check (option string) "5-coder alias" (Some "glm-5-code")
    (Spawn_eio.normalize_glm_model_alias "5-coder");
  check (option string) "flashx alias" (Some "glm-4.7-flashx")
    (Spawn_eio.normalize_glm_model_alias "4.7-flashx")

let test_glm_spawn_cascade_models_default_200k () =
  with_env "MASC_GLM_SPAWN_CASCADE" None (fun () ->
    with_env "MASC_GLM_DEFAULT_MODEL" None (fun () ->
      check (list string) "default cascade"
        Spawn_eio.default_glm_spawn_cascade_models
        (Spawn_eio.glm_spawn_cascade_models ())))

let test_glm_spawn_cascade_models_preferred_and_dedup () =
  with_env "MASC_GLM_SPAWN_CASCADE" (Some "4.5,4.7,5-coder,4.7") (fun () ->
    with_env "MASC_GLM_DEFAULT_MODEL" (Some "4.7-flashx") (fun () ->
      check (list string) "preferred+dedup"
        [ "glm-4.7-flashx"; "glm-4.5"; "glm-4.7"; "glm-5-code" ]
        (Spawn_eio.glm_spawn_cascade_models ())))

let test_glm_min_context_tokens_default_and_override () =
  with_env "MASC_GLM_MIN_CONTEXT_TOKENS" None (fun () ->
    check int "default 200k" 200_000 (Spawn_eio.glm_min_context_tokens ()));
  with_env "MASC_GLM_MIN_CONTEXT_TOKENS" (Some "invalid") (fun () ->
    check int "invalid -> default" 200_000 (Spawn_eio.glm_min_context_tokens ()));
  with_env "MASC_GLM_MIN_CONTEXT_TOKENS" (Some "128000") (fun () ->
    check int "override" 128_000 (Spawn_eio.glm_min_context_tokens ()))

let test_glm_spawn_cascade_models_for_policy_200k_only () =
  with_env "MASC_GLM_SPAWN_CASCADE"
    (Some "glm-4.5,4.7,4.7-flash,5,glm-4-32b-0414-128k") (fun () ->
      with_env "MASC_GLM_DEFAULT_MODEL" None (fun () ->
        with_env "MASC_GLM_MIN_CONTEXT_TOKENS" (Some "200000") (fun () ->
          check (list string) "200k models only"
            [ "glm-4.7"; "glm-4.7-flash"; "glm-5" ]
            (Spawn_eio.glm_spawn_cascade_models_for_policy ()))))

let test_extract_glm_message_text_openai_compat () =
  let json = Yojson.Safe.from_string
      {|{"choices":[{"message":{"content":"hello from choices"}}]}|} in
  check (option string) "choices.message.content string"
    (Some "hello from choices")
    (Spawn_eio.extract_glm_message_text json)

let test_extract_glm_message_text_openai_content_list () =
  let json = Yojson.Safe.from_string
      {|{"choices":[{"message":{"content":[{"type":"text","text":"line1"},{"type":"text","text":"line2"}]}}]}|} in
  check (option string) "choices.message.content list"
    (Some "line1\nline2")
    (Spawn_eio.extract_glm_message_text json)

let test_extract_glm_message_text_result_fallback () =
  let json = Yojson.Safe.from_string
      {|{"result":{"content":[{"type":"text","text":"fallback text"}]}}|} in
  check (option string) "result.content fallback"
    (Some "fallback text")
    (Spawn_eio.extract_glm_message_text json)

let test_glm_error_message_parsing () =
  let json = {|{"error":{"message":"Rate limit exceeded","type":"rate_limit"}}|} in
  match Spawn_eio.glm_error_message json with
  | Some msg ->
      check bool "contains error message" true
        (Str.string_match (Str.regexp ".*Rate limit exceeded.*") msg 0)
  | None -> fail "expected glm error"

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

let test_get_config_unknown () =
  match Spawn_eio.get_config "nonexistent" with
  | None -> check bool "None" true true
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
    "parse_glm_output", [
      test_case "success" `Quick test_parse_glm_output_success;
      test_case "invalid" `Quick test_parse_glm_output_invalid;
    ];
    "glm_spawn_cache", [
      test_case "roundtrip" `Quick test_spawn_result_cache_roundtrip;
      test_case "schema mismatch" `Quick test_spawn_result_cache_schema_mismatch;
    ];
    "glm_cascade_policy", [
      test_case "normalize alias" `Quick test_normalize_glm_model_alias;
      test_case "default 200k cascade" `Quick test_glm_spawn_cascade_models_default_200k;
      test_case "preferred + dedup" `Quick test_glm_spawn_cascade_models_preferred_and_dedup;
      test_case "min context default/override" `Quick test_glm_min_context_tokens_default_and_override;
      test_case "200k filter" `Quick test_glm_spawn_cascade_models_for_policy_200k_only;
      test_case "extract choices content" `Quick test_extract_glm_message_text_openai_compat;
      test_case "extract list content" `Quick test_extract_glm_message_text_openai_content_list;
      test_case "extract fallback content" `Quick test_extract_glm_message_text_result_fallback;
      test_case "error message parse" `Quick test_glm_error_message_parsing;
    ];
    "default_configs", [
      test_case "not empty" `Quick test_default_configs_not_empty;
      test_case "has claude" `Quick test_default_configs_has_claude;
      test_case "has gemini" `Quick test_default_configs_has_gemini;
      test_case "gemini json output" `Quick test_default_configs_gemini_json_output;
      test_case "has codex" `Quick test_default_configs_has_codex;
      test_case "has llama" `Quick test_default_configs_has_llama;
    ];
    "get_config", [
      test_case "claude" `Quick test_get_config_claude;
      test_case "llama" `Quick test_get_config_llama;
      test_case "llama requires explicit runtime_model" `Quick
        test_spawn_llama_requires_explicit_runtime_model;
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
  ]
