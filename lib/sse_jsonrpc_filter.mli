(** JSON-RPC payload filter for SSE agent_stream sessions. *)

val jsonrpc_message_for_agent_stream : Yojson.Safe.t -> bool

val event_data_payload : string -> string option
(** Extract and join the [data:] fields from one SSE event. *)

val event_string_jsonrpc_message_for_agent_stream : string -> bool
