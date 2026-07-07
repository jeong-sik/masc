(** RFC-0313 W2a — total routing of a degraded failure reason.

    RFC-0313 §2: a turn failure resolves to exactly one typed route. A
    failure may change WHEN the next turn runs (pacing) and WHERE it
    runs (rotation), or become a stimulus for an LLM-boundary verdict —
    but never WHETHER the keeper exists. This module is the pure,
    exhaustive projection of the existing closed failure taxonomy
    ([Keeper_error_classify.degraded_retry_reason]) onto that route.

    This is the W2 *foundation* only: a classification function plus its
    exhaustive contract. It changes no routing behavior. The consumer
    flip (deleting the [None] rotation family and the cycle-cap matrix so
    routing reads this projection) is W2b / W3.

    Reusing [degraded_retry_reason] as the source — rather than defining a
    second closed set — keeps one SSOT: adding a reason there forces a
    compile error here (no catch-all), so the two cannot drift (the
    N-of-M classifier-duplication the CLAUDE.md workaround bar forbids). *)

type route =
  | Retry_after_pacing
      (** Transient: widen this runtime's revisit (RFC-0313 W1
          [Keeper_pacing]) and continue on the next eligible runtime.
          The provider [retry_after] hint, when present, is honored by
          the pacing layer — the field the 2026-07-06 storm ignored. *)
  | Rotate_now
      (** Provider-bound failure with untried candidates: try the next
          candidate on the same turn (today's rotation behavior, kept). *)
  | Escalate_judgment
      (** Deterministic: retrying cannot help. The keeper keeps running;
          the failure becomes a typed stimulus for an LLM-boundary
          verdict (the keeper's own next turn, or HITL for mutating
          ambiguity). Never a retry, never an existence change. *)

val route_to_string : route -> string

val of_degraded_retry_reason : Keeper_error_classify.degraded_retry_reason -> route
(** Total, exhaustive map. Deterministic reasons (auth, the three
    no-progress accept-rejections) route to [Escalate_judgment]; every
    transient/capacity/timeout reason routes to [Retry_after_pacing];
    runtime-candidate filtering routes to [Rotate_now]. *)

val is_deterministic : route -> bool
(** [true] for [Escalate_judgment]. Convenience for callers deciding
    whether a failure is a retry candidate at all. *)
