(** Objective per-Keeper turn-attempt observations.

    Recording a turn start never authorizes, blocks, ends, fails, pauses, or
    delays execution.  The attempt count and first-start timestamp are
    observability data only. *)

type attempt_state = Keeper_registry_types.turn_attempt_state

type start_observation =
  | Fresh
  | Reattempt of
      { previous_attempts : int
      ; first_started_at : float
      }
  | Regression of { previous_turn_id : int }

(** Atomically record a turn start and emit the corresponding observation
    counters.  The caller must continue dispatch for every result. *)
val record_turn_start
  :  base_path:string
  -> keeper:string
  -> turn_id:int
  -> start_observation

(** Read-only current observation state. *)
val current_state : base_path:string -> keeper:string -> attempt_state option

(** Clear one Keeper's in-process observation state at a lifecycle boundary. *)
val reset_keeper : base_path:string -> keeper:string -> unit

(** Test isolation only. *)
val reset_for_tests : unit -> unit
