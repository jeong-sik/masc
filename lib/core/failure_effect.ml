type t =
  | Proven_pre_effect
  | Proven_post_effect
  | Effect_outcome_unknown

let to_string = function
  | Proven_pre_effect -> "proven_pre_effect"
  | Proven_post_effect -> "proven_post_effect"
  | Effect_outcome_unknown -> "effect_outcome_unknown"

let of_string = function
  | "proven_pre_effect" -> Some Proven_pre_effect
  | "proven_post_effect" -> Some Proven_post_effect
  | "effect_outcome_unknown" -> Some Effect_outcome_unknown
  | _ -> None
