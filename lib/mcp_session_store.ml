(** Durable MCP session records. This module has no authorization policy. *)

type mcp_session_record =
  { id : string
  ; agent_name : string option [@default None]
  ; created_at : float
  ; last_seen : float
  }
[@@deriving yojson { strict = false }]

let mcp_sessions_path (config : Workspace.config) =
  Filename.concat (Workspace_utils.masc_dir config) "mcp-sessions.json"
;;

let ensure_masc_dir (config : Workspace.config) =
  let dir = Workspace_utils.masc_dir config in
  if not (Sys.file_exists dir) then Workspace_utils.mkdir_p dir
;;

let mcp_session_to_json = mcp_session_record_to_yojson

let mcp_session_of_json (json : Yojson.Safe.t) : mcp_session_record option =
  match mcp_session_record_of_yojson json with
  | Ok value -> Some value
  | Error detail ->
    Log.Misc.warn "MCP session JSON decode error discarded: %s" detail;
    None
;;

let load_mcp_sessions (config : Workspace.config) : mcp_session_record list =
  let path = mcp_sessions_path config in
  if Workspace_utils.path_exists config path
  then (
    let json = Workspace_utils.read_json config path in
    match json with
    | `List items -> List.filter_map mcp_session_of_json items
    | other ->
      Log.Misc.warn
        "MCP session store expected a JSON list, got %s"
        (Json_util.kind_name other);
      [])
  else []
;;

let save_mcp_sessions (config : Workspace.config) (sessions : mcp_session_record list) =
  ensure_masc_dir config;
  let json = `List (List.map mcp_session_to_json sessions) in
  Workspace_utils.write_json config (mcp_sessions_path config) json
;;
