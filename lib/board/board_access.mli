(** Read authority comes from the calling boundary, never tool arguments or
    text in a post. Only Direct readership is enforced here; the other
    visibility modes retain their existing behavior. *)
type reader =
  | Anonymous
  | Named of { name : string; addressed_by : Board_types.Agent_id.t -> bool }
  | Operator

val named : string -> reader
(** An authenticated exact-name reader, without Keeper aliases. *)
val name : reader -> string option
val is_operator : reader -> bool
val cache_key : reader -> string
(** For HTTP readers whose [Named] address predicate is exact-name equality. *)
val can_read_fields :
  reader:reader -> author:Board_types.Agent_id.t -> visibility:Board_types.visibility ->
  audience:Board_types.audience option -> bool
val can_read : reader:reader -> Board_types.post -> bool

val can_post_in_sub_board : author_id:Board_types.Agent_id.t -> Board_types.sub_board -> bool
(** Existing Open/member/owner posting policy; reader privilege is separate. *)
