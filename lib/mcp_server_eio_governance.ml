(** Mcp_server_eio_governance — Governance configuration and MCP session helpers

    Extracted from mcp_server_eio.ml to reduce file size and enable reuse
    from Mcp_tool_runtime without circular dependencies.
*)

(** {1 Governance} *)

type governance_config = {
  level: string;
  audit_enabled: bool;
  anomaly_detection: bool;
} [@@deriving yojson { strict = false }]

let governance_defaults level =
  let level_lc = String.lowercase_ascii level in
  let audit_enabled =
    match level_lc with
    | "production" | "enterprise" | "paranoid" -> true
    | _ -> false
  in
  let anomaly_detection =
    match level_lc with
    | "enterprise" | "paranoid" -> true
    | _ -> false
  in
  { level = level_lc; audit_enabled; anomaly_detection }

let governance_path (config : Workspace.config) =
  Filename.concat (Workspace_utils.masc_dir config) "governance.json"

let load_governance (config : Workspace.config) : governance_config =
  let path = governance_path config in
  if Workspace_utils.path_exists config path then
    let json = Workspace_utils.read_json config path in
    let level = Json_util.get_string json "level" |> Option.value ~default:"development" in
    let defaults = governance_defaults level in
    let audit_enabled =
      Json_util.get_bool json "audit_enabled" |> Option.value ~default:defaults.audit_enabled
    in
    let anomaly_detection =
      Json_util.get_bool json "anomaly_detection" |> Option.value ~default:defaults.anomaly_detection
    in
    { level = String.lowercase_ascii level; audit_enabled; anomaly_detection }
  else
    governance_defaults "development"

let save_governance_result (config : Workspace.config) (g : governance_config) =
  let json = match governance_config_to_yojson g with
    | `Assoc fields ->
        `Assoc (fields @ [("updated_at", `String (Masc_domain.now_iso ()))])
    | other -> other
  in
  Workspace_utils.write_json_result config (governance_path config) json

let save_governance (config : Workspace.config) (g : governance_config) =
  match save_governance_result config g with
  | Ok () -> ()
  | Error error -> raise (Sys_error error)

(** {1 MCP Sessions} *)

type mcp_session_record = {
  id: string;
  agent_name: string option; [@default None]
  created_at: float;
  last_seen: float;
} [@@deriving yojson { strict = false }]

let mcp_sessions_path (config : Workspace.config) =
  Filename.concat (Workspace_utils.masc_dir config) "mcp-sessions.json"

let mcp_session_to_json = mcp_session_record_to_yojson

let mcp_session_of_json (json : Yojson.Safe.t) : mcp_session_record option =
  match mcp_session_record_of_yojson json with
  | Ok v -> Some v
  | Error detail ->
    Log.Misc.warn "MCP session JSON decode error discarded: %s" detail;
    None

let load_mcp_sessions (config : Workspace.config) : mcp_session_record list =
  let path = mcp_sessions_path config in
  if Workspace_utils.path_exists config path then
    let json = Workspace_utils.read_json config path in
    match json with
    | `List items -> List.filter_map mcp_session_of_json items
    | _ -> []
  else
    []

let save_mcp_sessions_result (config : Workspace.config)
    (sessions : mcp_session_record list) =
  let json = `List (List.map mcp_session_to_json sessions) in
  Workspace_utils.write_json_result config (mcp_sessions_path config) json

let save_mcp_sessions (config : Workspace.config)
    (sessions : mcp_session_record list) =
  match save_mcp_sessions_result config sessions with
  | Ok () -> ()
  | Error error -> raise (Sys_error error)
