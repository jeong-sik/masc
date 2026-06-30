(** OAS response helpers.

    Repo-local code should read SDK responses through this module rather than
    reaching into provider-specific helper namespaces. *)

type api_response = Agent_sdk.Types.api_response

val text_of_response : api_response -> string
(** Extract end-user-visible answer text from an API response. Thinking,
    ToolUse, ToolResult, and media blocks are intentionally excluded. *)

val structured_json_of_response
  :  ?schema_name:string
  -> api_response
  -> (Yojson.Safe.t, string) result
(** Extract provider-native structured JSON from an API response through the
    OAS structured-output extractor. Callers remain responsible for domain
    validation of the returned JSON value. *)

val usage : api_response -> Agent_sdk.Types.api_usage option
(** Return provider-reported usage stats, if present. [None] means the
    provider did not report usage; callers must not treat it as zero. *)
