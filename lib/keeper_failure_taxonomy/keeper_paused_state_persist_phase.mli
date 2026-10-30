(** Keeper_paused_state_persist_phase — closed sum for the [phase] label on
    [metric_keeper_paused_state_persist_errors].

    Replaces hardcoded string literals in the dashboard Keeper API.
    Each phase corresponds to a distinct write path; closing the set
    forces every emit site through the compiler. *)

type t =
  | Lifecycle_pause_persist
  (** Persist-time failure while shutdown/clear retains a paused Keeper. *)
  | Directive
  (** Failure persisting an operator-issued pause directive
          (e.g. POST /dashboard/api/keepers/:name/pause). *)

val to_label : t -> string
