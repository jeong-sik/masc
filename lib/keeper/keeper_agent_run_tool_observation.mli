type observed =
  { reported_tool_names : string list
  ; observed_tool_names : string list
  ; tool_names : string list
  ; canonical_tool_names : string list
  ; unexpected_tool_names : string list
  ; valid_tool_calls_present : bool
  }

val analyze
  :  base_path:string
  -> keeper_name:string
  -> requested_tool_names_seen:string list
  -> tool_usage_before:(string * int) list
  -> tool_calls:Keeper_agent_result.tool_call_detail list
  -> Agent_sdk.Types.content_block list
  -> observed
