(** The actionable chat rows produced by one rendered frame. *)
type 'scope t

val empty : 'scope t
val of_rows : scope:'scope -> keeper:string -> int list -> 'scope t

val equal :
  same_scope:('scope -> 'scope -> bool) -> 'scope t -> 'scope t -> bool

val contains :
  same_scope:('scope -> 'scope -> bool) -> scope:'scope ->
  keeper:string option -> row:int -> 'scope t -> bool
(** [contains] also requires the scope and selected Keeper to still match. *)
