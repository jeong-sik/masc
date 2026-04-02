(** Tests for Spawn module - Agent spawning *)

open Masc_mcp

let test_get_config_known_agents () =
  (* Test get_config for known agents *)
  let claude = Spawn.get_config "claude" in
  Alcotest.(check bool) "claude config exists" true (Option.is_some claude);
  let claude = Option.get claude in
  Alcotest.(check string) "claude agent_name" "claude" claude.Spawn.agent_name;
  Alcotest.(check bool) "claude has mcp_tools" true (List.length claude.mcp_tools > 0);

  let claude_alias = Spawn.get_config "claude-code" in
  Alcotest.(check bool) "claude-code alias exists" true (Option.is_some claude_alias);

  let gemini = Spawn.get_config "gemini" in
  Alcotest.(check bool) "gemini config exists" true (Option.is_some gemini);

  let gemini_alias = Spawn.get_config "gemini-cli" in
  Alcotest.(check bool) "gemini-cli alias exists" true (Option.is_some gemini_alias);

  let codex = Spawn.get_config "codex" in
  Alcotest.(check bool) "codex config exists" true (Option.is_some codex);

  let codex_alias = Spawn.get_config "codex-cli" in
  Alcotest.(check bool) "codex-cli alias exists" true (Option.is_some codex_alias);

  let llama = Spawn.get_config "llama" in
  Alcotest.(check bool) "llama config exists" true (Option.is_some llama);
  ()

let test_get_config_unknown_agent () =
  (* Test get_config for unknown agents returns None *)
  let unknown = Spawn.get_config "unknown-agent" in
  Alcotest.(check bool) "unknown config is None" true (Option.is_none unknown);
  ()

let test_get_config_bare_ollama_removed () =
  let ollama = Spawn.get_config "ollama" in
  Alcotest.(check bool) "ollama config removed" true (Option.is_none ollama)

let contains s1 s2 =
  try
    let _ = Str.search_forward (Str.regexp_string s2) s1 0 in true
  with Not_found -> false

let test_result_to_string_success () =
  (* Test result formatting for success case *)
  let result = {
    Spawn.success = true;
    output = "Hello from agent";
    exit_code = 0;
    elapsed_ms = 1234;
    input_tokens = None;
    output_tokens = None;
    cache_creation_tokens = None;
    cache_read_tokens = None;
    cost_usd = None;
  } in
  let s = Spawn.result_to_string result in
  Alcotest.(check bool) "contains completed text" true (contains s "completed");
  Alcotest.(check bool) "contains output" true (contains s "Hello from agent");
  ()

let test_result_to_string_failure () =
  (* Test result formatting for failure case *)
  let result = {
    Spawn.success = false;
    output = "Command not found";
    exit_code = 1;
    elapsed_ms = 100;
    input_tokens = None;
    output_tokens = None;
    cache_creation_tokens = None;
    cache_read_tokens = None;
    cost_usd = None;
  } in
  let s = Spawn.result_to_string result in
  Alcotest.(check bool) "contains failed text" true (contains s "failed");
  Alcotest.(check bool) "contains error output" true (contains s "Command not found");
  Alcotest.(check int) "exit code is 1" 1 result.exit_code;
  ()

let test_result_to_json () =
  (* Test result JSON conversion *)
  let result = {
    Spawn.success = true;
    output = "test output";
    exit_code = 0;
    elapsed_ms = 500;
    input_tokens = Some 100;
    output_tokens = Some 50;
    cache_creation_tokens = None;
    cache_read_tokens = None;
    cost_usd = Some 0.0025;
  } in
  let json = Spawn.result_to_json result in
  let open Yojson.Safe.Util in
  Alcotest.(check bool) "json success" true (json |> member "success" |> to_bool);
  Alcotest.(check int) "json exit_code" 0 (json |> member "exit_code" |> to_int);
  Alcotest.(check int) "json input_tokens" 100 (json |> member "input_tokens" |> to_int);
  ()

