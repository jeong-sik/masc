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
val prompt_input_for_librarian
  :  ?max_messages:int
  -> Keeper_librarian.input
  -> Keeper_librarian.input
(** [?max_messages] overrides the configured window; the byte-budget fit
    search shrinks through it when the full prompt exceeds an admitted
    slot's request-body limit. *)

val messages_for_librarian
  :  Keeper_librarian.input
  -> (Agent_core.Types.message list, string) result

type extraction_error

val extraction_error_to_string : extraction_error -> string

(** What one slot's pre-flight projection said: it fits, it is over the slot's
    request-body limit, or the projection refused the request outright -- a
    capability or serialization refusal, which is structural, not a size. *)
type slot_projection =
  | Slot_fits
  | Slot_too_large
  | Slot_unusable of string

(** The ladder's pre-flight verdict: which slot ids still impose the
    request-body bound, which are structurally unusable (with the refusal
    reason), and whether every usable slot's body fits its limit. *)
type lane_fit = {
  usable : string list;
  unusable : (string * string) list;
  fits : bool;
}

(** The size decision, pure over one projection per slot in ladder order.
    Structurally unusable slots leave the decision: they impose no bound
    because they cannot run, and one such slot used to fail the whole
    pre-flight, taking every usable slot down with it (2026-09-11,
    openrouter.openrouter-deepseek-v4-flash). *)
val fit_decision : (string * slot_projection) list -> lane_fit

(** Slot ids and refusal reasons on one line, for the exclusion WARN and the
    all-slots-refused error. *)
val slot_reason_pairs : ?sep:string -> (string * string) list -> string

val project_lane
  :  selected_slots:Runtime_exact_output_registry.selected_slot list
  -> messages:Agent_core.Types.message list
  -> lane_fit
(** One real projection per admitted slot. *)

val fitted_messages
  :  selected_slots:Runtime_exact_output_registry.selected_slot list
  -> full_messages:Agent_core.Types.message list
  -> render_at:(int -> (Agent_core.Types.message list, extraction_error) result)
  -> ( (Agent_core.Types.message list * int option)
       * (string * string) list
     , extraction_error )
     result
(** Pre-flight size discipline (lane audit W1/W2): the full prompt is kept
    when it fits every usable slot's request-body limit; otherwise the
    message window binary-searches down through [render_at] and the fitted
    count rides along as [Some k]. Zero-message overflow is
    [Exact_input_over_budget]. A slot whose projection is refused outright is
    excluded from the bound and returned in the report so the caller can say
    which slots the run is without; a ladder with no projectable slot at all
    is [Exact_request_projection_failed], naming each refusal. *)


(** Which failure kind this error records in the memory journal. The vocabulary
    is owned by {!Keeper_memory_os_current} because the journal is the only
    place it reaches disk; this function is the one place the classification
    happens, so adding an [extraction_error] case fails to compile until it
    names its journal kind. *)
val run_best_effort
  :  ?cli_runner:Keeper_lane_cli_oneshot.runner
       (** Injectable effect edge for the cli lane-slot fallback walked after
           catalog exhaustion (RFC cli-runtimes-as-lane-slots); [None] spawns
           the real official client. *)
  -> base_path:string
  -> keepers_dir:string
  -> keeper_id:string
  -> expected_revision:int option
  -> Keeper_librarian.input
  -> unit
(** Execute a Librarian unit already admitted and fenced by the post-turn
    entrypoint. This runtime owns cadence, not the live configuration gate. *)

module For_testing : sig
  type classified_error

  val classified_error_detail : classified_error -> string

  val execute_exact_output_classified
    :  ?cli_runner:Keeper_lane_cli_oneshot.runner
    -> clock:_ Eio.Time.clock
    -> net:[ `Generic | `Unix ] Eio.Net.ty Eio.Resource.t
    -> base_path:string
    -> keeper_id:string
    -> selected_input:Keeper_librarian.input
    -> messages:Agent_core.Types.message list
    -> render_at:(int -> (Agent_core.Types.message list, classified_error) result)
    -> unit
    -> ( (Keeper_librarian.selection * Yojson.Safe.t) * string * int option
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
end
