(** Immutable attached-service declarations for one admitted turn. *)
type t
val empty : t
val of_tools : Keeper_identity_tools.offered_tool list -> t
(** Capture the exact tools retained by turn admission, without global writes. *)
val read_only : t -> tool_name:string -> bool option option
(** [None] means absent from this turn; [Some None] means offered without a hint. *)
