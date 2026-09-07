type t = Keeper_provider_attempt_effect_core.t =
  | No_effect_observed
  | Effect_attempted
  | Observation_unavailable

let allows_same_turn_retry =
  Keeper_provider_attempt_effect_core.allows_same_turn_retry
;;

let to_string = Keeper_provider_attempt_effect_core.to_string