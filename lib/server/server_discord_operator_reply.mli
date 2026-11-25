(** Operator-authored replies anchored to a verified Discord transcript row.
    The request binds an operation ID to one origin and one body. A later lookup
    reads the original outcome, including a Discord message ID when delivered. *)

val handle_send :
  sw:Eio.Switch.t -> clock:_ Eio.Time.clock ->
  state:Mcp_server.server_state -> actor:string ->
  Httpun.Request.t -> Http_reqd.t -> unit

val handle_status :
  state:Mcp_server.server_state -> actor:string ->
  Httpun.Request.t -> Http_reqd.t -> unit

module For_testing : sig
  val origin_from_chat :
    chat_id:string -> Keeper_chat_store.chat_message -> (string * string * string option) option

  val submit :
    sw:Eio.Switch.t -> root:string -> actor:string ->
    resolve_origin:(keeper_name:string -> chat_id:string ->
      (string * string * string option, string) result) ->
    binding_allows:(keeper_name:string -> channel_id:string -> bool) ->
    send:(channel_id:string -> message_id:string -> content:string ->
      (string, Discord_rest_client.error) result) ->
    Yojson.Safe.t -> Httpun.Status.t * Yojson.Safe.t

  val status : root:string -> actor:string -> Yojson.Safe.t -> Httpun.Status.t * Yojson.Safe.t
end
