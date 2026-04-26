(** Tool_inline_dispatch — thin dispatch router for inline tool handlers.

    Delegates to sub-modules for coord, comm, and extra tool handling.
    Keeps inline: mcp_session, approval, spawn, discover_tools.

    @since 0.1.0 *)

(** {1 Types} (re-exported from Tool_inline_dispatch_types) *)

type tool_result = Tool_inline_dispatch_types.tool_result

type context = Tool_inline_dispatch_types.context =
  { config : Coord.config
  ; agent_name : string
  ; registry : Session.registry
  ; state : Mcp_server.server_state
  ; sw : Eio.Switch.t
  ; clock : float Eio.Time.clock_ty Eio.Resource.t
  ; arguments : Yojson.Safe.t
  ; mcp_session_id : string option
  ; write_mcp_session_agent : string -> unit
  ; wait_for_message :
      Session.registry -> agent_name:string -> timeout:float -> Yojson.Safe.t option
  ; governance_defaults : string -> Mcp_server_eio_governance.governance_config
  ; save_governance : Coord.config -> Mcp_server_eio_governance.governance_config -> unit
  ; load_mcp_sessions : Coord.config -> Mcp_server_eio_governance.mcp_session_record list
  ; save_mcp_sessions :
      Coord.config -> Mcp_server_eio_governance.mcp_session_record list -> unit
  }

(** {1 Functions} *)

val safe_exec : string list -> tool_result
val dispatch : context -> name:string -> tool_result option
