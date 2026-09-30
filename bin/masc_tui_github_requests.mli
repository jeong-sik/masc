(** GitHub authentication requests. Capture port and requested scopes before
    forking; deliver streamed lines and terminal outcomes to the UI mailbox. *)

val launch_login
  :  Masc_tui_types.state
  -> host:string
  -> deliver:(Masc_tui_async_protocol.async_msg -> unit)
  -> string
  -> unit

val launch_token_save
  :  Masc_tui_types.state
  -> host:string
  -> deliver:(Masc_tui_async_protocol.async_msg -> unit)
  -> string
  -> string
  -> unit
