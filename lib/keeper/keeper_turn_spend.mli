(** What each dispatched attempt of one Keeper turn reported about its spend,
    kept per attempt in the order the attempts started. The reports are read
    while the turn runs, so a turn that fails, and an attempt that lost to a
    later one, still has them. The Keeper resolves them after the turn.

    A reading is one thing a spend is resolved from: a client conversation's
    newest count, one client turn's total, or one Agent Core response. *)

type count_after =
  | Count_continues
  | Count_restarts_from_zero
      (** The client replaced the conversation's count after this reading (a
          Codex context-window fill). The reading's count is the last one the
          conversation reached; the next count of that conversation starts
          from zero. *)

type reading =
  { reading_index : int
        (** Position in its attempt, from 0. With the attempt's
            [lane_attempt_index] it names the reading within the turn: an
            official client can number two client turns of one attempt alike
            (a shrink retry that restarted the session starts again at 1). *)
  ; response_id : string
        (** The newest client turn or response the reading counts. *)
  ; ordinal : int
        (** The official turn, or the Agent Core response ordinal. *)
  ; model : string
  ; basis : Keeper_usage_resolution.basis
  ; observation : Keeper_usage_resolution.sample option
        (** [None] when the reading counted nothing. *)
  ; count_after : count_after
  }

type attempt =
  { routing_run_id : string
  ; runtime_id : string
  ; lane_attempt_index : int
  ; readings : reading list  (** In the order they were first seen. *)
  }

type t

(** A report that arrived when no attempt had started. *)
type unplaced = No_attempt_started

val empty : t

val start_attempt
  :  t
  -> routing_run_id:string
  -> runtime_id:string
  -> lane_attempt_index:int
  -> t

(** A conversation-cumulative count updates that conversation's reading, so
    a repeated frame changes nothing. After a replaced count, the
    conversation's next count opens a new reading that resumes from zero.
    Any other count is its own client turn, keyed by [response_id]. *)
val observe_client_report : t -> Keeper_client_usage_report.t -> (t, unplaced) result

(** One Agent Core response, one reading. [None] usage is a response that
    counted nothing. *)
val observe_agent_core_response
  :  t
  -> response_id:string
  -> ordinal:int
  -> model:string
  -> Agent_core.Types.api_usage option
  -> (t, unplaced) result

val attempts : t -> attempt list

(** One reading, resolved, with the attempt it belongs to. *)
type resolved =
  { routing_run_id : string
  ; runtime_id : string
  ; lane_attempt_index : int
  ; reading : reading
  ; resolution : Keeper_usage_resolution.t
  }

(** Resolves every reading in the order the attempts started and the
    readings were seen, each against the cursor the one before it left, so a
    conversation's deltas add up to its last count minus the cursor the turn
    started from. A reading whose count was replaced leaves its conversation's
    cursor at zero, where the next count starts. *)
val resolve
  :  cursor:Keeper_usage_resolution.cursor option
  -> observed_at:float
  -> attempt list
  -> resolved list * Keeper_usage_resolution.cursor option

(** A successful turn's readings, resolved in order: the one its result
    reports, every other, and the cursor they leave. *)
type turn_resolution =
  { turn_reading : resolved option
        (** The last attempt's last reading: the thread, client turn or
            response the result ended on. [None] when that attempt read
            nothing. *)
  ; other_readings : resolved list
        (** Every earlier conversation or response of that attempt, and
            every attempt that lost to it: spend beside the turn's. *)
  ; cursor : Keeper_usage_resolution.cursor option
  }

val resolve_turn
  :  cursor:Keeper_usage_resolution.cursor option
  -> observed_at:float
  -> attempt list
  -> turn_resolution
