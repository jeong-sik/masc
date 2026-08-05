(** Current MCP protocol and observer-stream request helpers. *)

val mcp_protocol_versions : string list
val mcp_protocol_version_default : string
val default_base_path : unit -> string
val is_valid_protocol_version : string -> bool

val observer_session_id : Httpun.Request.t -> string option
(** Reads the explicit [session_id] query parameter used by MASC observer
    streams. This is not MCP protocol session state. *)

val query_param : Httpun.Request.t -> string -> string option
