(** Runtime adapter for Memory OS librarian extraction.

    [Keeper_librarian] owns pure prompt variables and JSON parsing. This module
    owns the side-effect boundary: render external prompts, call a provider, and
    append accepted episodes to [Keeper_memory_os_io]. *)

type complete_fn =
  sw:Eio.Switch.t ->
  net:[ `Generic | `Unix ] Eio.Net.ty Eio.Resource.t ->
  ?clock:float Eio.Time.clock_ty Eio.Resource.t ->
  config:Llm_provider.Provider_config.t ->
  messages:Agent_sdk.Types.message list ->
  unit ->
  (Agent_sdk.Types.api_response, Llm_provider.Http_client.http_error) result

val max_messages : unit -> int
(** Exact cap on checkpoint messages sent to one librarian operation. *)

val default_timeout_sec : unit -> float
(** Provider timeout for post-turn extraction. Defaults to
    [librarian_default_timeout_sec] (600 s, aligned with the keeper turn budget)
    and can be overridden with [MASC_KEEPER_MEMORY_OS_LIBRARIAN_TIMEOUT_SEC]. *)

val runtime_id_for_librarian : runtime_id:string -> string
(** Runtime id after applying the optional
    [MASC_KEEPER_MEMORY_OS_LIBRARIAN_RUNTIME_ID] override. *)

val select_recent_messages
  :  max_messages:int
  -> Agent_sdk.Types.message list
  -> Agent_sdk.Types.message list

val messages_for_librarian
  :  Keeper_librarian.input
  -> (Agent_sdk.Types.message list, string) result

val provider_for_librarian
  :  Llm_provider.Provider_config.t
  -> Llm_provider.Provider_config.t
(** Provider config specialized for episode extraction. Caps [max_tokens] at
    the librarian output budget (default 4096, overridable with
    [MASC_KEEPER_MEMORY_OS_LIBRARIAN_MAX_TOKENS], floor 1) and requests the
    structured episode output schema. The selected provider config's exact
    temperature is preserved, including omission. *)

val librarian_max_parse_retries : int
(** Additional provider attempts after an initial unparseable response before
    [extract_with_provider] gives up (the initial attempt is not counted). *)

val parse_retry_episode_fields : string list
(** Episode object fields included in the corrective parse-retry shape. *)

val parse_retry_claim_fields : string list
(** Claim object fields included in the corrective parse-retry shape. *)

val parse_retry_nudge : string
(** Corrective instruction appended to the message list on each parse-retry. *)

type extraction_error =
  | Prompt_render_failed of string
  | Provider_clock_unavailable
  | Provider_config_rejected of string
  | Provider_timeout
  | Provider_transport_failed of string
  | Provider_empty_response
  | Provider_unparseable_response of string
  | Memory_fact_upsert_failed of string

val extraction_error_to_string : extraction_error -> string

type unparseable_response =
  { reason : string
  ; raw_evidence : string option
  }

val unparseable_response : ?raw_evidence:string -> string -> unparseable_response
(** Typed retry diagnostic. [raw_evidence] is present only when the provider
    returned non-empty output; [reason] describes that same response so the
    final typed provider error is not replaced by a later empty retry. *)

type attempt_outcome =
  | Parsed of Keeper_memory_os_types.episode
  | Unparseable of unparseable_response
  | Transport_failed of extraction_error

type parse_retry_error =
  | Retry_exhausted_unparseable of unparseable_response
  | Retry_transport_failed of extraction_error

val run_with_parse_retries
  :  max_retries:int
  -> attempt:(Agent_sdk.Types.message list -> attempt_outcome)
  -> Agent_sdk.Types.message list
  -> (Keeper_memory_os_types.episode, parse_retry_error) result
(** Drive [attempt] over a growing message list. Returns immediately on [Parsed].
    [Transport_failed] returns [Retry_transport_failed] without retry. On
    [Unparseable], appends {!parse_retry_nudge} and retries up to [max_retries]
    times before returning [Retry_exhausted_unparseable]. If any retry produced
    non-empty fallback evidence, the exhausted diagnostic preserves that
    evidence with its matching reason instead of pairing it with a later empty
    retry. Pure given a pure [attempt] — the provider side effect lives in the
    [attempt] supplied by {!extract_with_provider}. *)

