(** Semantics of provider-reported token usage at a runtime boundary. *)

type t =
  | Per_request
  | Conversation_cumulative
  | Usage_scope_unavailable

val to_string : t -> string
val of_string : string -> t option
