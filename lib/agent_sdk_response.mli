(** OAS response helpers.

    Repo-local code should read SDK responses through this module rather than
    reaching into provider-specific helper namespaces. *)

type api_response = Agent_sdk.Types.api_response

val text_of_response : api_response -> string
(** Extract end-user-visible answer text from an API response. Thinking,
    ToolUse, ToolResult, and media blocks are intentionally excluded. *)

val usage : api_response -> Agent_sdk.Types.api_usage option
(** Return provider-reported usage stats, if present. [None] means the
    provider did not report usage; callers must not treat it as zero. *)
