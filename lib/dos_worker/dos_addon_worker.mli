(** Standalone DOS worker. The host owns identity, credential admission and
    Board publication; this process owns machine state and tool execution. *)
val create : base_path:string -> unit -> Mcp_protocol_eio.Server.t
