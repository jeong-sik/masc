(** Board tool dispatch and Tool_dispatch registration. *)

val handle_tool : string -> Yojson.Safe.t -> Tool_result.result
val tool_spec_read_only : string list
val register : unit -> unit
