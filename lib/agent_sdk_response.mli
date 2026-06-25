(** OAS response helpers.

    Repo-local code should read SDK responses through this module rather than
    reaching into provider-specific helper namespaces. *)

type api_response = Agent_sdk.Types.api_response

val text_of_response : api_response -> string
(** Extract text content from an API response. *)

val usage : api_response -> Agent_sdk.Types.api_usage option
(** Return provider-reported usage stats, if present. [None] means the
    provider did not report usage; callers must not treat it as zero. *)

val stop_reason_string : api_response -> string
(** The provider's terminal reason as the agent_sdk canonical string
    ("end_turn" | "max_tokens" | "stop_sequence" | "tool_use" | "refusal" |
    "pause_turn" | ...). Feeds [Vision_analyze.done_reason_of_string], which
    maps "end_turn"/"stop" -> [Stop] and "length"/"max_tokens" -> [Length].
    Goes through the SDK stringifier so the variant set has one owner (the SDK);
    repo-local code never re-spells it. *)
