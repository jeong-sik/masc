(** Mcp_sdk_adapter_masc — narrow adapter between MASC's local
    {!Mcp_server} surface and the MCP protocol SDK
    ({!Mcp_protocol_eio.Handler} / {!Mcp_protocol.Mcp_types}).

    Three external entries — the rest of the module is internal
    glue (yojson parsers, schema converters, handler builder) that
    has no caller outside this file.  The narrow surface is
    deliberate: SDK / MASC type bridging stays here so the protocol
    layer stays clean. *)

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

val sdk_prompt_of_local :
  Mcp_prompt_surface.prompt_def -> Mcp_protocol.Mcp_types.prompt
(** [sdk_prompt_of_local prompt] converts a MASC-side
    {!Mcp_prompt_surface.prompt_def} into the SDK-side
    {!Mcp_protocol.Mcp_types.prompt}.  Each
    {!Mcp_prompt_surface.prompt_argument} maps to a
    {!Mcp_protocol.Mcp_types} prompt argument with [description]
    wrapped in [Some] and [required] wrapped in [Some].

    Exposed because {!Mcp_prompt_surface}'s interface references
    this conversion in its public contract — keeping the bridge in
    a single .mli avoids duplication. *)
