(** RFC-0058: Cascade capability profile tests (string-based profiles).

    @since RFC-0058 migrated from closed variant to config-driven strings *)

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
    (fun name ->
      let s = CP.profile_to_string name in
      match CP.profile_of_string s with
      | Some name' ->
          check string ("round-trip " ^ s) s name'
      | None ->
          failf "profile_of_string returned None for %s" s)
    CP.all_profiles

let test_unknown_string_returns_none () =
  check (option string) "unknown profile string" None
    (Option.map CP.profile_to_string (CP.profile_of_string "no_such_profile"));
  check (option string) "empty string" None
    (Option.map CP.profile_to_string (CP.profile_of_string ""))

let test_all_profiles_enumerates_every_builtin () =
  check int "all_profiles cardinality" 5 (List.length CP.all_profiles)

let test_local_accepts_anything () =
  check bool "local accepts all_off" true
    (CP.provider_satisfies_profile "local" all_off);
  check bool "local accepts all_on" true
    (CP.provider_satisfies_profile "local" all_on)

let test_tool_strict_requires_runtime_mcp_with_http_headers () =
  check bool "tool_strict rejects all_off" false
    (CP.provider_satisfies_profile "tool_strict" all_off);
  check bool "tool_strict accepts all_on" true
    (CP.provider_satisfies_profile "tool_strict" all_on);
  check bool "tool_strict accepts claude_code (runtime + headers)" true
    (CP.provider_satisfies_profile "tool_strict" claude_code_caps);
  check bool "tool_strict accepts kimi_cli (runtime + headers)" true
    (CP.provider_satisfies_profile "tool_strict" kimi_cli_caps);
  check bool "tool_strict rejects gemini_cli (no http headers)" false
    (CP.provider_satisfies_profile "tool_strict" gemini_cli_caps);
  check bool "tool_strict rejects codex_cli (no http headers)" false
    (CP.provider_satisfies_profile "tool_strict" codex_cli_caps);
  check bool "tool_strict rejects glm_http (no runtime mcp)" false
    (CP.provider_satisfies_profile "tool_strict" glm_http_caps)

let test_inline_tools_path () =
  check bool "inline_tools accepts glm_http" true
    (CP.provider_satisfies_profile "inline_tools" glm_http_caps);
  check bool "inline_tools rejects claude_code" false
    (CP.provider_satisfies_profile "inline_tools" claude_code_caps);
  check bool "inline_tools rejects gemini_cli" false
    (CP.provider_satisfies_profile "inline_tools" gemini_cli_caps)

let test_lite_accepts_runtime_mcp_without_http_headers () =
  check bool "lite accepts gemini_cli" true
    (CP.provider_satisfies_profile "lite" gemini_cli_caps);
  check bool "lite accepts codex_cli" true
    (CP.provider_satisfies_profile "lite" codex_cli_caps);
  check bool "lite accepts claude_code" true
    (CP.provider_satisfies_profile "lite" claude_code_caps);
  check bool "lite accepts kimi_cli" true
    (CP.provider_satisfies_profile "lite" kimi_cli_caps);
  check bool "lite rejects glm_http (no runtime mcp)" false
    (CP.provider_satisfies_profile "lite" glm_http_caps);
  check bool "lite rejects all_off" false
    (CP.provider_satisfies_profile "lite" all_off)

(* Regression: the 2026-05-05 incident keepers used a cascade whose
   fallback (primary) included gemini_cli + codex_cli but their turn
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
        (CP.provider_satisfies_profile "tool_strict" caps);
      check bool "incident: lite accepts cli-no-headers" true
        (CP.provider_satisfies_profile "lite" caps))
    cli_no_headers

(* RFC-0027 PR-4: __safe_lane system cascade. *)
let test_safe_lane_name_pinned () =
  check string "safe_lane_cascade_name pinned" "__safe_lane"
    CP.safe_lane_cascade_name

let test_system_cascade_name_predicate () =
  check bool "__safe_lane is system" true
    (CP.is_system_cascade_name "__safe_lane");
  check bool "__anything is system" true
    (CP.is_system_cascade_name "__anything");
  check bool "single underscore is not system" false
    (CP.is_system_cascade_name "_single");
  check bool "no prefix is not system" false
    (CP.is_system_cascade_name "primary");
  check bool "empty string is not system" false
    (CP.is_system_cascade_name "")

let () =
  run "Cascade_capability_profile"
    [
      ( "string round-trip",
        [
          test_case "to_string then of_string" `Quick test_round_trip;
          test_case "unknown string returns None" `Quick
            test_unknown_string_returns_none;
          test_case "all_profiles cardinality" `Quick
            test_all_profiles_enumerates_every_builtin;
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
      ( "system cascade naming",
        [
          test_case "safe_lane_cascade_name pinned" `Quick
            test_safe_lane_name_pinned;
          test_case "is_system_cascade_name predicate" `Quick
            test_system_cascade_name_predicate;
        ] );
    ]
