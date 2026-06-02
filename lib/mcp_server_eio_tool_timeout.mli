(** Per-tool timeout policy for [Mcp_server_eio_call_tool]. *)

type resolved_tool_timeout =
  { timeout_sec : float
  ; source_env : string option
  }

val tool_timeout :
  tool_name:string -> _arguments:Yojson.Safe.t -> resolved_tool_timeout option
(** Returns the resolved timeout policy for a tool call. *)

val tool_timeout_sec_opt :
  tool_name:string -> _arguments:Yojson.Safe.t -> float option
(** Returns only the timeout seconds from {!tool_timeout}. *)
