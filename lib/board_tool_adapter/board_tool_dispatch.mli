(** Tool routing and registration for the board MCP adapter. *)

val handle_tool : string -> Yojson.Safe.t -> Tool_result.result
val register : unit -> unit
