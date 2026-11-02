(** The actionable chat rows produced by one rendered frame. *)
type 'scope approval = {
  scope : 'scope;
  keeper : string;
  request_id : string;
  tool_call_id : string;
  approval_id : string;
}

type 'scope t

val empty : 'scope t
val of_rows : scope:'scope -> keeper:string -> int list -> 'scope t

val with_approval : 'scope approval -> 'scope t -> 'scope t
val approval : 'scope t -> 'scope approval option
(** The approval prompt actually drawn in this candidate frame. *)

val same_approval :
  same_scope:('scope -> 'scope -> bool) ->
  'scope approval -> 'scope approval -> bool

val equal :
  same_scope:('scope -> 'scope -> bool) -> 'scope t -> 'scope t -> bool

val contains :
  same_scope:('scope -> 'scope -> bool) -> scope:'scope ->
  keeper:string option -> row:int -> 'scope t -> bool
(** [contains] also requires the scope and selected Keeper to still match. *)
