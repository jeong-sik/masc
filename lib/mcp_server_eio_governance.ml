(** Mcp_server_eio_governance — Governance configuration and MCP session helpers

    Extracted from mcp_server_eio.ml to reduce file size and enable reuse
    from Tool_inline_dispatch without circular dependencies.
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

let governance_path (config : Coord.config) =
  Filename.concat (Coord_utils.masc_dir config) "governance.json"

let ensure_masc_dir (config : Coord.config) =
  let dir = Coord_utils.masc_dir config in
  if not (Sys.file_exists dir) then
    Coord_utils.mkdir_p dir

let load_governance (config : Coord.config) : governance_config =
  let path = governance_path config in
  if Coord_utils.path_exists config path then
    let json = Coord_utils.read_json config path in
    let module U = Yojson.Safe.Util in
    let level = Json_util.get_string json "level" |> Option.value ~default:"development" in
    let defaults = governance_defaults level in
    let audit_enabled =
      match json |> U.member "audit_enabled" with
      | `Bool b -> b
      | _ -> defaults.audit_enabled
    in
    let anomaly_detection =
      match json |> U.member "anomaly_detection" with
      | `Bool b -> b
      | _ -> defaults.anomaly_detection
    in
    { level = String.lowercase_ascii level; audit_enabled; anomaly_detection }
  else
    governance_defaults "development"

let save_governance (config : Coord.config) (g : governance_config) =
  ensure_masc_dir config;
  let json = match governance_config_to_yojson g with
    | `Assoc fields ->
        `Assoc (fields @ [("updated_at", `String (Masc_domain.now_iso ()))])
    | other -> other
  in
  Coord_utils.write_json config (governance_path config) json

(** {1 MCP Sessions} *)

type mcp_session_record = {
  id: string;
  agent_name: string option; [@default None]
  created_at: float;
  last_seen: float;
} [@@deriving yojson { strict = false }]

let mcp_sessions_path (config : Coord.config) =
  Filename.concat (Coord_utils.masc_dir config) "mcp-sessions.json"

let mcp_session_to_json = mcp_session_record_to_yojson

let mcp_session_of_json (json : Yojson.Safe.t) : mcp_session_record option =
  match mcp_session_record_of_yojson json with
  | Ok v -> Some v
  | Error detail ->
    Log.Misc.warn "MCP session JSON decode error discarded: %s" detail;
    None

let load_mcp_sessions (config : Coord.config) : mcp_session_record list =
  let path = mcp_sessions_path config in
  if Coord_utils.path_exists config path then
    let json = Coord_utils.read_json config path in
    match json with
    | `List items -> List.filter_map mcp_session_of_json items
    | _ -> []
  else
    []

let save_mcp_sessions (config : Coord.config) (sessions : mcp_session_record list) =
  ensure_masc_dir config;
  let json = `List (List.map mcp_session_to_json sessions) in
  Coord_utils.write_json config (mcp_sessions_path config) json
