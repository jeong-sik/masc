(** MCP tools for long-running supervised execution sessions (1h orchestration).

    Thin facade that re-exports types from [Tool_team_session_support],
    delegates dispatch to [Tool_team_session_handlers], and includes
    schema definitions from [Tool_team_session_schemas]. *)

include Tool_team_session_support
include Tool_team_session_handlers

include Tool_team_session_schemas

(* ================================================================ *)
(* Tool_spec registration                                           *)
(* ================================================================ *)

let _tool_spec_read_only = [ "masc_team_session_status"; "masc_team_session_report"; "masc_team_session_list"; "masc_team_session_compare"; "masc_team_session_events"; "masc_team_session_prove" ]

let () =
  List.iter
    (fun (s : Types.tool_schema) ->
      Tool_spec.register
        (Tool_spec.create
           ~name:s.name
           ~description:s.description
           ~module_tag:Tool_dispatch.Mod_team_session
           ~input_schema:s.input_schema
           ~handler_binding:Tag_dispatch
           ~is_read_only:(List.mem s.name _tool_spec_read_only)
           ~is_idempotent:(List.mem s.name _tool_spec_read_only)
           ()))
    schemas
