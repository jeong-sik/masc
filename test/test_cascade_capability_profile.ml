open Alcotest
module CP = Masc_mcp.Cascade_capability_profile
module PTS = Masc_mcp.Provider_tool_support

let make_caps ~it ~itc ~rmt ~rte ~rmh : PTS.capabilities =
  {
    supports_inline_tools = it;
    supports_inline_tool_choice = itc;
    supports_runtime_mcp_tools = rmt;
    supports_runtime_tool_events = rte;
    supports_runtime_mcp_http_headers = rmh;
  }

let all_off = make_caps ~it:false ~itc:false ~rmt:false ~rte:false ~rmh:false
let all_on = make_caps ~it:true ~itc:true ~rmt:true ~rte:true ~rmh:true

(* Mirror Provider_tool_support semantics: HTTP-based providers
   (claude-api, glm, anthropic) carry inline tools; CLI runtimes
   (claude_code, kimi_cli) carry runtime MCP. *)
let claude_code_caps =
  make_caps ~it:false ~itc:false ~rmt:true ~rte:true ~rmh:true

let kimi_cli_caps =
  make_caps ~it:false ~itc:false ~rmt:true ~rte:true ~rmh:true

let gemini_cli_caps =
  make_caps ~it:false ~itc:false ~rmt:true ~rte:true ~rmh:false

let codex_cli_caps =
  make_caps ~it:false ~itc:false ~rmt:true ~rte:true ~rmh:false

let glm_http_caps =
  make_caps ~it:true ~itc:true ~rmt:false ~rte:false ~rmh:false

let test_round_trip () =
  List.iter
    (fun p ->
      let s = CP.profile_to_string p in
      match CP.profile_of_string s with
      | Some p' ->
          check bool ("round-trip " ^ s) true (p = p')
      | None ->
          failf "profile_of_string returned None for %s" s)
    CP.all_profiles

let test_unknown_string_returns_none () =
  check (option string) "unknown profile string" None
    (Option.map CP.profile_to_string (CP.profile_of_string "no_such_profile"));
  check (option string) "empty string" None
    (Option.map CP.profile_to_string (CP.profile_of_string ""))

let test_all_profiles_enumerates_every_variant () =
  (* If a new variant is added without updating [all_profiles], this
     test will not catch it directly — but the round-trip test will,
     because it iterates [all_profiles] and any missed variant cannot
     produce a string at all (no compile error, but no test coverage).
     This redundant length check pins the cardinality. *)
  check int "all_profiles cardinality" 4 (List.length CP.all_profiles)

let test_local_accepts_anything () =
  check bool "local accepts all_off" true
    (CP.provider_satisfies_profile CP.Local all_off);
  check bool "local accepts all_on" true
    (CP.provider_satisfies_profile CP.Local all_on)

let test_tool_strict_requires_runtime_mcp_with_http_headers () =
  check bool "tool_strict rejects all_off" false
    (CP.provider_satisfies_profile CP.Tool_strict all_off);
  check bool "tool_strict accepts all_on" true
    (CP.provider_satisfies_profile CP.Tool_strict all_on);
  (* claude_code carries runtime MCP HTTP headers → satisfies tool_strict
     even though it lacks inline tools. *)
  check bool "tool_strict accepts claude_code (runtime + headers)" true
    (CP.provider_satisfies_profile CP.Tool_strict claude_code_caps);
  check bool "tool_strict accepts kimi_cli (runtime + headers)" true
    (CP.provider_satisfies_profile CP.Tool_strict kimi_cli_caps);
  (* gemini_cli / codex_cli carry runtime MCP but no per-request HTTP
     headers → fail tool_strict. *)
  check bool "tool_strict rejects gemini_cli (no http headers)" false
    (CP.provider_satisfies_profile CP.Tool_strict gemini_cli_caps);
  check bool "tool_strict rejects codex_cli (no http headers)" false
    (CP.provider_satisfies_profile CP.Tool_strict codex_cli_caps);
  (* glm_http has inline tools but no runtime MCP → fail tool_strict. *)
  check bool "tool_strict rejects glm_http (no runtime mcp)" false
    (CP.provider_satisfies_profile CP.Tool_strict glm_http_caps)

let test_inline_tools_path () =
  check bool "inline_tools accepts glm_http" true
    (CP.provider_satisfies_profile CP.Inline_tools glm_http_caps);
  check bool "inline_tools rejects claude_code" false
    (CP.provider_satisfies_profile CP.Inline_tools claude_code_caps);
  check bool "inline_tools rejects gemini_cli" false
    (CP.provider_satisfies_profile CP.Inline_tools gemini_cli_caps)

let test_lite_accepts_runtime_mcp_without_http_headers () =
  check bool "lite accepts gemini_cli" true
    (CP.provider_satisfies_profile CP.Lite gemini_cli_caps);
  check bool "lite accepts codex_cli" true
    (CP.provider_satisfies_profile CP.Lite codex_cli_caps);
  check bool "lite accepts claude_code" true
    (CP.provider_satisfies_profile CP.Lite claude_code_caps);
  check bool "lite accepts kimi_cli" true
    (CP.provider_satisfies_profile CP.Lite kimi_cli_caps);
  check bool "lite rejects glm_http (no runtime mcp)" false
    (CP.provider_satisfies_profile CP.Lite glm_http_caps);
  check bool "lite rejects all_off" false
    (CP.provider_satisfies_profile CP.Lite all_off)

(* Regression: the 2026-05-05 incident keepers used a cascade whose
   fallback (big_three) included gemini_cli + codex_cli but their turn
   required keeper-bound runtime MCP HTTP headers.  Profile [tool_strict]
   must reject every CLI runtime that strips per-request headers, and
   [lite] must accept them — that is the entire point of the split. *)
let test_incident_2026_05_05_partition () =
  let lacks_http_headers caps =
    not caps.PTS.supports_runtime_mcp_http_headers
  in
  let cli_no_headers = [ gemini_cli_caps; codex_cli_caps ] in
  List.iter
    (fun caps ->
      check bool "incident: cli has no http headers" true
        (lacks_http_headers caps);
      check bool "incident: tool_strict rejects cli-no-headers" false
        (CP.provider_satisfies_profile CP.Tool_strict caps);
      check bool "incident: lite accepts cli-no-headers" true
        (CP.provider_satisfies_profile CP.Lite caps))
    cli_no_headers

let () =
  run "Cascade_capability_profile"
    [
      ( "string round-trip",
        [
          test_case "to_string then of_string" `Quick test_round_trip;
          test_case "unknown string returns None" `Quick
            test_unknown_string_returns_none;
          test_case "all_profiles cardinality" `Quick
            test_all_profiles_enumerates_every_variant;
        ] );
      ( "profile satisfaction",
        [
          test_case "local accepts anything" `Quick test_local_accepts_anything;
          test_case "tool_strict requires runtime MCP with HTTP headers"
            `Quick test_tool_strict_requires_runtime_mcp_with_http_headers;
          test_case "inline_tools requires inline path" `Quick
            test_inline_tools_path;
          test_case "lite accepts runtime MCP without HTTP headers" `Quick
            test_lite_accepts_runtime_mcp_without_http_headers;
        ] );
      ( "incident regression",
        [
          test_case "2026-05-05 partition: tool_strict vs lite" `Quick
            test_incident_2026_05_05_partition;
        ] );
    ]
