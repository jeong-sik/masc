(** Per-session heard waiting-inventory generation tracking for Keeper chat
    reconcile watchers, replacing process-global mutable singletons. *)

type t

type news =
  | Heard_news
  | Stream_lost

val create : unit -> t

val keeper_changed : t -> string -> unit

val stream_reopened : t -> unit

val observe_hearing : t -> Masc_tui_keeper_chat_projection.inventory_hearing -> unit

val hearing : t -> Masc_tui_keeper_chat_projection.inventory_hearing

val generation : t -> string -> int

val await_after : t -> string -> int -> unit

val await_news : t -> string -> int -> news