let test_masc_mcp_tools () =
  (* Test that masc_mcp_tools list is populated *)
  Alcotest.(check bool) "tools list not empty" true (List.length Spawn.masc_mcp_tools > 0);
  Alcotest.(check bool) "contains masc_status" true
    (List.mem "mcp__masc__masc_status" Spawn.masc_mcp_tools);
  Alcotest.(check bool) "omits masc_claim" false
    (List.mem "mcp__masc__masc_claim" Spawn.masc_mcp_tools);
  Alcotest.(check bool) "contains team_session_step" true
    (List.mem "mcp__masc__masc_team_session_step" Spawn.masc_mcp_tools);
  Alcotest.(check bool) "contains team_session_finalize" true
    (List.mem "mcp__masc__masc_team_session_finalize" Spawn.masc_mcp_tools);
  Alcotest.(check bool) "contains portal_send" true
    (List.mem "mcp__masc__masc_portal_send" Spawn.masc_mcp_tools);
  Alcotest.(check bool) "contains a2a_delegate" true
    (List.mem "mcp__masc__masc_a2a_delegate" Spawn.masc_mcp_tools);
  Alcotest.(check bool) "omits run_deliverable" false
    (List.mem "mcp__masc__masc_run_deliverable" Spawn.masc_mcp_tools);
  Alcotest.(check bool) "contains board_post" true
    (List.mem "mcp__masc__masc_board_post" Spawn.masc_mcp_tools);
  Alcotest.(check bool) "omits tool_stats" false
    (List.mem "mcp__masc__masc_tool_stats" Spawn.masc_mcp_tools);
  Alcotest.(check bool) "contains tool_help" true
    (List.mem "mcp__masc__masc_tool_help" Spawn.masc_mcp_tools);
  Alcotest.(check bool) "omits tool_admin_snapshot" false
    (List.mem "mcp__masc__masc_tool_admin_snapshot" Spawn.masc_mcp_tools);
  Alcotest.(check bool) "omits keeper_tool_catalog" false
    (List.mem "mcp__masc__masc_keeper_tool_catalog" Spawn.masc_mcp_tools);
  Alcotest.(check bool) "omits operator_snapshot" false
    (List.mem "mcp__masc__masc_operator_snapshot" Spawn.masc_mcp_tools);
  Alcotest.(check bool) "omits team_session_prove" false
    (List.mem "mcp__masc__masc_team_session_prove" Spawn.masc_mcp_tools);
  Alcotest.(check bool) "omits tool_list (no schema)" false
    (List.mem "mcp__masc__masc_tool_list" Spawn.masc_mcp_tools);
  Alcotest.(check bool) "omits tool_grant (no schema)" false
    (List.mem "mcp__masc__masc_tool_grant" Spawn.masc_mcp_tools);
  Alcotest.(check bool) "omits tool_revoke (no schema)" false
    (List.mem "mcp__masc__masc_tool_revoke" Spawn.masc_mcp_tools);
  ()

let test_spawn_bare_ollama_rejected () =
  let result = Spawn.spawn ~agent_name:"ollama" ~prompt:"test" () in
  Alcotest.(check bool) "spawn rejected" false result.Spawn.success;
  Alcotest.(check int) "exit code" 2 result.Spawn.exit_code;
  Alcotest.(check bool) "migration message" true
    (contains result.Spawn.output "llama:<model>")

let tests = [
  Alcotest.test_case "get_config known agents" `Quick test_get_config_known_agents;
  Alcotest.test_case "get_config unknown agent" `Quick test_get_config_unknown_agent;
  Alcotest.test_case "bare ollama config removed" `Quick
    test_get_config_bare_ollama_removed;
  Alcotest.test_case "result_to_string success" `Quick test_result_to_string_success;
  Alcotest.test_case "result_to_string failure" `Quick test_result_to_string_failure;
  Alcotest.test_case "result_to_json" `Quick test_result_to_json;
  Alcotest.test_case "masc_mcp_tools populated" `Quick test_masc_mcp_tools;
  Alcotest.test_case "bare ollama rejected" `Quick test_spawn_bare_ollama_rejected;
]

let () =
  Alcotest.run "Spawn" [
    "Config", tests;
  ]
