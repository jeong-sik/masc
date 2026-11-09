(** Read authority comes from the calling boundary, never tool arguments or
    text in a post. Only Direct readership is enforced here; the other
    visibility modes retain their existing behavior. *)
type reader =
  | Anonymous
  | Named of { name : string; addressed_by : Board.Agent_id.t -> bool }
  | Operator

val named : string -> reader
(** An authenticated exact-name reader, without Keeper aliases. *)
val name : reader -> string option
val is_operator : reader -> bool
val cache_key : reader -> string
(** For HTTP readers whose [Named] address predicate is exact-name equality. *)
val can_read_fields :
  reader:reader -> author:Board.Agent_id.t -> visibility:Board.visibility ->
  audience:Board.audience option -> bool
val can_read : reader:reader -> Board.post -> bool
