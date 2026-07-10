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

val enabled : unit -> bool
(** Default-on gate with [MASC_KEEPER_MEMORY_OS_LIBRARIAN] as the explicit kill
    switch. *)

val cadence_turns : unit -> int
(** Turns between librarian extractions per keeper. Default 3, floored at 1,
    overridable with [MASC_KEEPER_MEMORY_OS_LIBRARIAN_CADENCE_TURNS]. 1 restores
    per-turn extraction. *)

type cadence_decision =
  | Due
  | Not_due of { turns_remaining : int }

val cadence_decision_for_keeper_turn :
  cadence:int -> keeper_turn:int -> cadence_decision
(** Pure, restart-stable cadence decision derived from the Keeper's durable
    timeline turn id. Turn ids zero and one are the initial due state;
    subsequent due turns are spaced exactly [cadence] turns apart. *)

type librarian_admission_decision =
  | Admission_disabled
  | Admission_not_due of { turns_remaining : int }
  | Admission_due

val decide_librarian_admission :
  keeper_turn:int -> librarian_admission_decision

val librarian_admission_decision_to_json :
  librarian_admission_decision -> Yojson.Safe.t

val librarian_admission_decision_of_json :
  Yojson.Safe.t -> (librarian_admission_decision, string) result

val max_messages : unit -> int
(** Base per-turn cap on checkpoint messages sent to the librarian prompt. The
    effective prompt window is this value scaled by [cadence_turns] so skipped
    turns are not evicted before the next due extraction. *)

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

val prompt_window_messages
  :  Agent_sdk.Types.message list
  -> Agent_sdk.Types.message list
(** Snapshot exactly the bounded raw-message window that
    {!messages_for_librarian} will consume. Durable memory jobs use this helper
    so the cadence/window policy has one SSOT and job payloads do not duplicate
    an entire unbounded checkpoint history. *)

val messages_for_librarian
  :  Keeper_librarian.input
  -> (Agent_sdk.Types.message list, string) result

val provider_for_librarian
  :  Llm_provider.Provider_config.t
  -> Llm_provider.Provider_config.t
(** Provider config specialized for episode extraction. Caps [max_tokens] at
    the librarian output budget (default 4096, overridable with
    [MASC_KEEPER_MEMORY_OS_LIBRARIAN_MAX_TOKENS], floor 1) and requests the
    structured episode output schema. *)

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
  | Memory_episode_persistence_failed of string

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
  -> provider_cfg:Llm_provider.Provider_config.t
  -> generation:int
  -> Keeper_librarian.input
  -> (Keeper_memory_os_types.episode, extraction_error) result
(** Provider-backed librarian extraction. [clock] stays optional at the API
    boundary because [run_best_effort] may be called from contexts that cannot
    supply an Eio clock; [None] returns
    {!librarian_provider_clock_unavailable_error} before provider I/O so
    production calls cannot silently run without timeout enforcement. *)

val extract_and_append_with_provider
  :  ?operation_id:string
  -> ?complete:complete_fn
  -> ?clock:float Eio.Time.clock_ty Eio.Resource.t
  -> ?keepers_dir:string
  -> ?timeout_sec:float
  -> sw:Eio.Switch.t
  -> net:[ `Generic | `Unix ] Eio.Net.ty Eio.Resource.t
  -> keeper_id:string
  -> provider_cfg:Llm_provider.Provider_config.t
  -> Keeper_librarian.input
  -> (Keeper_memory_os_types.episode, string) result

val extract_and_append_with_provider_classified
  :  ?operation_id:string
  -> ?complete:complete_fn
  -> ?clock:float Eio.Time.clock_ty Eio.Resource.t
  -> ?keepers_dir:string
  -> ?timeout_sec:float
  -> sw:Eio.Switch.t
  -> net:[ `Generic | `Unix ] Eio.Net.ty Eio.Resource.t
  -> keeper_id:string
  -> provider_cfg:Llm_provider.Provider_config.t
  -> Keeper_librarian.input
  -> (Keeper_memory_os_types.episode, extraction_error) result

val commit_staged_operation
  :  keepers_dir:string
  -> ?clock:float Eio.Time.clock_ty Eio.Resource.t
  -> keeper_id:string
  -> operation_id:string
  -> Keeper_memory_os_io.operation_episode
  -> (unit, extraction_error) result
(** Publish an already staged provider result without re-running enablement,
    cadence, runtime resolution, or provider gates. *)

type skip_reason =
  | Librarian_disabled
  | Cadence_not_due

type run_error =
  | Eio_context_unavailable
  | Runtime_resolution_failed of string
  | Provider_not_direct_completion
  | Extraction_failed of extraction_error
  | Unexpected_failure of string

type run_outcome =
  | Run_skipped of
      { runtime_id : string
      ; model_id : string option
      ; reason : skip_reason
      ; latency_ms : float
      ; next_due_after_turns : int option
      }
  | Run_succeeded of
      { runtime_id : string
      ; model_id : string
      ; episode : Keeper_memory_os_types.episode
      ; provider_latency_ms : float
      ; latency_ms : float
      ; next_due_after_turns : int
      }
  | Run_failed of
      { runtime_id : string
      ; model_id : string option
      ; error : run_error
      ; latency_ms : float
      ; next_due_after_turns : int
      }

val run_outcome_to_json : run_outcome -> Yojson.Safe.t
val run_outcome_is_failure : run_outcome -> bool

val run_best_effort
  :  ?operation_id:string
  -> ?complete:complete_fn
  -> ?timeout_sec:float
  -> keepers_dir:string
  -> admission_decision:librarian_admission_decision
  -> runtime_id:string
  -> keeper_id:string
  -> Keeper_librarian.input
  -> run_outcome
(** Run the opt-in post-turn librarian path and return its typed terminal
    outcome.

    Non-cancel failures are logged and counted, never raised or flattened into
    a successful unit result. *)
