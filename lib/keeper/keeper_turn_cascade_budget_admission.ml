(** Retry admission denial reasons + attempt_kind enum for keeper
    cascade budget reasoner.

    Two typed variants:
    - [retry_admission_denial] — closed 2-variant sum with inline-
      record payloads carrying the budget arithmetic that justified
      the denial (projected vs min vs remaining + the wall-clock
      flag for retry, plus the adaptive timeout for retry only).
    - [attempt_kind] — First_attempt | Retry_attempt; tags the
      decide-retry call.

    Plus 2 helpers:
    - [attempt_kind_is_retry] — bool projection.
    - [retry_admission_denial_to_yojson] — per-arm `Assoc payload
      with "kind" tag + arm-specific float/bool fields.

    Verbatim extract from [Keeper_turn_cascade_budget]; the parent
    retains transparent variant aliases (including inline records)
    + 2 value aliases. *)

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

let attempt_kind_is_retry = function
  | First_attempt -> false
  | Retry_attempt -> true

let retry_admission_denial_to_yojson (d : retry_admission_denial) : Yojson.Safe.t =
  match d with
  | Retry_budget_below_min r ->
    `Assoc
      [
        ("kind", `String "retry_budget_below_min");
        ("projected_usable_budget_s", `Float r.projected_usable_budget_s);
        ("min_required_s", `Float r.min_required_s);
        ("remaining_turn_budget_s", `Float r.remaining_turn_budget_s);
        ("adaptive_timeout_s", `Float r.adaptive_timeout_s);
        ( "allow_wall_clock_retry_budget",
          `Bool r.allow_wall_clock_retry_budget );
      ]
  | First_attempt_budget_below_min r ->
    `Assoc
      [
        ("kind", `String "first_attempt_budget_below_min");
        ("projected_usable_budget_s", `Float r.projected_usable_budget_s);
        ("min_required_s", `Float r.min_required_s);
        ("remaining_turn_budget_s", `Float r.remaining_turn_budget_s);
      ]
