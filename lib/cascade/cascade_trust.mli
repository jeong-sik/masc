(** Cascade trust score — kill switch + hardcoded calibration.

    @see {!Cascade_trust} for full documentation.
    @since 0.174.0 *)

(** {1 Kill Switch} *)

(** [true] when [MASC_CASCADE_TRUST_DISABLED=1] or ["true"] is set.
    When disabled, [trust_score] returns 1.0 for all providers. *)
val disabled : bool

(** {1 Trust Computation} *)

(** Compute a trust score [0.0..1.0] from provider health data.

    The score reflects recent success rate, consecutive failures, and
    cooldown state.  It is NOT a replacement for cooldown — providers
    in cooldown get weight 0 from
    {!Cascade_health_tracker.effective_weight} regardless of trust.

    When [disabled] is [true], returns 1.0 unconditionally. *)
val trust_score : Cascade_health_tracker.provider_info -> float

(** Modulate a config weight by the trust score.

    Returns [max 1 (config_weight * trust)] so the provider always
    retains at least weight 1.  Hard cooldown (weight 0) is handled
    upstream by {!Cascade_health_tracker.effective_weight}. *)
val modulated_weight : config_weight:int -> trust:float -> int

(**/**)

(** White-box test helpers.  Not part of the stable API. *)
module For_testing : sig
  val disabled : bool
  val base_trust : float
  val consecutive_failure_penalty : float
  val max_consecutive_penalty : float
  val cooldown_penalty : float
  val minimum_trust : float
  val trust_score : Cascade_health_tracker.provider_info -> float
  val modulated_weight : config_weight:int -> trust:float -> int
end
