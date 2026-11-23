(** Runtime adapter for the tool-free working-context Librarian pass.

    Organizes pending sources into the Keeper's working context through the
    [librarian_exact] lane and [Keeper_librarian_context_review], without
    reading or mutating current Memory OS snapshots. *)

val working_context_messages
  :  Keeper_librarian.input
  -> (Llm_provider.Types.message list, string) result

type extraction_error

val extraction_error_to_string : extraction_error -> string

type slot_refusal =
  { slot_id : string
  ; cause : Agent_core.Exact_output.admission_error
  }

(** Render each rejected slot and its typed admission cause once, for the
    exclusion WARN and the all-slots-refused error. *)
val slot_reason_pairs : ?sep:string -> slot_refusal list -> string

type preflight_selection =
  { selected_slots : Runtime_exact_output_registry.selected_slot list
  ; unusable : slot_refusal list
  }

val preflight_slots
  :  requirement:Agent_core.Exact_output.output_requirement
  -> selected_slots:Runtime_exact_output_registry.selected_slot list
  -> messages:Llm_provider.Types.message list
  -> (preflight_selection, extraction_error) result
(** The pre-flight over the ladder: the selected slots whose request projected
    and the slots this run is without (id and typed admission cause). *)

type served_slot =
  | Api_slot of string
      (** An API slot, named by its exact-output flow candidate id. *)
  | Cli_slot of string
      (** A CLI slot, named by its lane runtime id -- the id a CLI's
          {!Keeper_lane_cli_oneshot.input_capacity} carries. *)

val served_slot_id : served_slot -> string

type input_capacity_evidence =
  | No_input_capacity_refusal
  | Input_capacity_refused

type message_descent =
  | No_descent_evidence
  | Smaller_input_may_help
  | Invalid_output_blocks_descent
  | Unsettled_native_blocks_descent

type failure_kind =
  | Prompt_render_failure
  | Execution_clock_unavailable
  | Exact_setup_failure
  | Exact_execution_failure
  | Domain_output_invalid
  | Runtime_context_unavailable
  | Lane_cancelled
  | Unhandled_exception

type not_committed =
  { input_capacity_evidence : input_capacity_evidence
  ; input_capacity_only : bool
  ; message_descent : message_descent
  ; provider_input_refusals : Keeper_exact_input_refusal.t list
  ; detail : string
  ; walk_shows_size : bool
  ; smaller_range_meets_same_failure : bool
  }

val not_committed_of_failure : detail:string -> Keeper_exact_walk_failure.t -> not_committed

val run_best_effort
  :  ?on_cli_input_limit:(Keeper_lane_cli_oneshot.input_capacity -> unit)
  -> ?on_not_committed:(not_committed -> unit)
  -> ?on_context_committed:(Keeper_librarian_context.version -> unit)
       (** The working-context version this pass wrote, observed right after
           that write succeeds. Must only update caller-owned in-memory state,
           without I/O, yielding or raising. *)
  -> ?cli_runner:Keeper_lane_cli_oneshot.runner
       (** Injectable effect edge for the cli lane-slot fallback walked after
           catalog exhaustion; [None] spawns the real official client. *)
  -> base_path:string
  -> keepers_dir:string
  -> keeper_id:string
  -> Keeper_librarian.input
  -> unit
(** Execute one working-context organization pass for pending sources. *)

module For_testing : sig
  val cause_input_refusals
    :  Agent_core.Exact_output.execution_error_cause
    -> Keeper_exact_input_refusal.t list

  val cause_shows_size : Agent_core.Exact_output.execution_error_cause -> bool
  val cli_failure_shows_size : Keeper_lane_cli_oneshot.failure -> bool
  val disposition_shows_size : Agent_core.Exact_output.candidate_rejection_disposition -> bool

  type classified_error

  val classified_error_detail : classified_error -> string
  val classified_error_kind : classified_error -> failure_kind

  val execute_working_context_classified
    :  ?cli_runner:Keeper_lane_cli_oneshot.runner
    -> clock:_ Eio.Time.clock
    -> net:[ `Generic | `Unix ] Eio.Net.ty Eio.Resource.t
    -> base_path:string
    -> keeper_id:string
    -> selected_input:Keeper_librarian.input
    -> messages:Llm_provider.Types.message list
    -> unit
    -> ((Keeper_librarian_context.pocket list * Yojson.Safe.t) * served_slot, classified_error)
       result

  val record_failure
    :  keepers_dir:string
    -> keeper_id:string
    -> trace_id:string
    -> kind:failure_kind
    -> detail:string
    -> unit
end
