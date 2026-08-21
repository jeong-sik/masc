(** Leaf SSOT for provider-attempt tool-effect observations. *)

type t =
  | No_effect_observed
  | Effect_attempted
  | Observation_unavailable

val to_string : t -> string
val of_string : string -> t option
