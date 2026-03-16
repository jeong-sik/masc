(** MCP tools for long-running team sessions (1h orchestration).
    Facade: re-exports types from support, dispatch from handlers,
    schemas from Tool_team_session_schemas. *)

open Tool_team_session_handlers

type 'a context = 'a Tool_team_session_support.context = {
  config : Room.config;
  agent_name : string;
  sw : Eio.Switch.t;
  clock : 'a Eio.Time.clock;
  proc_mgr : Eio_unix.Process.mgr_ty Eio.Resource.t option;
}

type result = Tool_team_session_support.result

let dispatch ctx ~name ~args : result option =
  match name with
  | "masc_team_session_start" -> Some (handle_start ctx args)
  | "masc_team_session_step" -> Some (handle_step ctx args)
  | "masc_team_session_status" -> Some (handle_status ctx args)
  | "masc_team_session_finalize" -> Some (handle_finalize ctx args)
  | "masc_team_session_stop" -> Some (handle_stop ctx args)
  | "masc_team_session_report" -> Some (handle_report ctx args)
  | "masc_team_session_list" -> Some (handle_list ctx args)
  | "masc_team_session_compare" -> Some (handle_compare ctx args)
  | "masc_team_session_turn" -> Some (handle_turn ctx args)
  | "masc_team_session_events" -> Some (handle_events ctx args)
  | "masc_team_session_prove" -> Some (handle_prove ctx args)
  | "masc_team_session_verify_trace" -> Some (handle_verify_trace ctx args)
  | _ -> None

include Tool_team_session_schemas
