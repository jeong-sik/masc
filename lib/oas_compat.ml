(** OAS v0.23+ type adapter for MASC tool results.

    OAS v0.23 changed tool_result from [(string, string) result]
    to [(tool_output, tool_error) result] with structured error types.
    This module bridges MASC's existing [(string, string) result] pattern
    to the new OAS types without rewriting every tool closure.

    Note: This module remains necessary as long as masc-mcp tool closures
    return [(string, string) result]. For message/provider conversions,
    prefer [Llm_client.to_oas_message] and [Llm_client.to_oas_provider]
    which are now the canonical adapters. *)

(** Wrap a success string into [Ok { content }]. *)
let tool_ok (content : string) : Agent_sdk.Types.tool_result =
  Ok { Agent_sdk.Types.content }

(** Wrap an error string into [Error { message; recoverable }].
    Default: [recoverable = true] (agent can retry with different input). *)
let tool_error ?(recoverable = true) (message : string) : Agent_sdk.Types.tool_result =
  Error { Agent_sdk.Types.message; recoverable }

(** Convert a legacy [(string, string) result] to [tool_result].
    Use this to adapt existing code that returns [Ok "content" | Error "msg"]. *)
let adapt_result (r : (string, string) result) : Agent_sdk.Types.tool_result =
  match r with
  | Ok content -> tool_ok content
  | Error message -> tool_error message
