(** Typed semantic identity shared by tool-surface projections.

    Route identities are nominal and never merge by prefix or alias. Board
    identities are closed over {!Tool_name.Board_name.t}, allowing the external
    MCP route and its Keeper wrapper to share one capability deliberately. *)

type t

val route : string -> t
val board_operation : Tool_name.Board_name.t -> t
val board_operation_opt : t -> Tool_name.Board_name.t option
val to_string : t -> string
val equal : t -> t -> bool
val compare : t -> t -> int
