(** Worker protocol only. It does not initialize MASC, resolve Keepers or publish
    Board events. The containing process must install its activity observer. *)
val create : base_path:string -> unit -> Mcp_protocol_eio.Server.t
