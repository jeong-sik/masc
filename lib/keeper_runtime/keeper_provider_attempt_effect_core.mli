(** Leaf SSOT for provider-attempt tool-effect observations. *)

type t =
  | No_effect_observed
  | Effect_attempted
  | Observation_unavailable

val allows_same_turn_retry : t -> bool
val to_string : t -> string
val of_string : string -> t option
