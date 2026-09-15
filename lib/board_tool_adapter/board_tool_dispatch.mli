(** Tool routing and registration for the board MCP adapter. *)

val handle_tool :
  result_boundary:Tool_output.result_boundary -> string -> Yojson.Safe.t -> Tool_result.result
(** [result_boundary] is what the result meets on its way to the caller's
    reader; [masc_board_post_get] sizes its comment page by it. *)
val register : unit -> unit
