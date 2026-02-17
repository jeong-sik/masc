(** Handoff Quality Signals -- Pure computation module.

    Captures quality signals from each handoff and computes threshold
    adjustments for {!Adaptive_thresholds}. All functions are pure
    (no side effects, no I/O).

    {2 Adaptation rules}

    The delta is applied to the handoff threshold in
    {!Adaptive_thresholds.adapt}:

    {v
      Completion >= 95%  : +0.01   (handoff was timely, raise threshold)
      Completion >= 85%  : +0.005  (good but not perfect)
      Completion >= 75%  : -0.01   (cutting it close, lower threshold)
      Completion <  75%  : -0.03   (handoff too late, significant decrease)
      Emergency penalty  : -0.02   (no Prepared state before handoff)
      Errors >= 3        : -0.02   (penalty for excessive errors)
      Errors = 0         : +0.005  (bonus for clean handoff)
    v}

    Maximum absolute delta per session: +/- 0.03.

    @since 0.5.0 *)

(** {1 Types} *)

(** Quality signals collected after each handoff.

    These signals capture the outcome of a single handoff event and
    are fed into {!compute_adjustment} to determine threshold adaptation. *)
type handoff_outcome = {
  completion_rate : float;
      (** Task completion percentage, 0.0--1.0. Higher is better. *)
  error_count : int;
      (** Number of errors that occurred during the handoff. *)
  was_emergency : bool;
      (** [true] if the handoff happened without prior [Prepared] state.
          Emergency handoffs incur an additional penalty. *)
  duration_seconds : float;
      (** Wall-clock time taken for the handoff operation. *)
  generation : int;
      (** Generation number of the cell that performed the handoff. *)
}

(** {1 Constants} *)

(** Maximum absolute threshold adjustment allowed per session.
    Value: 0.03. Both positive and negative adjustments are clamped
    to this bound. *)
val max_session_delta : float

(** {1 Functions} *)

(** [compute_adjustment outcome] computes the raw threshold adjustment
    from a handoff outcome.

    Applies the adaptation rules based on {!handoff_outcome.completion_rate},
    {!handoff_outcome.was_emergency}, and {!handoff_outcome.error_count}.
    The result is {b unclamped} -- call {!clamp_delta} afterwards to
    enforce per-session bounds.

    @return signed float: positive means raise threshold, negative means lower. *)
val compute_adjustment : handoff_outcome -> float

(** [clamp_delta delta] constrains [delta] to the range
    [\[-.max_session_delta, +max_session_delta\]] (i.e., +/- 0.03).

    @return clamped delta value. *)
val clamp_delta : float -> float
