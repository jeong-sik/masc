(** Tool routing and registration for the board MCP adapter. *)

val handle_tool :
  reader:Masc_board_handlers.Board_access.reader ->
  result_boundary:Tool_output.result_boundary -> string -> Yojson.Safe.t -> Tool_result.result
(** [result_boundary] is what the result meets on its way to the caller's
    reader; [masc_board_post_get] sizes its comment page by it. The thread read
    owns its coalesced source/ACL check; a cached mutation-target lookup must
    not preempt that read and turn unavailable data into an absent post. *)
val register : unit -> unit
