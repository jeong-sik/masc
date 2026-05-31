(** JSON-RPC payload filter for SSE workspace_client sessions. *)

val jsonrpc_message_for_workspace_client : Yojson.Safe.t -> bool

val event_string_jsonrpc_message_for_workspace_client : string -> bool
