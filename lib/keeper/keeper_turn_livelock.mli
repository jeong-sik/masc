(** Keeper turn livelock observer (#10121).

    Observability surface for stuck-turn livelocks: per-keeper
    in-memory state tracks the most recent turn id seen and the
    attempt count for that id.  Re-starts of the same id and
    backwards regressions emit dedicated Prometheus counters so
    operators can alert without grepping log lines.

    This module does NOT gate dispatch — that's a follow-up.
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

(** [record_turn_start ~keeper ~turn_id] increments the
    [masc_keeper_turn_starts_total] counter and, when the start
    classifies as [Reattempt] or [Regression], the matching
    counter as well.  Returns the classification for the caller.
    Thread-safe across keeper fibers / domains. *)
val record_turn_start : keeper:string -> turn_id:int -> start_outcome

(** Read-only view of the current attempt state for a keeper.
    Returns [None] when no state has been recorded yet. *)
val current_state : keeper:string -> attempt_state option

(** Convenience wrapper — Unix seconds since the FIRST attempt of
    the current turn id.  [None] when no state exists. *)
val seconds_since_first_attempt : keeper:string -> float option

(** Reset the in-memory state.  Intended for unit tests; the live
    server resets state implicitly on process restart. *)
val reset_for_tests : unit -> unit
