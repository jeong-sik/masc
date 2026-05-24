(** Retry admission denial reasons + attempt_kind enum for keeper
    cascade budget reasoner.

    RFC-0158 Phase A: the [retry_admission_denial] type and its JSON codec
    now live in [Cascade_internal_error] (cascade layer) to avoid a
    dependency cycle — [Cascade_internal_error] references this type in the
    [Retry_admission_denied] variant of [masc_internal_error], so the type
    must be defined below the keeper layer.  This module re-exports via
    transparent alias so [Keeper_turn_cascade_budget] and its callers are
    unchanged. *)

type retry_admission_denial =
  Cascade_internal_error.retry_admission_denial =
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

let attempt_kind_is_retry = function
  | First_attempt -> false
  | Retry_attempt -> true

let retry_admission_denial_to_yojson =
  Cascade_internal_error.retry_admission_denial_to_yojson
