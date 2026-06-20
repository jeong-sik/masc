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
(** Opt-in gate controlled by [MASC_KEEPER_MEMORY_OS_LIBRARIAN]. *)

val cadence_turns : unit -> int
(** Turns between librarian extractions per keeper. Default 3, floored at 1,
    overridable with [MASC_KEEPER_MEMORY_OS_LIBRARIAN_CADENCE_TURNS]. 1 restores
    per-turn extraction. *)

val cadence_step : cadence:int -> counter:int -> int * bool
(** Pure cadence decision. [(updated_counter, due)] for a keeper whose counter
    (turns since last successful extraction) is [counter] under [cadence].
    [counter < 0] is treated as a fresh (keeper, trace) and is due immediately.
    cadence<=1 is always due with the counter pinned at 0. When due, the updated
    counter is set to [cadence] and stays there until [cadence_record_success]
    resets it. Exposed for testing the cadence logic without the per-keeper
    counter table. *)

val cadence_max_entries : int
(** Soft cap on the cadence counter table: once it exceeds this many entries,
    [cadence_due] reclaims entries untouched past the staleness horizon. Exposed
    so the bound's regression test does not hardcode the threshold. *)

val cadence_due : keeper_id:string -> trace_id:string -> bool
(** Advance the persistent cadence counter for ([keeper_id], [trace_id]) by one
    turn and report whether extraction is due now. This is what
    [run_best_effort] gates on. The counter is scoped to the active trace so a
    handoff rollover starts a fresh cadence cycle. First call for an unseen pair
    is due immediately. As a side effect it reclaims dead-trace entries (see
    [cadence_due_at]) so the counter table stays bounded. *)

val cadence_due_at : now:float -> keeper_id:string -> trace_id:string -> bool
(** [cadence_due] with an explicit wall-clock [now]. Before reading the counter
    it prunes entries untouched past the staleness horizon once the table exceeds
    [cadence_max_entries], so dead traces from handoff rollovers do not
    accumulate without bound; entries in active rotation are kept, preserving
    per-trace independence. [cadence_due] is this with [now = Time_compat.now ()].
    Exposed with an explicit clock so the prune is testable deterministically. *)

val cadence_record_success : keeper_id:string -> trace_id:string -> unit
(** Record a successful extraction for ([keeper_id], [trace_id]) so the cadence
    counter resets and the next cycle can begin. Must only be called after a
    due turn actually produced an episode; skipped or failed attempts must not
    call this. *)

val cadence_tracked_pairs : unit -> int
(** Number of [(keeper_id, trace_id)] cadence entries currently tracked. Bounded
    by the dead-trace prune in [cadence_due_at]. Read-only; exposed for that
    bound's regression test and for diagnostics. *)

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

val messages_for_librarian
  :  Keeper_librarian.input
  -> (Agent_sdk.Types.message list, string) result

val provider_for_librarian
  :  Llm_provider.Provider_config.t
  -> Llm_provider.Provider_config.t

val librarian_max_parse_retries : int
(** Additional provider attempts after an initial unparseable response before
    [extract_with_provider] gives up (the initial attempt is not counted). *)

val parse_retry_nudge : string
(** Corrective instruction appended to the message list on each parse-retry. *)

type attempt_outcome =
  | Parsed of Keeper_memory_os_types.episode
  | Unparseable of string
  | Transport_failed of string

val run_with_parse_retries
  :  max_retries:int
  -> attempt:(Agent_sdk.Types.message list -> attempt_outcome)
  -> Agent_sdk.Types.message list
  -> (Keeper_memory_os_types.episode, string) result
(** Drive [attempt] over a growing message list. Returns immediately on [Parsed]
    (Ok) and [Transport_failed] (Error); on [Unparseable], appends
    {!parse_retry_nudge} and retries up to [max_retries] times before returning
    the last error. Pure given a pure [attempt] — the provider side effect lives
    in the [attempt] supplied by {!extract_with_provider}. *)

val global_slot_capacity : unit -> int
(** Fleet-wide librarian provider gate capacity from
    [MASC_KEEPER_MEMORY_OS_LIBRARIAN_GLOBAL_SLOT] (default 1, 0 disables the
    gate). *)

val with_provider_slot
  :  ?clock:float Eio.Time.clock_ty Eio.Resource.t
  -> (unit -> 'a)
  -> 'a option
(** Run [f] under the fleet-wide librarian provider gate — the #21230
    storm-guard the per-keeper lane keeps as an optional fleet-wide cap. At
    capacity N, the (N+1)-th concurrent entrant returns [None] after
    [provider_slot_wait_sec] when [clock] is supplied (drop, not block);
    capacity 0 disables the gate so [f] always runs ([Some]). Exposed for
    storm-guard regression coverage (#21376). *)

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

val extract_and_append_with_provider
  :  ?complete:complete_fn
  -> ?clock:float Eio.Time.clock_ty Eio.Resource.t
  -> ?timeout_sec:float
  -> sw:Eio.Switch.t
  -> net:[ `Generic | `Unix ] Eio.Net.ty Eio.Resource.t
  -> keeper_id:string
  -> provider_cfg:Llm_provider.Provider_config.t
  -> Keeper_librarian.input
  -> (Keeper_memory_os_types.episode, string) result

val run_best_effort
  :  ?complete:complete_fn
  -> ?timeout_sec:float
  -> runtime_id:string
  -> keeper_id:string
  -> Keeper_librarian.input
  -> unit
(** Run the opt-in post-turn librarian path.

    Non-cancel failures are logged and counted, never raised. *)
