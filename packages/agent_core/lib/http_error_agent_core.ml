(** Shared [Http_client.http_error] -> [Error.t] mapping.

    Keep this adapter above [llm_provider]: the provider layer deliberately
    does not depend on the top-level [Error.t] type. *)

type accept_rejected = Provider_failure_attribution.accept_rejected =
  | Api_invalid_request
  | Config_invalid_config of { field : string }

let of_http_error = Provider_failure_attribution.core_error_of_http_error
