(** Tier admission backoff — exponential backoff with full jitter for
    capacity-saturated tiers.

    When [Cascade_tier_admission.try_acquire] returns [Capacity_full],
    this module computes a retry delay using exponential backoff
    capped at a configurable maximum, with uniform random jitter
    ("full jitter" strategy per Marc Brooker, AWS Architecture Blog).

    The caller ([with_admission_backoff]) loops up to [max_retries]
    times, sleeping between attempts, before giving up and returning
    the [Capacity_full] error.

    @since task-503 / RFC-0153 Phase B.2 *)

type backoff_state = {
  mutable attempt : int;
  config : Env_config_cascade_tier_backoff.t;
  rng : Random.State.t;
}

let create_backoff_state config =
  { attempt = 0; config; rng = Random.State.make_self_init () }

(** Full-jitter delay: uniform random in [0, min(base * exp^attempt, cap)].

    This is the same strategy used in {!Coord_utils_ops.backoff_with_jitter}
    but parameterised by the tier admission config rather than the keeper
    retry config. Keeping them separate because:
    - keeper retry backoff is for the outer loop (transient provider errors)
    - tier admission backoff is for the inner loop (inflight capacity contention)
    They have different time scales and different failure modes. *)
let jitter_delay (state : backoff_state) =
  let cfg = state.config in
  let raw =
    cfg.base_delay_sec
    *. (cfg.exponential_base ** float_of_int state.attempt)
  in
  let capped = min raw cfg.max_delay_sec in
  Random.State.float state.rng capped

(** One backoff step: compute delay, sleep, increment attempt.
    Returns [false] if max retries exceeded, [true] if a retry is viable. *)
let step (state : backoff_state) =
  if state.attempt >= state.config.max_retries
  then false
  else begin
    let delay = jitter_delay state in
    Time_compat.sleep delay;
    state.attempt <- state.attempt + 1;
    true
  end