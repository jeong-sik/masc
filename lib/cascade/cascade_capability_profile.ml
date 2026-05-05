type profile =
  | Tool_strict
  | Inline_tools
  | Lite
  | Local

let profile_to_string = function
  | Tool_strict -> "tool_strict"
  | Inline_tools -> "inline_tools"
  | Lite -> "lite"
  | Local -> "local"

let profile_of_string = function
  | "tool_strict" -> Some Tool_strict
  | "inline_tools" -> Some Inline_tools
  | "lite" -> Some Lite
  | "local" -> Some Local
  | _ -> None

let all_profiles = [ Tool_strict; Inline_tools; Lite; Local ]

type requirement =
  | Required
  | Optional

type required_capabilities = {
  inline_tools : requirement;
  inline_tool_choice : requirement;
  runtime_mcp_tools : requirement;
  runtime_tool_events : requirement;
  runtime_mcp_http_headers : requirement;
}

let required_capabilities_of = function
  | Tool_strict ->
      (* Keeper-bound MCP requires per-request HTTP headers carried
         to the provider; inline tools are NOT required because CLI
         runtimes (claude_code, kimi_cli) carry tools through runtime
         MCP, not inline.  The 2026-05-05 incident keepers needed
         exactly this: runtime MCP + HTTP headers, no inline. *)
      {
        inline_tools = Optional;
        inline_tool_choice = Optional;
        runtime_mcp_tools = Required;
        runtime_tool_events = Required;
        runtime_mcp_http_headers = Required;
      }
  | Inline_tools ->
      {
        inline_tools = Required;
        inline_tool_choice = Required;
        runtime_mcp_tools = Optional;
        runtime_tool_events = Optional;
        runtime_mcp_http_headers = Optional;
      }
  | Lite ->
      {
        inline_tools = Optional;
        inline_tool_choice = Optional;
        runtime_mcp_tools = Required;
        runtime_tool_events = Required;
        runtime_mcp_http_headers = Optional;
      }
  | Local ->
      {
        inline_tools = Optional;
        inline_tool_choice = Optional;
        runtime_mcp_tools = Optional;
        runtime_tool_events = Optional;
        runtime_mcp_http_headers = Optional;
      }

let satisfies req has =
  match req with Optional -> true | Required -> has

let provider_satisfies_profile p (caps : Provider_tool_support.capabilities) =
  let req = required_capabilities_of p in
  satisfies req.inline_tools caps.supports_inline_tools
  && satisfies req.inline_tool_choice caps.supports_inline_tool_choice
  && satisfies req.runtime_mcp_tools caps.supports_runtime_mcp_tools
  && satisfies req.runtime_tool_events caps.supports_runtime_tool_events
  && satisfies req.runtime_mcp_http_headers caps.supports_runtime_mcp_http_headers

let safe_lane_cascade_name = "__safe_lane"

let is_system_cascade_name name =
  String.length name >= 2 && String.sub name 0 2 = "__"
