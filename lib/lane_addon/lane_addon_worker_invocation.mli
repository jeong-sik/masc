(** Private worker control protocol. The host obtains credential admission
    before [call], which owns serialization of each individual RPC. *)
val run : invocation:Lane_addon_types.tool_invocation ->
  authorize:Lane_addon_call_context.mediation option ->
  principal:Lane_addon_call_context.principal -> name:string -> arguments:Yojson.Safe.t ->
  call:(name:string -> arguments:Yojson.Safe.t -> (Mcp_protocol.Mcp_types.tool_result, string) result) ->
  (Mcp_protocol.Mcp_types.tool_result, Lane_addon_call_context.invocation_error) result
