(** The runtime a Keeper turn's outcome is credited to.

    How a runtime walk ended decides it, and the turn execution reports that
    here once, so the registry, the composite observer and the operator
    screens name the same runtime. *)

(** How a runtime walk ended, as far as naming the runtime goes. *)
type attempt_end =
  | Completed of
      { runtime_id : string
      ; selected_model : string option
      }
      (** The walk returned a result and the turn finished with it. *)
  | Failed of
      { answering_runtime_id : string option
          (** Set when the walk returned a result that finalization then
              rejected: the candidate that answered. *)
      ; terminal_origin_runtime_id : string option
          (** Set when the walk returned a candidate's error as the lane's
              error: the candidate that produced it. It can be an earlier
              candidate than the last one dispatched, when its typed
              overflow outranked a later error. *)
      }

(** [Completed] names the runtime and its model. [Failed] names the
    answering candidate first, else the terminal origin, with no model. [None]
    when no candidate was dispatched. *)
val selected_runtime : attempt_end -> Keeper_registry_types.selected_runtime option
