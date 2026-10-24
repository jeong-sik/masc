(** Switch-owned native Telegram polling. The cursor module owns receipt and
    persistence admission; this module binds it to real Keeper operations. *)
val start : sw:Eio.Switch.t -> env:Eio_unix.Stdenv.base -> state:Mcp_server.server_state -> unit
module For_testing : sig
  val accept_update :
    claim_root:string ->
    resolve:(channel_id:string -> (string option, string) result) ->
    dispatch_for_delivery:(Gate_keeper_backend.connector_delivery -> Channel_gate.dispatch_fn) ->
    bot_user_id:int64 -> operation_id:string -> Telegram_rest_client.update ->
    (Telegram_poll_custody.disposition, string) result
end
