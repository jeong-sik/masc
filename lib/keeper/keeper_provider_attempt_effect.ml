type t = Keeper_provider_attempt_effect_core.t =
  | No_effect_observed
  | Effect_attempted
  | Observation_unavailable

let to_string = Keeper_provider_attempt_effect_core.to_string
let of_string = Keeper_provider_attempt_effect_core.of_string
