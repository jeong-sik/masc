(** Keeper_chat_store_operation — closed sum for the [operation] label on
    [masc_keeper_chat_store_failures_total]. [to_label] gives ["append"] for
    [Append] and ["load"] for [Load]. *)

type t =
  | Append (** Append-to-chat-store I/O failure. *)
  | Load (** Read-from-chat-store I/O failure. *)

val to_label : t -> string
