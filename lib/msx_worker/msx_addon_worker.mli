(** Worker protocol only. It does not initialize MASC, resolve Keepers or publish
    Board events. The containing process must install its activity observer. *)
val create : base_path:string -> unit -> Mcp_protocol_eio.Server.t

val contain :
  tool_name:string -> start_time:Tool_timing.started -> (unit -> Mcp_protocol.Mcp_types.tool_result) ->
  Mcp_protocol.Mcp_types.tool_result
(** The worker's exception boundary, applied to every machine call. An
    exception raised by the call becomes a runtime failure whose effect is
    unknown; the process and its machine survive. Cancellation is re-raised. *)
