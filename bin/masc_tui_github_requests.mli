(** GitHub authentication requests. Capture port and requested scopes before
    forking. The caller supplies dispatch-captured workspace delivery,
    cancellation through [fork], and captured endpoint authority through [check].
    Deliver streamed lines and terminal outcomes to the UI mailbox. *)

val launch_login
  :  Masc_tui_types.state
  -> host:string
  -> deliver:(Masc_tui_async_protocol.async_msg -> unit)
  -> fork:(sw:Eio.Switch.t -> (unit -> unit) -> unit)
  -> check:(unit -> (unit, string) result)
  -> string
  -> unit

val launch_token_save
  :  Masc_tui_types.state
  -> host:string
  -> deliver:(Masc_tui_async_protocol.async_msg -> unit)
  -> fork:(sw:Eio.Switch.t -> (unit -> unit) -> unit)
  -> check:(unit -> (unit, string) result)
  -> string
  -> string
  -> unit
