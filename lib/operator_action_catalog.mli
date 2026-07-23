(** Closed MASC operator action vocabulary, without risk or approval
    hierarchy. *)

type t =
  | Broadcast
  | Namespace_pause
  | Namespace_resume
  | Social_sweep
  | Keeper_message
  | Keeper_probe
  | Keeper_recover
  | Task_inject

val to_string : t -> string
val of_string : string -> t option
val all : t list
val strings : string list
val is_allowed : string -> bool

(** Every recognized product action follows the same explicit confirmation
    flow. Unknown actions are rejected before confirmation. *)
val requires_confirmation : string -> bool
