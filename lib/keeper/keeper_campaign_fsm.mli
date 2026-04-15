(** Keeper_campaign_fsm — pure campaign goal-reaching sub-FSM.

    This FSM tracks mission progress on top of the keeper lifecycle FSM.
    It deliberately does not own runtime liveness; it only models
    goal-reaching progress for the keeper-only campaign harness. *)

type phase =
  | Bootstrapping
  | Claiming_task
  | Task_bound
  | Searching
  | Target_reached
  | Pressure_testing
  | Continuity_verified
  | Stalled
  | Escalated

type snapshot = {
  phase : phase;
  goal : string option;
  task_id : string option;
  current_task_id : string option;
  loop_id : string option;
  target_score : float option;
  target_reached : bool;
  compaction_count : int;
  handoff_count : int;
  continuity_goal_matches : bool option;
  continuity_task_matches : bool option;
  reason : string option;
}

type event =
  | Bootstrap_ok of { goal : string }
  | Task_bound_observed of { task_id : string; current_task_id : string }
  | Autoresearch_started of {
      loop_id : string;
      target_score : float option;
    }
  | Target_reached_event
  | Pressure_started
  | Compaction_observed of { count : int }
  | Handoff_observed of {
      count : int;
      generation : int option;
      trace_id : string option;
    }
  | Continuity_observed of {
      goal_matches : bool;
      current_task_id : string option;
    }
  | Window_exhausted of { reason : string }
  | Error_observed of { reason : string }

val initial : snapshot
val phase_to_string : phase -> string
val phase_of_string : string -> phase option
val phase_terminal : phase -> bool
val verdict_of_phase : phase -> string option

val event_to_string : event -> string
val snapshot_to_yojson : snapshot -> Yojson.Safe.t
val event_to_yojson : event -> Yojson.Safe.t
val event_of_yojson_result : Yojson.Safe.t -> (event, string) result
val event_of_yojson : Yojson.Safe.t -> event

val apply_event : snapshot -> event -> (snapshot, string) result
val replay : event list -> (snapshot, string) result
