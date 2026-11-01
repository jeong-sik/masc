(** Producer evidence about the requested effect when an operation fails.
    Classification, transport status and exception text do not establish it. *)

type t =
  | Proven_pre_effect
  | Proven_post_effect
  | Effect_outcome_unknown

val to_string : t -> string
val of_string : string -> t option
(** Strict inverse; unknown wire values return [None]. *)
