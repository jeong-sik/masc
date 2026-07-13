(** Durable MCP session records. *)

type mcp_session_record =
  { id : string
  ; agent_name : string option
  ; created_at : float
  ; last_seen : float
  }

val mcp_session_to_json : mcp_session_record -> Yojson.Safe.t
val mcp_session_of_json : Yojson.Safe.t -> mcp_session_record option
val load_mcp_sessions : Workspace.config -> mcp_session_record list
val save_mcp_sessions : Workspace.config -> mcp_session_record list -> unit
