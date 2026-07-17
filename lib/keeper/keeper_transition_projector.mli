(** Synchronous projection of one Keeper lane's durable queue transition.

    The projector appends every stimulus reaction in source order and retires
    the transition only after every append succeeds. *)

type projection_failure =
  | Queue_read_failed of { detail : string }
  | Reaction_append_failed of
      { transition_id : string
      ; stimulus_post_id : string
      ; detail : string
      }
  | Projection_mark_failed of
      { transition_id : string
      ; detail : string
      }
  | Multiple_unprojected_transitions of { count : int }

type projection_report =
  { projected_transition_count : int
  ; projected_stimulus_count : int
  }

val project_transition_outbox :
  base_path:string ->
  keeper_name:string ->
  (projection_report, projection_failure) result
(** Project the lane's current transition outbox synchronously. An empty
    outbox succeeds with zero counts. More than one entry is an explicit state
    invariant failure. *)

val projection_failure_to_string : projection_failure -> string
(** Preserve the existing heartbeat boundary's textual failure contract. *)
