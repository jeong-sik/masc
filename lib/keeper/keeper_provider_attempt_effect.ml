type t =
  | No_effect_observed
  | Effect_attempted
  | Observation_unavailable

let allows_same_turn_retry = function
  | No_effect_observed -> true
  | Effect_attempted | Observation_unavailable -> false
;;
