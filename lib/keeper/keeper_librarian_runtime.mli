(** Runtime adapter for Memory OS librarian extraction.

    [Keeper_librarian] owns pure prompt variables and JSON parsing. This module
    owns the side-effect boundary: render external prompts, call a provider, and
    append accepted episodes to [Keeper_memory_os_io]. *)

type complete_fn = Keeper_provider_subcall.complete_fn

val enabled : unit -> bool
(** Opt-in gate controlled by [MASC_KEEPER_MEMORY_OS_LIBRARIAN]. *)

val cadence_turns : unit -> int
(** Turns between librarian extractions per keeper. Default 3, floored at 1,
    overridable with [MASC_KEEPER_MEMORY_OS_LIBRARIAN_CADENCE_TURNS]. 1 restores
    per-turn extraction. *)

val cadence_step : cadence:int -> counter:int -> int * bool
(** Pure cadence decision. [(updated_counter, due)] for a keeper whose counter
    (turns since last successful extraction) is [counter] under [cadence].
    [counter < 0] is treated as fresh and is due immediately.
    cadence<=1 is always due with the counter pinned at 0. When due, the updated
    counter is set to [cadence] and stays there until [cadence_record_success] or
    [cadence_record_attempt] resets it. Skipped work leaves the counter due;
    completed non-success attempts may be recorded to wait for the next cadence
    window. Exposed for testing the cadence logic without the per-keeper counter
    table. *)

val cadence_step_keyed
  :  cadence:int
  -> current_trace:string
  -> prior:(string * int) option
  -> (string * int) * bool
(** Pure keyed cadence decision. Given a keeper's [prior] stored
    [(trace, counter)] and the [current_trace], returns the [(trace, counter)]
    value to store and whether extraction is due now. A [prior] from a different
    (rotated) trace, or [None], is treated as fresh — due immediately, not
    inheriting the old trace's schedule. Exposed for testing the rollover
    decision without the global table. *)

val cadence_due : keeper_id:string -> trace_id:string -> bool
(** Advance the persistent cadence counter for [keeper_id] by one turn and
    report whether extraction is due now. This is what [run_best_effort] gates
    on. The counter is keyed by [keeper_id] and stores the active [trace_id]
    alongside it, so a handoff rollover (a new [trace_id]) resets the cadence
    cycle in place — bounding the table to one row per keeper. First call for an
    unseen keeper, or the first call after a rollover, is due immediately.

    Uses [Eio_guard.with_mutex] so runtime fibers take a cooperative mutex while
    focused pre-Eio tests keep a direct single-threaded path. *)

val cadence_record_success : keeper_id:string -> trace_id:string -> unit
(** Record a successful structured extraction for [keeper_id] on [trace_id] so
    the cadence counter resets and the next cycle can begin. Must only be called
    after a due turn actually produced a structured episode; skipped, failed, or
    unparseable provider attempts must not call this.

    Uses [Eio_guard.with_mutex] so runtime fibers take a cooperative mutex while
    focused pre-Eio tests keep a direct single-threaded path. *)

val cadence_record_attempt : keeper_id:string -> trace_id:string -> unit
(** Record a completed non-success extraction attempt for [keeper_id] on
    [trace_id] so transient provider failures and unparseable structured-output
    failures do not immediately retry every keeper turn. This intentionally does
    not mark the extraction as semantically successful. Skipped work such as a
    busy provider slot must not call this, because no provider attempt happened.

    Uses [Eio_guard.with_mutex] so runtime fibers take a cooperative mutex while
    focused pre-Eio tests keep a direct single-threaded path. *)

val cadence_counter_entries : unit -> int
(** Number of live per-keeper cadence rows. Bounded by the number of keepers
    that have run (one row each), independent of trace rotations — so it is the
    leak-regression signal for the keeper-keyed cadence table and a memory-health
    metric for the dashboard. Read-only.

    Uses [Eio_guard.with_mutex_ro] so runtime fibers take a cooperative mutex
    while focused pre-Eio tests keep a direct single-threaded path. *)

