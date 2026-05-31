(** JSON-RPC payload filter for SSE agent_stream sessions. *)

val jsonrpc_message_for_agent_stream : Yojson.Safe.t -> bool

val event_string_jsonrpc_message_for_agent_stream : string -> bool
