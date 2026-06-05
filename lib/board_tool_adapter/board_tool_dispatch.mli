(** Tool routing and registration for the board MCP adapter. *)

val handle_tool : string -> Yojson.Safe.t -> Tool_result.result
val tool_spec_read_only : string list
val register : unit -> unit
