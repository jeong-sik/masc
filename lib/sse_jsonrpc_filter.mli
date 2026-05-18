(** JSON-RPC payload filter for SSE coordinator sessions. *)

val jsonrpc_message_for_coordinator : Yojson.Safe.t -> bool

val event_string_jsonrpc_message_for_coordinator : string -> bool
