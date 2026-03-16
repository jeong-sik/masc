(** MCP tools for long-running team sessions (1h orchestration).

    Thin facade that re-exports types from [Tool_team_session_support],
    delegates dispatch to [Tool_team_session_handlers], and includes
    schema definitions from [Tool_team_session_schemas]. *)

include Tool_team_session_support
include Tool_team_session_handlers

include Tool_team_session_schemas
