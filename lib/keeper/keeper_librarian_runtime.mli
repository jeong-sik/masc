(** Runtime adapter for tool-free LLM-owned current Memory OS selection.

    The exact-output flow receives only the immutable Librarian input. No tool
    output or external research is admitted to the persistent Memory OS
    mutation path. One atomic current-snapshot replacement remains the sole
    mutation authority. *)

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
  :  requirement:Agent_core.Exact_output.output_requirement
  -> selected_slots:Runtime_exact_output_registry.selected_slot list
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


type write_scope = Context_only | Context_and_memory
(** The caller names the evidence's purpose. A queue-source organization pass
    writes only working Context; a durable range retains Memory processing. *)

type not_committed =
  { detail : string
        (** The typed cause, for the caller's log. *)
  ; walk_shows_size : bool
        (** Something this pass met says the range's size is what stopped it:
            a provider that judged the request too large, one that refused it
            for a reason it did not name, a refused output, or a candidate
            whose projection did not fit a slot's declared window.

            False covers everything else, and a caller reading less only when
            this is true is what keeps an outage from shrinking its reads. A
            provider that took the request and could not serve it (quota,
            overload, server, network), a refusal only an operator can lift
            (authentication, authorization, payment, an absent model), and
            every failure that never reached a provider all answer false, as
            does a pass that recorded no typed cause at all.

            The verdict covers every failed visit of the walk, not the last
            one, so the same set of causes answers the same way whatever order
            the slots were tried in. *)
  }

val fit_continuity :
  capacity:Keeper_lane_cli_oneshot.input_capacity -> base_path:string -> keeper_id:string ->
  input:Keeper_librarian.input -> Keeper_librarian_continuity.prepared ->
  (Keeper_librarian_continuity.prepared option, string) result
(** Fit the complete rendered CLI prompt to a reported character limit while its
    runtime remains declared in the lane. Returns [None] if no safe source fits.
    Does not dispatch a provider or change Memory receipts. *)

val run_best_effort
  :  ?write_scope:write_scope
  -> ?continuity:Keeper_librarian_continuity.prepared
  -> ?on_memory_committed:(unit -> unit)
       (** Synchronous observation at the snapshot commit. Must only update
           caller-owned in-memory state, without I/O, yielding or raising. *)
  -> ?on_cli_input_limit:(Keeper_lane_cli_oneshot.input_capacity -> unit)
       (** The character limit a CLI slot reported while refusing, for
           {!fit_continuity}. An API slot's refusal reports none. *)
  -> ?on_not_committed:(not_committed -> unit)
  -> ?on_continuity_committed:(Librarian_continuity_snapshot.t -> unit)
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
(** Execute a Librarian unit already admitted by its producer. The input
    arrives already selected -- a durable range, official-line fragments, or a
    Context-only pass with no messages -- and nothing here trims it.
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
    :  continuity:Keeper_librarian_continuity.prepared option
    -> ?cli_runner:Keeper_lane_cli_oneshot.runner
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
    -> unit
end
