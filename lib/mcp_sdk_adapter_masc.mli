(** Mcp_sdk_adapter_masc — narrow adapter for the SDK-owned slice of
    the MCP JSON-RPC surface.

    Two external entries — {!handles_method} and {!dispatch_request} —
    cover the methods the SDK adapter answers directly (currently only
    ["ping"]).  Every other method falls through to the MASC-native
    handler.  The narrow surface is deliberate: the protocol router
    asks {!handles_method} first and only delegates the small SDK-owned
    set here. *)

val handles_method : string -> bool
(** [handles_method m] is [true] iff the SDK adapter dispatches
    method [m] (currently only ["ping"]).  The protocol router uses
    this to decide whether to delegate to {!dispatch_request} or
    fall through to the MASC-native handler. *)

val dispatch_request :
  handle_call_tool_eio:_ ->
  state:_ ->
  profile:_ ->
  sw:_ ->
  clock:_ ->
  ?mcp_session_id:_ ->
  ?auth_token:_ ->
  Yojson.Safe.t ->
  Yojson.Safe.t option
(** [dispatch_request ~handle_call_tool_eio ~state ~profile ~sw
      ~clock ?mcp_session_id ?auth_token json] inspects [json] for
    a JSON-RPC request whose method is in {!handles_method}'s set
    and returns:

    - [Some response_json] when the method is SDK-owned and was
      dispatched (currently only ["ping"] -> empty
      [\{"jsonrpc":"2.0","id":..,"result":\{\}\}]).
    - [None] when [json] is not a [`Assoc] or the method is not in
      the SDK-owned set — caller must fall through to the
      MASC-native handler.

    The capability arguments ([handle_call_tool_eio], [state],
    [profile], [sw], [clock], [mcp_session_id], [auth_token]) are
    threaded through for forward compatibility — the current ["ping"]
    dispatcher ignores them.  Polymorphic types intentional: the
    adapter does not own the runtime types. *)
