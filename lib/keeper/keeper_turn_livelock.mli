(** Keeper turn livelock observer (#10121).

    Observability surface for stuck-turn livelocks: per-keeper
    in-memory state tracks the most recent turn id seen and the
    attempt count for that id.  Re-starts of the same id and
    backwards regressions emit dedicated Prometheus counters so
    operators can alert without grepping log lines.

    [guard_and_record_turn_start] can also gate dispatch once a
    turn exhausts its retry budget or stays stuck too long.
    State is process-local; a server restart resets the
    bookkeeping. *)

type attempt_state = {
  turn_id : int;
  attempts : int;
  first_started_at : float;  (** Unix seconds. *)
}

type start_outcome =
  | Fresh
  | Reattempt of { previous_attempts : int; first_started_at : float }
  | Regression of { previous_turn_id : int }

type gate_reason =
  | Attempts_exhausted of {
      attempts : int;
      max_attempts : int;
      first_started_at : float;
    }
  | Stuck_age_exceeded of {
      attempts : int;
      age_sec : float;
      threshold_sec : float;
      first_started_at : float;
    }

type guarded_start_outcome =
  | Started of start_outcome
  | Blocked of gate_reason

(** [record_turn_start ~keeper ~turn_id] increments the
    [masc_keeper_turn_starts_total] counter and, when the start
    classifies as [Reattempt] or [Regression], the matching
    counter as well.  Returns the classification for the caller.
    Thread-safe across keeper fibers / domains. *)
val record_turn_start : keeper:string -> turn_id:int -> start_outcome

val guard_and_record_turn_start :
  ?now:(unit -> float) ->
  keeper:string ->
  turn_id:int ->
  max_attempts:int ->
  stuck_after_sec:float ->
  ?provider:string ->
  ?model:string ->
  unit ->
  guarded_start_outcome
(** Atomically enforce a per-turn retry/age budget before recording a start.
    With [max_attempts = 3], attempts 1, 2, and 3 are started; the fourth
    start for the same [(keeper, turn_id)] is [Blocked].  Blocked starts do
    not increment [metric_keeper_turn_starts], because no dispatch occurs.

    If [model] is provided and [Keeper_provider_health] reports that any
    provider serving the model is unhealthy, [stuck_after_sec] is halved so
    the gate reacts faster to provider degradation. *)

val gate_reason_kind : gate_reason -> string
val gate_reason_to_string : gate_reason -> string

(** Read-only view of the current attempt state for a keeper.
    Returns [None] when no state has been recorded yet. *)
val current_state : keeper:string -> attempt_state option

(** Convenience wrapper — Unix seconds since the FIRST attempt of
    the current turn id.  [None] when no state exists. *)
val seconds_since_first_attempt : keeper:string -> float option

(** Reset the in-memory state.  Intended for unit tests; the live
    server resets state implicitly on process restart. *)
val reset_for_tests : unit -> unit

(** Remove the attempt state for a single keeper.  Called by the
    supervisor when a keeper fiber is cleaned up after a crash so
    that the next restart begins with a fresh counter rather than
    inheriting the previous stuck turn's exhaustion. *)
val reset_keeper_livelock : keeper:string -> unit
