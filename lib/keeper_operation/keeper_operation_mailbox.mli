(** Bounded non-blocking admission mailbox.

    Producers never wait for capacity. The consumer may suspend until an item
    arrives or the mailbox closes. *)

type 'a t

type add_result =
  | Added
  | Full
  | Closed

val create : capacity:int -> ('a t, string) result
val try_add : 'a t -> 'a -> add_result
val take : 'a t -> 'a option
val close : 'a t -> unit
val length : 'a t -> int
val capacity : 'a t -> int
val is_closed : 'a t -> bool
