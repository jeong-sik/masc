(** Standalone DOS worker. The host owns identity, credential admission and
    Board publication; this process owns machine state and tool execution. *)
val create : base_path:string -> unit -> Mcp_protocol_eio.Server.t

val contained :
  tool_name:string ->
  (unit -> (Mcp_protocol.Mcp_types.tool_result, string) result) ->
  (Mcp_protocol.Mcp_types.tool_result, string) result
(** Runs a tool handler and turns an exception it raises into an error result
    with [Runtime_failure] and [Effect_outcome_unknown], the exception and its
    backtrace in the structured content. [Eio.Cancel.Cancelled] is re-raised.
    Every tool [create] registers with a handler goes through it. *)
