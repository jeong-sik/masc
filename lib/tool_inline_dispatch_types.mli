(** Tool_inline_dispatch_types — shared types for inline dispatch modules.

    Extracted to avoid circular dependencies between
    [tool_inline_dispatch], [tool_inline_dispatch_coord], and
    [tool_inline_dispatch_comm]. *)

(** Boolean success flag paired with human-readable output. *)
type tool_result = bool * string

(** Context record capturing all bindings from [execute_tool_eio] that the
    inline dispatch block needs. Pure data — callers populate all fields. *)
type context =
  { config : Coord.config
  ; agent_name : string
  ; registry : Session.registry
  ; state : Mcp_server.server_state
  ; sw : Eio.Switch.t
  ; clock : float Eio.Time.clock_ty Eio.Resource.t
  ; arguments : Yojson.Safe.t
  ; mcp_session_id : string option
  ; write_mcp_session_agent : string -> unit
    (** Write agent name to MCP session file for HTTP persistence. *)
  ; wait_for_message :
      Session.registry -> agent_name:string -> timeout:float -> Yojson.Safe.t option
    (** Wait for a message from a given agent. *)
  ; governance_defaults : string -> Mcp_server_eio_governance.governance_config
    (** Governance helpers passed in to avoid circular deps. *)
  ; save_governance : Coord.config -> Mcp_server_eio_governance.governance_config -> unit
  ; load_mcp_sessions : Coord.config -> Mcp_server_eio_governance.mcp_session_record list
  ; save_mcp_sessions :
      Coord.config -> Mcp_server_eio_governance.mcp_session_record list -> unit
  }

(** [safe_exec argv] runs [argv] as a subprocess with a 60s timeout.
    Returns [(true, stdout)] on exit 0 and [(false, stderr_or_msg)] on
    any non-zero exit or timeout. *)
val safe_exec : string list -> tool_result
