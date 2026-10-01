(** MCP resource request execution. The caller owns mailbox delivery.
    Request IDs, session capture and async launch remain at this effect boundary. *)

val launch_list :
  Masc_tui_types.state -> host:string ->
  deliver:(Masc_tui_async_protocol.async_msg -> unit) -> unit
(** Capture the port and MCP session, opening a session only when absent, then
    deliver the resource inventory with its existing failure behavior. *)

val launch_read :
  Masc_tui_types.state -> host:string ->
  deliver:(Masc_tui_async_protocol.async_msg -> unit) -> uri:string -> unit
(** Mark the pending URI before launching. Changing resources clears the old
    content, error and scroll; re-reading the same resource keeps its content.
    AsyncRead attributes failures at the Resource_read boundary exactly once. *)
