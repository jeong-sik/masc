(** Handoff Quality Signals — Pure computation module

    Captures quality signals from each handoff and computes threshold
    adjustments. No side effects — all functions are pure.

    Adaptation rules (delta applied to handoff_threshold):
    - Completion >= 95%: +0.01  (handoff was timely, can afford higher threshold)
    - Completion >= 85%: +0.005 (good but not perfect)
    - Completion >= 75%: -0.01  (cutting it close, lower threshold)
    - Completion <  75%: -0.03  (handoff too late, significant decrease)
    - Emergency (no Prepared state): -0.02 penalty
    - Error count >= 3: -0.02 penalty
    - Error count = 0: +0.005 bonus

    Max delta per session: +/- 0.03 *)

(** Quality signals collected after each handoff *)
type handoff_outcome = {
  completion_rate : float;   (** 0.0-1.0: task completion percentage *)
  error_count : int;         (** errors during handoff *)
  was_emergency : bool;      (** true if handoff happened without Prepared state *)
  duration_seconds : float;  (** time taken for handoff *)
  generation : int;          (** which generation *)
}

(** Maximum absolute adjustment per session *)
let max_session_delta = 0.03

(** Compute raw threshold adjustment from a handoff outcome.
    Returns the unclamped delta — caller should apply {!clamp_delta}. *)
let compute_adjustment (outcome : handoff_outcome) : float =
  (* Base adjustment from completion rate *)
  let base =
    if outcome.completion_rate >= 0.95 then 0.01
    else if outcome.completion_rate >= 0.85 then 0.005
    else if outcome.completion_rate >= 0.75 then -0.01
    else -0.03
  in
  (* Emergency penalty: handoff without Prepared state *)
  let emergency_penalty =
    if outcome.was_emergency then -0.02 else 0.0
  in
  (* Error penalty/bonus *)
  let error_adjustment =
    if outcome.error_count >= 3 then -0.02
    else if outcome.error_count = 0 then 0.005
    else 0.0
  in
  base +. emergency_penalty +. error_adjustment

(** Clamp a single-session delta to max bounds (+/- 0.03) *)
let clamp_delta (delta : float) : float =
  Float.max (-.max_session_delta) (Float.min max_session_delta delta)
