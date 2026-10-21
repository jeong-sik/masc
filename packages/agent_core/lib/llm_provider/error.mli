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
  (** The provider answered with an empty assistant turn. Both recognized
      non-overflow reasons and unmodeled tokens retain provider, typed reason
      and diagnostic detail. Consumers use [Retry.verdict_of_empty_completion]
      to distinguish recoverable model output from an unknown provider contract;
      an unknown token is not an invalid request or evidence of overflow.
      The core boundary promotes a known overflow to [Api ContextOverflow]. *)
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

val is_repeating_generation : provider_error -> bool
(** [true] only for [RepeatingGeneration]: the model repeated one unit of
    output until accept refused it. *)

val timeout_phase_is_local_admission : Http_client.timeout_phase option -> bool
(** [true] for [Queue] and [Capacity_backpressure]: the wait expired in MASC's
    own permit queue or local capacity gate, before anything reached the
    provider. [None] and every other phase are [false]. *)

val is_local_admission_timeout : provider_error -> bool
(** [true] only for [Timeout] whose phase satisfies
    {!timeout_phase_is_local_admission}. [NetworkError] carrying a
    [timeout_phase] is [false]. *)

val is_candidate_access_rejection : provider_error -> bool
(** [true] for [AuthError], [AuthorizationError] and [NotFound]: the candidate
    refused this credential or does not serve this model, so the next
    candidate may succeed where this one cannot. *)

val is_end_turn_empty_completion : provider_error -> bool
(** [true] only for [EmptyCompletion] whose stop_reason is [EndTurn]: the
    provider finished its turn and returned no content. An empty completion
    with any other stop reason ([MaxTokens], [Refusal], [PauseTurn], an
    unknown one) reports a turn that was cut short and is [false]. *)
