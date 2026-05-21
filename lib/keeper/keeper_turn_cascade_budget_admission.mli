(** Retry admission denial reasons + attempt_kind enum for keeper
    cascade budget reasoner. *)

type retry_admission_denial =
  | Retry_budget_below_min of {
      projected_usable_budget_s : float;
      min_required_s : float;
      remaining_turn_budget_s : float;
      adaptive_timeout_s : float;
      allow_wall_clock_retry_budget : bool;
    }
  | First_attempt_budget_below_min of {
      projected_usable_budget_s : float;
      min_required_s : float;
      remaining_turn_budget_s : float;
    }

type attempt_kind = First_attempt | Retry_attempt

val attempt_kind_is_retry : attempt_kind -> bool
val retry_admission_denial_to_yojson : retry_admission_denial -> Yojson.Safe.t
