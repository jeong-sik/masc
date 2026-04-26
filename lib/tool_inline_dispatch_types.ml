(** Tool_inline_dispatch_types — shared types for inline dispatch modules.

    Extracted to avoid circular dependencies between
    tool_inline_dispatch, tool_inline_dispatch_coord, and tool_inline_dispatch_comm. *)

type tool_result = bool * string

(** Context record capturing all bindings from execute_tool_eio
    that the inline dispatch block needs. *)
type context =
  { config : Coord.config
  ; agent_name : string
  ; registry : Session.registry
  ; state : Mcp_server.server_state
  ; sw : Eio.Switch.t
  ; clock : float Eio.Time.clock_ty Eio.Resource.t
  ; arguments : Yojson.Safe.t
  ; mcp_session_id : string option
    (** Write agent name to MCP session file for HTTP persistence *)
  ; write_mcp_session_agent : string -> unit (** Wait for a message from a given agent *)
  ; wait_for_message :
      Session.registry -> agent_name:string -> timeout:float -> Yojson.Safe.t option
    (** Governance types/helpers — passed in to avoid circular deps *)
  ; governance_defaults : string -> Mcp_server_eio_governance.governance_config
  ; save_governance : Coord.config -> Mcp_server_eio_governance.governance_config -> unit
  ; load_mcp_sessions : Coord.config -> Mcp_server_eio_governance.mcp_session_record list
  ; save_mcp_sessions :
      Coord.config -> Mcp_server_eio_governance.mcp_session_record list -> unit
  }

(** Helper: run subprocess with 60s timeout *)
let safe_exec args =
  match Process_eio.run_argv_with_status ~timeout_sec:60.0 args with
  | Unix.WEXITED 0, output -> true, output
  | _, output -> false, if output = "" then "Command failed" else output
;;
