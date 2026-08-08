(** Shared [Http_client.http_error] -> [Error.sdk_error] mapping.

    Keep this adapter above [llm_provider]: the provider layer deliberately
    does not depend on the SDK-wide [Error.sdk_error] type. *)

type accept_rejected = Provider_failure_attribution.accept_rejected =
  | Api_invalid_request
  | Config_invalid_config of { field : string }

let of_http_error = Provider_failure_attribution.sdk_error_of_http_error
