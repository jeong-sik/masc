(** OAS boundary adapter for tool results.

    MASC tools use [(bool * string)] internally (success flag + message).
    OAS uses [Agent_sdk.Types.tool_result = (tool_output, tool_error) result].

    This module converts at the OAS boundary only — internal MASC
    tool handlers keep their existing convention unchanged.

    @since 2.95.1 *)

let to_oas_tool_result ?(recoverable = true) (success, msg)
  : Agent_sdk.Types.tool_result =
  if success then Ok { Agent_sdk.Types.content = msg }
  else Error { Agent_sdk.Types.message = msg; recoverable }

let of_oas_tool_result : Agent_sdk.Types.tool_result -> bool * string = function
  | Ok { content } -> (true, content)
  | Error { message; _ } -> (false, message)
