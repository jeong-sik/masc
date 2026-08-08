(** Closed ownership and detailed error evidence for resolved provider calls.

    Existing SDK APIs continue to return {!Error.sdk_error}.  Opt-in detailed
    APIs return {!detailed_error}, whose [error] field is the exact legacy
    projection and whose optional attribution is constructed before typed
    transport evidence is discarded.

    @since 0.211.7 *)

type failure_ownership =
  | Attempt_local
  | Session_local
  | Credential_pool
  | Runtime_binding
  | Endpoint
  | Provider_region
  | Provider
  | Unclassified

type evidence =
  | Http_status of int
  | Network of Llm_provider.Http_client.network_error_kind
  | Timeout of Llm_provider.Http_client.timeout_phase
  | Accept_rejected
  | Provider_terminal of Llm_provider.Http_client.provider_terminal_kind
  | Provider_failure of Llm_provider.Http_client.provider_failure_kind
  | Provider_configuration
  | Request_validation
  | Response_parse
  | Coarse_api_error
  | Coarse_provider_error

type t =
  { ownership : failure_ownership
  ; binding : Binding_identity.t option
  ; evidence : evidence
  }

type detailed_error =
  { error : Error.sdk_error
  ; provider_failure : t option
  }

type accept_rejected =
  | Api_invalid_request
  | Config_invalid_config of { field : string }

(** Lift an already-projected SDK error.  Coarse [Api] and [Provider] errors
    remain explicit [Unclassified] provider evidence with no invented binding;
    non-provider domains carry no provider attribution. *)
val of_sdk_error : Error.sdk_error -> detailed_error

(** A failure while resolving the provider config has no resolved binding.  It
    remains explicitly unclassified instead of being widened downstream. *)
val of_provider_configuration_error : Error.sdk_error -> detailed_error

(** A provider implementation that resolved for this call but is unavailable
    at dispatch time is owned by that exact runtime binding. *)
val of_runtime_binding_error
  :  binding:Binding_identity.t
  -> Error.sdk_error
  -> detailed_error

val of_request_validation_error
  :  binding:Binding_identity.t
  -> Error.sdk_error
  -> detailed_error

val of_response_parse_error
  :  binding:Binding_identity.t
  -> Error.sdk_error
  -> detailed_error

(** Legacy SDK projection used by compatibility adapters.  New provider call
    paths should prefer {!of_http_error} so attribution cannot be discarded
    before the public detailed boundary. *)
val sdk_error_of_http_error
  :  ?accept_rejected:accept_rejected
  -> Llm_provider.Http_client.http_error
  -> Error.sdk_error

(** Central transport-error mapping.  The returned [error] preserves the legacy
    SDK mapping exactly; ownership is derived only from closed/status evidence
    and the OAS-constructed binding identity. *)
val of_http_error
  :  ?accept_rejected:accept_rejected
  -> binding:Binding_identity.t
  -> Llm_provider.Http_client.http_error
  -> detailed_error

val failure_ownership_to_string : failure_ownership -> string

(** Redacted observability projection.  It never includes HTTP bodies, raw
    transport diagnostics, credentials, or full credential digests. *)
val to_yojson : t -> Yojson.Safe.t
