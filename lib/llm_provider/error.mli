(** Provider-level error types.

    Independent of the OAS [Error.sdk_error] hierarchy.

    @stability Internal
    @since 0.93.1 *)

type provider_error =
  | MissingApiKey of { var_name : string }
  | InvalidConfig of
      { field : string
      ; detail : string
      }
  | ParseError of { detail : string }
  | ProviderWireError of
      { provider : string
      ; format : Http_client.provider_wire_format
      ; kind : Http_client.provider_wire_error_kind
      ; detail : string
      }
  (** The accepted provider response violated its declared wire contract.
      This is deliberately distinct from [ParseError], HTTP [RateLimit], and
      provider-owned error envelopes. *)
  | ProviderReportedError of
      { provider : string
      ; error_type : string option
      ; detail : string
      }
  (** A provider-owned error envelope arrived in an otherwise accepted
      response.  Its subtype is diagnostic evidence only; retry policy is
      owned by the caller above OAS. *)
  | UnknownVariant of
      { type_name : string
      ; value : string
      }
  | ProviderUnavailable of
      { provider : string
      ; detail : string
      }
  | RateLimit of
      { provider : string
      ; retry_after : float option
      ; detail : string
      }
  | HardQuota of
      { provider : string
      ; retry_after : float option
      ; detail : string
      }
  | CapacityExhausted of
      { scope : capacity_scope
      ; affected : string list
      ; retry_after : float option
      ; detail : string
      }
  | AuthError of
      { provider : string
      ; detail : string
      }
  | AuthorizationError of
      { provider : string
      ; detail : string
      }
  | ServerError of
      { provider : string
      ; code : int
      ; transient : bool
      ; detail : string
      }
  | NetworkError of
      { provider : string
      ; kind : Http_client.network_error_kind
      ; timeout_phase : Http_client.timeout_phase option
      ; detail : string
      }
  | Timeout of
      { provider : string
      ; timeout_phase : Http_client.timeout_phase option
      ; detail : string
      }
  | InvalidRequest of
      { provider : string
      ; reason : string
      }
  | NotFound of
      { provider : string
      ; detail : string
      }
  | ProviderTerminal of
      { provider : string
      ; reason : string
      ; detail : string
      }

and capacity_scope =
  | CapacityModel
  | CapacityAccount
  | CapacityRegion
  | CapacityProvider
  | CapacityUnknown

val to_string : provider_error -> string
val is_retryable : provider_error -> bool
val capacity_scope_to_string : capacity_scope -> string
val of_retry_api_error : ?provider:string -> Retry.api_error -> provider_error
val of_http_error : ?provider:string -> Http_client.http_error -> provider_error
