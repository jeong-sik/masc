(** Closed MASC operator action vocabulary, without risk or approval
    hierarchy. *)

type t =
  | Broadcast
  | Namespace_pause
  | Namespace_resume
  | Task_inject
  | Keeper_message
  | Keeper_probe
  | Keeper_recover

val all : t list
(** Every action, in declaration order. The operator surface lists its
    available actions in this order. *)

val to_string : t -> string
val of_string : string -> t option
val strings : string list

val target_type : t -> Operator_action_constants.target_type
(** The one kind of target an action addresses. A request does not choose
    it. *)

val target_type_string : t -> string
(** {!target_type} in its wire spelling. *)

(** Every catalog action follows the same explicit confirmation flow. A name
    outside the catalog is refused where it is read, so it never reaches this
    question. *)
val requires_confirmation : t -> bool