val memory_os_librarian_provider_slot_site : string
(** OTel [site] label used when the fleet-wide librarian provider slot is busy.
    The producer and dashboard health reader share this value so label drift
    cannot silently hide provider-slot-busy alerts. *)

val max_messages : unit -> int
(** Base per-turn cap on checkpoint messages sent to the librarian prompt. The
    effective prompt window is this value scaled by [cadence_turns] so skipped
    turns are not evicted before the next due extraction. *)

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

val should_record_cadence_backoff_after_error : extraction_error -> bool
(** Whether an extraction error represents enough completed work to defer the
    next attempt until the next cadence window. Only completed provider-attempt
    failures should defer cadence; local deterministic failures stay due. *)

val per_keeper_slot_capacity : unit -> int
(** Per-keeper librarian provider slot capacity from
    [MASC_KEEPER_MEMORY_OS_LIBRARIAN_GLOBAL_SLOT] (default 1, 0 disables the
    gate). The capacity is applied per keeper, not fleet-wide. *)

val with_provider_slot
  :  keeper_id:string
  -> clock:float Eio.Time.clock_ty Eio.Resource.t
  -> (unit -> 'a)
  -> 'a option
(** Run [f] under the per-keeper librarian provider slot — the #21230/P0-4
    storm guard. At capacity N per keeper, the (N+1)-th concurrent entrant for
    the same keeper returns [None] immediately (drop, not block); capacity 0
    disables the gate so [f] always runs ([Some]). The
    provider slot registry is guarded through [Eio_guard.with_mutex], avoiding
    blocking stdlib locks on keeper runtime fibers. Exposed for storm-guard
    regression coverage (#21376). *)

val librarian_provider_clock_unavailable_error : string
(** Stable error returned before provider I/O when provider-backed librarian
    extraction is called without a clock. Exposed so callers/tests do not
    classify the human diagnostic with substring matching. *)

val extract_with_provider
  :  ?complete:complete_fn
  -> ?clock:float Eio.Time.clock_ty Eio.Resource.t
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
  -> sw:Eio.Switch.t
  -> net:[ `Generic | `Unix ] Eio.Net.ty Eio.Resource.t
  -> runtime_id:string
  -> provider_cfg:Llm_provider.Provider_config.t
  -> generation:int
  -> Keeper_librarian.input
  -> (Keeper_memory_os_types.episode, extraction_error) result
(** Provider-backed librarian extraction. [clock] stays optional at the API
    boundary because [run_best_effort] may be called from contexts that cannot
    supply an Eio clock; [None] returns
    {!librarian_provider_clock_unavailable_error} before provider I/O because
    the provider call itself requires the clock. The extraction now runs to
    completion: [timeout_sec] no longer force-kills a legitimate in-flight
    provider call (that wall-clock kill produced kill -> retry churn; see
    RFC-0156, Withdraw MASC turn-budget timeout policy). An inner-transport
    (connect/idle/HTTP) timeout still surfaces as {!Provider_timeout}. *)

val extract_and_append_with_provider
  :  ?complete:complete_fn
  -> ?clock:float Eio.Time.clock_ty Eio.Resource.t
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
  -> sw:Eio.Switch.t
  -> net:[ `Generic | `Unix ] Eio.Net.ty Eio.Resource.t
  -> keeper_id:string
  -> runtime_id:string
  -> provider_cfg:Llm_provider.Provider_config.t
  -> Keeper_librarian.input
  -> (Keeper_memory_os_types.episode, extraction_error) result

val run_best_effort
  :  ?complete:complete_fn
  -> runtime_id:string
  -> keeper_id:string
  -> Keeper_librarian.input
  -> unit
(** Run the opt-in post-turn librarian path.

    Non-cancel failures are logged and counted, never raised. *)
