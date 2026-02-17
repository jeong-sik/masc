(** Handoff Quality Signals — Pure computation module

    Captures quality signals from each handoff and computes threshold
    adjustments for adaptive threshold learning. *)

(** Quality signals collected after each handoff *)
type handoff_outcome = {
  completion_rate : float;   (** 0.0-1.0: task completion percentage *)
  error_count : int;         (** errors during handoff *)
  was_emergency : bool;      (** true if handoff happened without Prepared state *)
  duration_seconds : float;  (** time taken for handoff *)
  generation : int;          (** which generation *)
}

(** Maximum absolute adjustment per session *)
val max_session_delta : float

(** Compute raw threshold adjustment from a handoff outcome.
    Applies adaptation rules based on completion rate, emergency status,
    and error count. Result is unclamped — use {!clamp_delta} afterwards. *)
val compute_adjustment : handoff_outcome -> float

(** Clamp a single-session delta to max bounds (+/- 0.03) *)
val clamp_delta : float -> float
