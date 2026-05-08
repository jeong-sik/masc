(** OAS response helpers.

    Repo-local code should read SDK responses through this module rather than
    reaching into provider-specific helper namespaces. *)

type api_response = Agent_sdk.Types.api_response

val text_of_response : api_response -> string
(** Extract text content from an API response. *)

val model_used : api_response -> string
(** Return the model identifier used for the response. *)

val usage : api_response -> Agent_sdk.Types.api_usage option
(** Return provider-reported usage stats, if present. [None] means the
    provider did not report usage; callers must not treat it as zero. *)
