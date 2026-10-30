(** Semantics of provider-reported token usage at a runtime boundary. *)

type t =
  | Per_request
  | Turn_total
      (** Sum of provider requests within one official-client turn, not all
          attempts in a Keeper turn or a conversation lifetime counter. *)
  | Conversation_cumulative
  | Usage_scope_unavailable
[@@deriving enumerate]

val to_string : t -> string
val of_string : string -> t option
