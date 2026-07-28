(** Runtime adapter for Memory OS librarian extraction.

    [Keeper_librarian] owns pure prompt variables and JSON parsing. This module
    owns the side-effect boundary: render external prompts, call OAS, and
    append accepted episodes to [Keeper_memory_os_io]. *)

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
    busy execution slot must not call this, because no attempt happened.

    Uses [Eio_guard.with_mutex] so runtime fibers take a cooperative mutex while
    focused pre-Eio tests keep a direct single-threaded path. *)

val cadence_counter_entries : unit -> int
(** Number of live per-keeper cadence rows. Bounded by the number of keepers
    that have run (one row each), independent of trace rotations — so it is the
    leak-regression signal for the keeper-keyed cadence table and a memory-health
    metric for the dashboard. Read-only.

    Uses [Eio_guard.with_mutex_ro] so runtime fibers take a cooperative mutex
    while focused pre-Eio tests keep a direct single-threaded path. *)

val durable_cadence_due :
  base_path:string -> keeper_id:string -> trace_id:string -> (bool, string) result
(** Advance the restart-safe cadence state for one keeper turn. Runtime
    admission uses this durable state; an unreadable or unwritable state fails
    closed so a restart cannot create an unbounded provider burst. The state is
    paired with the trace it was accumulated in ([cadence_step_keyed]): a
    counter left by a rotated trace does not schedule the new trace, so a short
    trace cannot silently finish without any extraction ever becoming due. *)

val durable_cadence_record_completed_attempt :
  base_path:string -> keeper_id:string -> trace_id:string -> (unit, string) result
(** Reset the restart-safe cadence state after a completed provider attempt,
    whether the structured result was accepted or rejected. The reset is
    recorded against [trace_id], so it only delays subsequent turns of the
    same trace. *)

val max_messages : unit -> int
(** Base per-turn cap on checkpoint messages sent to the librarian prompt. The
    effective prompt window is this value scaled by [cadence_turns] so skipped
    turns are not evicted before the next due extraction. *)

val select_recent_messages
  :  max_messages:int
  -> Agent_sdk.Types.message list
  -> Agent_sdk.Types.message list

val messages_for_librarian
  :  Keeper_librarian.input
  -> (Agent_sdk.Types.message list, string) result

val exact_lane_id : string
(** OAS exact-output lane used by the Librarian. *)

type extraction_error

type extraction_error_kind =
  | Prompt_render_failure
  | Execution_clock_unavailable
  | Store_read_failure
  | Store_snapshot_change
    (** A concurrent writer changed the fact store between the pre-provider
        snapshot and the post-provider apply; the operations were abandoned
        (their indices refer to the stale snapshot) and the next due turn
        re-reads a fresh store. *)
  | Exact_setup_failure
  | Exact_execution_failure
  | Domain_output_invalid
  | Pending_publication_blocked
  | Memory_apply_failure

val extraction_error_kind : extraction_error -> extraction_error_kind

val extraction_error_to_string : extraction_error -> string

val should_record_cadence_backoff_after_error : extraction_error -> bool
(** Whether an extraction error represents enough completed work to defer the
    next attempt until the next cadence window. Completed provider attempts and
    a durable unsettled prior-attempt guard defer cadence; local deterministic
    setup failures stay due. *)

val extract_with_exact_output_classified
  :  ?clock:float Eio.Time.clock_ty Eio.Resource.t
  -> base_path:string
  -> net:[ `Generic | `Unix ] Eio.Net.ty Eio.Resource.t
  -> keeper_id:string
  -> generation:int
  -> Keeper_librarian.input
  -> (Keeper_librarian.recognition_output, extraction_error) result
(** OAS exact-output Librarian recognition pass. Target resolution, capability
    admission, wire materialization, and failover are owned by OAS. MASC
    supplies only the immutable prompt (conversation window + numbered store
    snapshot), domain schema, minimum JSON guarantee, post-success domain
    validation, and an fsync-backed generation journal for OAS's predetermined
    candidate transitions. An unsettled journal blocks only the same trace
    generation; historical pre-release journals are not migrated or consulted.
    [clock] stays optional at the API boundary because [run_best_effort] may be
    called from contexts that cannot supply an Eio clock; [None] returns a
    typed [Execution_clock_unavailable] classification before OAS I/O. *)

