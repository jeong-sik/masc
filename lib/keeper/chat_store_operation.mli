(** Chat_store_operation — closed sum for the [operation] label on
    [metric_keeper_chat_store_failures].

    Replaces 2 hardcoded literals in [keeper_chat_store.ml]
    (`"append"` / `"load"`). *)

type t =
  | Append (** Append-to-chat-store I/O failure. *)
  | Load (** Read-from-chat-store I/O failure. *)

val to_label : t -> string
