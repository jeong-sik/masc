(** The attached-service tool names one admitted turn retained. *)
type t
val empty : t
val of_tools : Keeper_identity_tools.offered_tool list -> t
(** Capture the exact tools retained by turn admission, without global writes. *)
val mem : t -> tool_name:string -> bool
(** Whether this turn admitted [tool_name] from an attached service. *)
