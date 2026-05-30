(** Cascade trust score — kill switch + hardcoded calibration.

    Computes a per-provider trust score [0.0..1.0] from the rolling
    health data maintained by {!Cascade_health_tracker}.  The score
    modulates cascade selection weights so poorly-performing providers
    are gradually de-prioritised even when not in hard cooldown.

    Kill switch: [MASC_CASCADE_TRUST_DISABLED=1] disables trust
    scoring globally (all providers score 1.0 regardless of health).
    This is the only env-exposed knob — calibration constants are
    hardcoded per the project's "no hyperparameter as env knob" rule.

    The trust score formula is:
    {v
      trust = base_score * decay_factor
      base_score = success_rate
                   * (1.0 - consecutive_failure_penalty * consecutive_failures)
      decay_factor = 1.0 / (1.0 + cooldown_penalty * cooldown_count)
    v}

    @since 0.174.0 *)

(* ── Kill switch (sole env-exposed control) ─────────────────── *)

let disabled =
  match Sys.getenv_opt "MASC_CASCADE_TRUST_DISABLED" with
  | Some v ->
    let trimmed = String.trim v in
    String.equal trimmed "1" || String.equal trimmed "true"
  | None -> false

(* ── Hardcoded calibration constants ──────────────────────────
   Per project rule: "No hyperparameter as env knob — calibration
   constants live in code."  Changes here require a PR + review.
   Kill switch is the only env-exposed knob (boolean). *)

let base_trust = 1.0
(** Starting trust for providers with no health data. *)

let consecutive_failure_penalty = 0.15
(** Each consecutive failure reduces trust by this fraction.
    0.15 means 3 consecutive failures → trust × 0.55. *)

let max_consecutive_penalty = 0.90
(** Cap the cumulative penalty so trust never goes fully negative.
    After ~6 consecutive failures the penalty saturates. *)

let cooldown_penalty = 0.25
(** Each observed cooldown period reduces trust by this factor
    (multiplicative decay).  After 3 cooldowns: trust × ~0.42. *)

let minimum_trust = 0.05
(** Floor — even a terrible provider retains some weight so the
    cascade can recover it when health improves. *)

(* ── Trust computation ──────────────────────────────────────── *)

(** Compute the trust score for a single provider.

    When the kill switch is active ([disabled = true]), returns 1.0
    unconditionally (trust modulation disabled).

    Otherwise, computes:
    1. Base from [success_rate]
    2. Consecutive-failure penalty (capped)
    3. Cooldown history decay
    4. Clamp to [minimum_trust, 1.0] *)
let trust_score (info : Cascade_health_tracker.provider_info) : float =
  if disabled then 1.0
  else
    let consecutive_penalty =
      Float.min max_consecutive_penalty
        (Float.mul
           (float_of_int info.consecutive_failures)
           consecutive_failure_penalty)
    in
    let base =
      info.success_rate *. (1.0 -. consecutive_penalty)
    in
    let cooldown_count =
      if info.in_cooldown then 1 else 0
    in
    let decay =
      1.0 /. (1.0 +. Float.mul (float_of_int cooldown_count) cooldown_penalty)
    in
    Float.min 1.0 (Float.max minimum_trust (base *. decay))

(** Modulate a config weight by the trust score.

    Returns [max 1 (int_of_float (config_weight *. trust))] so the
    provider always has at least weight 1 when not in hard cooldown
    (hard cooldown is handled by
    [Cascade_health_tracker.effective_weight] returning 0). *)
let modulated_weight ~config_weight ~trust =
  if disabled then config_weight
  else max 1 (int_of_float (float_of_int config_weight *. trust))

module For_testing = struct
  let disabled = disabled
  let base_trust = base_trust
  let consecutive_failure_penalty = consecutive_failure_penalty
  let max_consecutive_penalty = max_consecutive_penalty
  let cooldown_penalty = cooldown_penalty
  let minimum_trust = minimum_trust
  let trust_score = trust_score
  let modulated_weight = modulated_weight
end