(** What an accepted recognition pass produced. A schema-valid empty operation
    list still produces [Recognized] because its episode summary and metadata
    belong to the current conversation slice. It does not rewrite facts, but
    uses an equal-before/after recoverable publication so the episode/event pair
    cannot be stranded across a crash. *)
type recognition_write =
  | Recognized of Keeper_memory_os_types.episode

module For_testing : sig
  val apply_and_persist
    :  ?clock:float Eio.Time.clock_ty Eio.Resource.t
    -> base_path:string
    -> keeper_id:string
    -> generation:int
    -> Keeper_librarian.input
    -> Keeper_librarian.recognition_output
    -> (recognition_write, extraction_error) result

  val persist_cadence_backoff
    :  should_defer:bool
    -> write:(unit -> (unit, string) result)
    -> (bool, string) result

  val reserve_recognition_input :
    keeper_id:string
    -> Keeper_librarian.input
    -> int * Keeper_librarian.input

  val extract_and_append_with
    :  ?clock:float Eio.Time.clock_ty Eio.Resource.t
    -> base_path:string
    -> keeper_id:string
    -> extract:
         (generation:int
          -> Keeper_librarian.input
          -> (Keeper_librarian.recognition_output, extraction_error) result)
    -> Keeper_librarian.input
    -> (recognition_write, extraction_error) result
  (** Test seam around the production preflight/reserve/apply ordering. The
      callback stands only for the provider extraction boundary. *)
end

val repair_pending_publication
  :  ?clock:float Eio.Time.clock_ty Eio.Resource.t
  -> base_path:string
  -> keeper_id:string
  -> action:Keeper_librarian_recognition_ledger.pending_repair
  -> unit
  -> ( Keeper_librarian_recognition_ledger.repair_outcome
       , Keeper_librarian_recognition_ledger.repair_error )
       result
(** Operator-owned resolution for a latched recognition publication. Acquires
    the episode-bundle and facts locks, then performs exactly the explicit
    ledger repair action; it never selects restore/abort/settle heuristically. *)

val repair_pending_publication_for_masc_root
  :  ?clock:float Eio.Time.clock_ty Eio.Resource.t
  -> masc_root:string
  -> keeper_id:string
  -> action:Keeper_librarian_recognition_ledger.pending_repair
  -> unit
  -> ( Keeper_librarian_recognition_ledger.repair_outcome
       , Keeper_librarian_recognition_ledger.repair_error )
       result
(** Exact-root variant for authenticated multi-cluster operator surfaces. *)

val extract_and_append_with_exact_output_classified
  :  ?clock:float Eio.Time.clock_ty Eio.Resource.t
  -> base_path:string
  -> net:[ `Generic | `Unix ] Eio.Net.ty Eio.Resource.t
  -> keeper_id:string
  -> Keeper_librarian.input
  -> (recognition_write, extraction_error) result
(** Full recognition write (masc#26122): settle any pending publication under
    the recognition transaction before provider admission, snapshot the fact
    store, run the exact-output pass with the snapshot in the prompt, revalidate the snapshot
    under the facts lock ([same_fact_snapshot] CAS), apply the typed
    operations ({!Keeper_librarian_recognition.apply} — the store can shrink),
    persist the episode bundle, and append the recognition evidence row
    ({!Keeper_librarian_recognition_ledger}). The input's [store] field is
    overwritten with the fresh snapshot read here. *)

val run_best_effort
  :  base_path:string
  -> keeper_id:string
  -> Keeper_librarian.input
  -> unit
(** Run the opt-in post-turn librarian path.

    Non-cancel failures are logged and counted, never raised. Runtime dispatch
    uses the immutable OAS exact-output registry and [librarian_exact] lane. *)
