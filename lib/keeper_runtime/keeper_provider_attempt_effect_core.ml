type t =
  | No_effect_observed
  | Effect_attempted
  | Observation_unavailable

let allows_same_turn_retry = function
  | No_effect_observed -> true
  | Effect_attempted | Observation_unavailable -> false
;;

let to_string = function
  | No_effect_observed -> "no_effect_observed"
  | Effect_attempted -> "effect_attempted"
  | Observation_unavailable -> "observation_unavailable"
;;

let of_string = function
  | "no_effect_observed" -> Some No_effect_observed
  | "effect_attempted" -> Some Effect_attempted
  | "observation_unavailable" -> Some Observation_unavailable
  | _ -> None
;;
