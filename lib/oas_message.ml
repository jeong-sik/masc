(** OAS message helpers.

    Repo-local code uses these constructors so provider-specific helper names do
    not leak into application code. *)

let tool_result ?(is_error = false) ~tool_use_id ~content () :
    Agent_sdk.Types.message =
  {
    Agent_sdk.Types.role = Agent_sdk.Types.Tool;
    content = [ Agent_sdk.Types.ToolResult { tool_use_id; content; is_error } ];
    name = None;
    tool_call_id = None;
  }