val librarian_provider_clock_unavailable_error : string
(** Stable error returned before provider I/O when provider-backed librarian
    extraction is called without a clock. Exposed so callers/tests do not
    classify the human diagnostic with substring matching. *)

val extract_with_provider
  :  ?complete:complete_fn
  -> ?clock:float Eio.Time.clock_ty Eio.Resource.t
  -> ?timeout_sec:float
  -> sw:Eio.Switch.t
  -> net:[ `Generic | `Unix ] Eio.Net.ty Eio.Resource.t
  -> runtime_id:string
  -> provider_cfg:Llm_provider.Provider_config.t
  -> generation:int
  -> Keeper_librarian.input
  -> (Keeper_memory_os_types.episode, string) result

val extract_with_provider_classified
  :  ?complete:complete_fn
  -> ?clock:float Eio.Time.clock_ty Eio.Resource.t
  -> ?timeout_sec:float
  -> sw:Eio.Switch.t
  -> net:[ `Generic | `Unix ] Eio.Net.ty Eio.Resource.t
  -> runtime_id:string
  -> provider_cfg:Llm_provider.Provider_config.t
  -> generation:int
  -> Keeper_librarian.input
  -> (Keeper_memory_os_types.episode, extraction_error) result
(** Provider-backed librarian extraction. [clock] stays optional at the API
    boundary for focused callers; [None] returns
    {!librarian_provider_clock_unavailable_error} before provider I/O because
    the provider call itself requires the clock. The extraction now runs to
    completion: [timeout_sec] no longer force-kills a legitimate in-flight
    provider call (that wall-clock kill produced kill -> retry churn; see
    RFC-0156, Withdraw MASC turn-budget timeout policy). An inner-transport
    (connect/idle/HTTP) timeout still surfaces as {!Provider_timeout}. *)

val extract_and_append_with_provider
  :  ?complete:complete_fn
  -> ?clock:float Eio.Time.clock_ty Eio.Resource.t
  -> ?timeout_sec:float
  -> sw:Eio.Switch.t
  -> net:[ `Generic | `Unix ] Eio.Net.ty Eio.Resource.t
  -> keeper_id:string
  -> runtime_id:string
  -> provider_cfg:Llm_provider.Provider_config.t
  -> Keeper_librarian.input
  -> (Keeper_memory_os_types.episode, string) result

val extract_and_append_with_provider_classified
  :  ?complete:complete_fn
  -> ?clock:float Eio.Time.clock_ty Eio.Resource.t
  -> ?timeout_sec:float
  -> sw:Eio.Switch.t
  -> net:[ `Generic | `Unix ] Eio.Net.ty Eio.Resource.t
  -> keeper_id:string
  -> runtime_id:string
  -> provider_cfg:Llm_provider.Provider_config.t
  -> Keeper_librarian.input
  -> (Keeper_memory_os_types.episode, extraction_error) result

type operation_request =
  { runtime_id : string
  ; keeper_id : string
  ; input : Keeper_librarian.input
  }
(** Immutable input for one explicitly requested LLM Memory operation. *)

type operation_error =
  | Eio_context_unavailable
  | Runtime_resolution_failed of string
  | Direct_completion_unsupported
  | Extraction_failed of extraction_error
  | Unexpected_failure of string

val operation_error_to_string : operation_error -> string

val execute_operation
  :  ?complete:complete_fn
  -> ?timeout_sec:float
  -> operation_request
  -> (Keeper_memory_os_types.episode, operation_error) result
(** Execute one explicitly requested LLM Memory operation.

    This boundary never converts failure into [unit]. Cancellation propagates;
    every other outcome
    is returned to its caller. Production execution is claimed by the durable
    per-Keeper owner drain before entering this function; no provider-slot drop
    or replacement concurrency heuristic exists here. *)
