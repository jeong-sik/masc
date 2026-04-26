(** OAS response helpers.

    Repo-local code should read SDK responses through this module rather than
    reaching into provider-specific helper namespaces. *)

type api_response = Agent_sdk.Types.api_response

(** Extract text content from an API response. *)
val text_of_response : api_response -> string

(** Return the model identifier used for the response. *)
val model_used : api_response -> string

(** Return usage stats, defaulting to zero when absent. *)
val usage_or_zero : api_response -> Agent_sdk.Types.api_usage
