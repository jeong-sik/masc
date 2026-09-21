(** Runtime adapter for tool-free LLM-owned current Memory OS selection.

    The exact-output flow receives only the immutable Librarian input. No tool
    output or external research is admitted to the persistent Memory OS
    mutation path. One atomic current-snapshot replacement remains the sole
    mutation authority. *)

val cadence_step : cadence:int -> counter:int -> int * bool
val cadence_step_keyed
  :  cadence:int
  -> current_trace:string
  -> prior:(string * int) option
  -> (string * int) * bool
val cadence_counter_entries : unit -> int

val prompt_max_messages : unit -> int

(** The immutable input projected into the Librarian prompt. The exact-run
    registry records this value as the actual input, so observability and
    provider dispatch share the same history window. *)
val prompt_input_for_librarian : Keeper_librarian.input -> Keeper_librarian.input

val messages_for_librarian
  :  Keeper_librarian.input
  -> (Agent_core.Types.message list, string) result

type extraction_error

val extraction_error_to_string : extraction_error -> string

(** Slot ids and refusal reasons on one line, for the exclusion WARN and the
    all-slots-refused error. *)
val slot_reason_pairs : ?sep:string -> (string * string) list -> string

type preflight_selection =
  { selected_slots : Runtime_exact_output_registry.selected_slot list
  ; unusable : (string * string) list
  }

val preflight_slots
  :  selected_slots:Runtime_exact_output_registry.selected_slot list
  -> messages:Agent_core.Types.message list
  -> (preflight_selection, extraction_error) result
(** The pre-flight over the ladder: the selected slots whose request projected
    and the slots this run is without (id and refusal reason). The execution
    flow receives only [selected_slots]; a ladder with no projectable slot at
    all is [Exact_request_projection_failed], naming each refusal. An empty
    ladder reports two empty lists -- the caller routes it to the cli lane.
    The execution caller also tries declared CLI slots after all API
    projections are refused, preserving this error if no CLI answer is
    accepted. *)


(** Which failure kind this error records in the memory journal. The vocabulary
    is owned by {!Keeper_memory_os_current} because the journal is the only
    place it reaches disk; this function is the one place the classification
    happens, so adding an [extraction_error] case fails to compile until it
    names its journal kind. *)
type trigger = Conversation_completed | Queue_changed | Durable_range

type write_scope = Context_only | Context_and_memory
(** The caller names the evidence's purpose. A queue-source organization pass
    writes only working Context; remembered conversation and durable ranges
    retain Memory processing regardless of the wake-up trigger. *)

type input_projection =
  | Recent_window
  | Already_selected_range

val run_best_effort
  :  ?trigger:trigger
  -> ?input_projection:input_projection
  -> ?write_scope:write_scope
  -> ?continuity:Keeper_librarian_continuity.prepared
  -> ?on_memory_committed:(unit -> unit)
       (** Synchronous observation at the snapshot commit. Must only update
           caller-owned in-memory state, without I/O, yielding or raising. *)
  -> ?durable_range_id:Keeper_memory_os_current.durable_range_id
  -> ?official_range_id:Keeper_memory_os_current.official_range_id
  -> ?cli_runner:Keeper_lane_cli_oneshot.runner
       (** Injectable effect edge for the cli lane-slot fallback walked after
           catalog exhaustion (RFC cli-runtimes-as-lane-slots); [None] spawns
           the real official client. *)
  -> base_path:string
  -> keepers_dir:string
  -> keeper_id:string
  -> expected_revision:int option
  -> Keeper_librarian.input
  -> unit
(** Execute a Librarian unit already admitted by its producer. The default
    [Recent_window] preserves the direct official-client path. A durable range
    consumer passes [Already_selected_range], because applying the retired
    recent-message window again would drop the front of the selected range.
    [on_memory_committed] runs only after the current Memory OS snapshot write
    succeeds. [durable_range_id] and [official_range_id] are committed through the Memory store's WAL
    sidecar, so a durable consumer can recover a later progress-file failure
    without submitting the completed-turn range again. *)

module For_testing : sig
  val commit_continuity
    : commit:(unit -> (Librarian_continuity_snapshot.t, string) result)
    -> observe:((Librarian_continuity_snapshot.t, string) result -> unit)
    -> unit

  type classified_error

  val classified_error_detail : classified_error -> string
  val classified_error_kind : classified_error -> Keeper_memory_os_current.librarian_failure_kind

  val execute_exact_output_classified
    :  ?cli_runner:Keeper_lane_cli_oneshot.runner
    -> clock:_ Eio.Time.clock
    -> net:[ `Generic | `Unix ] Eio.Net.ty Eio.Resource.t
    -> base_path:string
    -> keeper_id:string
    -> selected_input:Keeper_librarian.input
    -> messages:Agent_core.Types.message list
    -> unit
    -> ( (Keeper_librarian.selection * Yojson.Safe.t) * string
       , classified_error )
       result

  val record_failure
    :  keepers_dir:string
    -> keeper_id:string
    -> trace_id:string
    -> kind:Keeper_memory_os_current.librarian_failure_kind
    -> detail:string
    -> cadence_deferred:bool
    -> unit

  val input_for_projection
    :  input_projection
    -> Keeper_librarian.input
    -> Keeper_librarian.input
end
