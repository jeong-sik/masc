(** JSON-RPC payload filter for SSE workspace_session sessions. *)

val jsonrpc_message_for_workspace_session : Yojson.Safe.t -> bool

val event_string_jsonrpc_message_for_workspace_session : string -> bool
