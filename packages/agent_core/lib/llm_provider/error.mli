(** Provider-level error types.

    Independent of the AGENT_CORE [Error.t] hierarchy.

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
      owned by the caller above AGENT_CORE. *)
  | UnknownVariant of
      { type_name : string
      ; value : string
      }
  | ProviderUnavailable of
      { provider : string
      ; detail : string
      }
  | EmptyCompletion of
      { provider : string
      ; stop_reason : Types.stop_reason
      ; detail : string
      }
  (** The provider answered with an empty assistant turn and a recognized,
      non-overflow [stop_reason] ([Retry.Empty_attributed]). The reason stays
      typed across the boundary so MASC classifies it by variant; an
      overflow is [ContextOverflow] on the [Api] side and an unmodeled
      stop_reason is [InvalidRequest]. *)
  | RepeatingGeneration of
      { provider : string
      ; shape : Types.repeating_shape
      ; occurrences : int
      ; unit_bytes : int
      ; detail : string
      }
  (** The model's generation repeated one unit past the threshold and the
      client ended the stream. The bytes were intact, so this is not a
      [ProviderWireError]: the failure belongs to the model, and the same
      model reached through another provider repeats the same way. A caller
      rotating candidates should leave the model, not only the connection.
      [is_retryable] is false: the identical request to the same model is the
      same roll. *)
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
      ; kind : Http_client.provider_terminal_kind
      ; detail : string
      }

and capacity_scope =
  | CapacityModel
  | CapacityAccount
  | CapacityRegion
  | CapacityProvider
  | CapacityUnknown

val provider_terminal_reason : Http_client.provider_terminal_kind -> string
(** Display and wire label of a provider terminal kind: ["session_conflict"],
    or the provider's own subtype for [Other]. *)

val to_string : provider_error -> string
val is_retryable : provider_error -> bool
val capacity_scope_to_string : capacity_scope -> string
val of_retry_api_error : ?provider:string -> Retry.api_error -> provider_error
val of_http_error : ?provider:string -> Http_client.http_error -> provider_error
