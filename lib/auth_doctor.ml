open Masc_domain

type status =
  | Ok
  | Warn
  | Error

type watched_agent = {
  agent_name : string;
  credential_present : bool;
  credential_role : string option;
  can_admin : bool option;
  expires_at : string option;
  raw_token_file_present : bool;
}

type codex_mcp = {
  server_name : string;
  auth_model : string;
  token_env_var : string;
  token_env_configured : bool;
  token_status : string;
  token_agent : string option;
  token_role : string option;
  token_can_read_state : bool option;
  login_supported : bool;
  login_note : string;
  config : Codex_mcp_config_doctor.t;
}

type mcp_client = {
  client_name : string;
  agent_name : string;
  token_env_var : string;
  token_file_path : string;
  credential_present : bool;
  credential_role : string option;
  raw_token_file_present : bool;
  token_source : string;
  token_status : string;
  token_agent : string option;
  token_role : string option;
  token_can_read_state : bool option;
  identity_ready : bool;
}

type t = {
  status : status;
  base_path : string;
  auth_dir : string;
  auth_config_path : string;
  auth_enabled : bool;
  require_token : bool;
  default_role : string;
  initial_admin : string option;
  bind_host : string;
  bind_is_loopback : bool;
  http_auth_strict : bool;
  dashboard_dev_token_available : bool;
  dashboard_dev_token_file_present : bool;
  admin_token_env_configured : bool;
  admin_token_env_status : string;
  admin_token_env_agent : string option;
  admin_token_env_role : string option;
  token_bound_admin_http_ready : bool;
  admin_bearer_sources : string list;
  credential_count : int;
  role_counts : (string * int) list;
  watched_agents : watched_agent list;
  codex_mcp : codex_mcp;
  mcp_clients : mcp_client list;
  warnings : string list;
  next_actions : string list;
}

type admin_token_env_state =
  | Env_unset
  | Env_invalid_or_expired
  | Env_non_admin of agent_credential
  | Env_admin of agent_credential

let status_to_string = function
  | Ok -> "ok"
  | Warn -> "warn"
  | Error -> "error"

let codex_mcp_token_env_var = "MASC_MCP_TOKEN"

let codex_mcp_login_note =
  "`codex mcp login` is OAuth-only; masc-mcp uses bearer token auth."

type mcp_client_spec = {
  client_name : string;
  agent_name : string;
  token_env_var : string;
}

let mcp_client_specs =
  [
    {
      client_name = "codex";
      agent_name = "codex-mcp-client";
      token_env_var = codex_mcp_token_env_var;
    };
    {
      client_name = "claude";
      agent_name = "claude";
      token_env_var = "MASC_CLAUDE_MCP_TOKEN";
    };
    {
      client_name = "gemini";
      agent_name = "gemini";
      token_env_var = "MASC_GEMINI_MCP_TOKEN";
    };
  ]

let canonicalize_path path =
  try Unix.realpath path with
  | Unix.Unix_error _ | Sys_error _ | Invalid_argument _ -> path

let file_exists path =
  try Sys.file_exists path with
  | Sys_error _ -> false

let read_nonempty_text_file path =
  if not (file_exists path) then
    None
  else
    try
      let value = String.trim (Fs_compat.load_file path) in
      if value = "" then None else Some value
    with Sys_error _ -> None

let dedupe_keep_order values =
  let seen = Hashtbl.create (List.length values) in
  List.filter
    (fun value ->
      if value = "" || Hashtbl.mem seen value then
        false
      else (
        Hashtbl.replace seen value ();
        true))
    values

let option_field name = function
  | Some value -> (name, `String value)
  | None -> (name, `Null)

let raw_token_file_path ~auth_dir agent_name =
  Filename.concat auth_dir (agent_name ^ ".token")

let watched_agent_of_credential ~auth_dir agent_name credential_opt =
  let raw_token_file_present =
    file_exists (raw_token_file_path ~auth_dir agent_name)
  in
  match credential_opt with
  | Some (cred : agent_credential) ->
      {
        agent_name;
        credential_present = true;
        credential_role = Some (agent_role_to_string cred.role);
        can_admin = Some (has_permission cred.role CanAdmin);
        expires_at = cred.expires_at;
        raw_token_file_present;
      }
  | None ->
      {
        agent_name;
        credential_present = false;
        credential_role = None;
        can_admin = None;
        expires_at = None;
        raw_token_file_present;
      }

let watched_agent_names ~initial_admin admin_token_env_agent =
  [
    Some "codex";
    Some "codex-mcp-client";
    Some "dashboard-dev";
    Some "admin";
    initial_admin;
    admin_token_env_agent;
  ]
  |> List.filter_map Fun.id
  |> dedupe_keep_order

let admin_token_env_state ~base_path =
  match Env_config_core.admin_token_opt () with
  | None -> Env_unset
  | Some raw_token -> (
      match Auth.find_credential_by_token base_path ~token:raw_token with
      | Ok cred ->
          if has_permission cred.role CanAdmin then
            Env_admin cred
          else
            Env_non_admin cred
      | Error _ -> Env_invalid_or_expired)

let admin_token_env_fields = function
  | Env_unset -> ("unset", None, None)
  | Env_invalid_or_expired -> ("invalid_or_expired", None, None)
  | Env_non_admin cred ->
      ( "non_admin",
        Some cred.agent_name,
        Some (agent_role_to_string cred.role) )
  | Env_admin cred ->
      ("admin", Some cred.agent_name, Some (agent_role_to_string cred.role))

let role_counts_of_credentials credentials =
  [ Worker; Admin ]
  |> List.filter_map (fun role ->
         let count =
           List.fold_left
             (fun acc cred -> if cred.role = role then acc + 1 else acc)
             0 credentials
         in
         if count = 0 then
           None
         else
           Some (agent_role_to_string role, count))

let live_admin_token_file_source ~base_path ~auth_dir (cred : agent_credential) =
  let token_file = raw_token_file_path ~auth_dir cred.agent_name in
  match read_nonempty_text_file token_file with
  | None -> None
  | Some raw_token -> (
      match Auth.find_credential_by_token base_path ~token:raw_token with
      | Ok owner
        when String.equal owner.agent_name cred.agent_name
             && has_permission owner.role CanAdmin ->
          Some (Printf.sprintf "token_file:%s" cred.agent_name)
      | Ok _ | Error _ -> None)

let admin_bearer_sources ~base_path ~auth_dir ~dashboard_dev_token_available
    ~admin_token_env_state (credentials : agent_credential list) =
  let env_sources =
    match admin_token_env_state with
    | Env_admin cred ->
        [ Printf.sprintf "env:%s->%s"
            Env_config_core.admin_token_env_key cred.agent_name ]
    | Env_unset | Env_invalid_or_expired | Env_non_admin _ -> []
  in
  let dashboard_sources =
    if dashboard_dev_token_available then
      [ "dashboard_dev_endpoint" ]
    else
      []
  in
  let token_file_sources =
    credentials
    |> List.filter (fun (cred : agent_credential) ->
           has_permission cred.role CanAdmin)
    |> List.filter_map (live_admin_token_file_source ~base_path ~auth_dir)
  in
  env_sources @ dashboard_sources @ token_file_sources
  |> dedupe_keep_order

let codex_mcp_report ~base_path =
  let config = Codex_mcp_config_doctor.analyze_default () in
  match
    Sys.getenv_opt codex_mcp_token_env_var |> Env_config_core.trim_opt
  with
  | None ->
      {
        server_name = "masc";
        auth_model = "bearer_token_env";
        token_env_var = codex_mcp_token_env_var;
        token_env_configured = false;
        token_status = "unset";
        token_agent = None;
        token_role = None;
        token_can_read_state = None;
        login_supported = false;
        login_note = codex_mcp_login_note;
        config;
      }
  | Some raw_token -> (
      match Auth.find_credential_by_token base_path ~token:raw_token with
      | Ok cred ->
          {
            server_name = "masc";
            auth_model = "bearer_token_env";
            token_env_var = codex_mcp_token_env_var;
            token_env_configured = true;
            token_status = "live";
            token_agent = Some cred.agent_name;
            token_role = Some (agent_role_to_string cred.role);
            token_can_read_state =
              Some (has_permission cred.role CanReadState);
            login_supported = false;
            login_note = codex_mcp_login_note;
            config;
          }
      | Error _ ->
          {
            server_name = "masc";
            auth_model = "bearer_token_env";
            token_env_var = codex_mcp_token_env_var;
            token_env_configured = true;
            token_status = "invalid_or_expired";
            token_agent = None;
            token_role = None;
            token_can_read_state = None;
            login_supported = false;
            login_note = codex_mcp_login_note;
            config;
          })

let mcp_client_report ~base_path ~auth_dir
    ({ client_name; agent_name; token_env_var } : mcp_client_spec) =
  let token_file_path = raw_token_file_path ~auth_dir agent_name in
  let credential_opt = Auth.load_credential base_path agent_name in
  let raw_token_file_present = file_exists token_file_path in
  let token_source, raw_token =
    match Sys.getenv_opt token_env_var |> Env_config_core.trim_opt with
    | Some value -> ("env", Some value)
    | None -> (
        match read_nonempty_text_file token_file_path with
        | Some value -> ("token_file", Some value)
        | None -> ("missing", None))
  in
  let token_status, token_agent, token_role, token_can_read_state =
    match raw_token with
    | None -> ("missing", None, None, None)
    | Some token -> (
        match Auth.find_credential_by_token base_path ~token with
        | Ok cred ->
            let status =
              if String.equal cred.agent_name agent_name then
                "live"
              else
                "wrong_agent"
            in
            ( status,
              Some cred.agent_name,
              Some (agent_role_to_string cred.role),
              Some (has_permission cred.role CanReadState) )
        | Error _ -> ("invalid_or_expired", None, None, None))
  in
  let identity_ready =
    Option.is_some credential_opt && String.equal token_status "live"
  in
  {
    client_name;
    agent_name;
    token_env_var;
    token_file_path;
    credential_present = Option.is_some credential_opt;
    credential_role = Option.map (fun (cred : agent_credential) -> agent_role_to_string cred.role) credential_opt;
    raw_token_file_present;
    token_source;
    token_status;
    token_agent;
    token_role;
    token_can_read_state;
    identity_ready;
  }

let mcp_client_warning (client : mcp_client) =
  match client.token_status with
  | "wrong_agent" ->
      Some
        (Printf.sprintf
           "%s MCP bearer resolves to %s instead of %s; rerun `masc-mcp login --agent %s --role worker --shell` and `sb mcp sync`."
           client.client_name
           (Option.value ~default:"(unknown)" client.token_agent)
           client.agent_name client.agent_name)
  | "invalid_or_expired" ->
      Some
        (Printf.sprintf
           "%s MCP bearer from %s is invalid or expired; rerun `masc-mcp login --agent %s --role worker --shell` and `sb mcp sync`."
           client.client_name client.token_source client.agent_name)
  | _ -> None

let mcp_client_next_action (client : mcp_client) =
  if client.identity_ready then
    None
  else
    Some
      (Printf.sprintf
         "For %s MCP, run `masc-mcp login --agent %s --role worker --shell`, then `sb mcp sync` so its bearer and X-MASC-Agent match."
         client.client_name client.agent_name)

let analyze ~base_path_input ~default_base_path () =
  let normalized_base_path =
    Env_config_core.normalize_masc_base_path_input base_path_input
  in
  let base_path =
    let candidate =
      if String.trim normalized_base_path = "" then
        default_base_path
      else
        normalized_base_path
    in
    canonicalize_path candidate
  in
  let auth_dir = Auth.auth_dir base_path in
  let auth_cfg = Auth.load_auth_config base_path in
  let credentials = Auth.list_credentials base_path in
  let initial_admin = Auth.read_initial_admin base_path in
  let admin_token_env_state = admin_token_env_state ~base_path in
  let admin_token_env_status, admin_token_env_agent, admin_token_env_role =
    admin_token_env_fields admin_token_env_state
  in
  let bind_host = Server_auth.http_auth_bind_host () in
  let bind_is_loopback = Server_auth.http_auth_bind_is_loopback () in
  let http_auth_strict = Server_auth.http_auth_strict_enabled () in
  let dashboard_dev_token_available =
    bind_is_loopback && not http_auth_strict
  in
  let dashboard_dev_token_file_present =
    file_exists (Filename.concat auth_dir "dashboard-dev.token")
  in
  let admin_bearer_sources =
    admin_bearer_sources ~base_path ~auth_dir
      ~dashboard_dev_token_available ~admin_token_env_state credentials
  in
  let codex_mcp = codex_mcp_report ~base_path in
  let mcp_clients =
    List.map (mcp_client_report ~base_path ~auth_dir) mcp_client_specs
  in
  let token_bound_admin_http_ready =
    auth_cfg.enabled && auth_cfg.require_token && admin_bearer_sources <> []
  in
  let watched_agents =
    watched_agent_names ~initial_admin admin_token_env_agent
    |> List.map (fun agent_name ->
           watched_agent_of_credential ~auth_dir agent_name
             (Auth.load_credential base_path agent_name))
  in
  let admin_permission = show_permission CanAdmin in
  let codex = Auth.load_credential base_path "codex" in
  let codex_mcp_client =
    Auth.load_credential base_path "codex-mcp-client"
  in
  let warnings =
    [
      (if not auth_cfg.enabled then
         Some
           "Room auth is disabled; token-bound admin HTTP mutation routes will reject until auth is enabled."
       else
         None);
      (if auth_cfg.enabled && not auth_cfg.require_token then
         Some
           "Room auth does not require bearer tokens; token-bound admin HTTP mutation routes will reject until require_token=true."
       else
         None);
      (match admin_token_env_state with
       | Env_invalid_or_expired ->
           Some
             (Printf.sprintf
                "%s is set, but it does not resolve to a live credential in this base path."
                Env_config_core.admin_token_env_key)
       | Env_non_admin cred ->
           Some
             (Printf.sprintf
                "%s resolves to %s with role=%s, so it cannot satisfy %s."
                Env_config_core.admin_token_env_key
                cred.agent_name
                (agent_role_to_string cred.role)
                admin_permission)
       | Env_unset | Env_admin _ -> None);
      (if auth_cfg.enabled && auth_cfg.require_token
          && not token_bound_admin_http_ready then
         Some
           "No usable admin bearer source was detected for token-bound admin HTTP mutation routes."
       else
         None);
      (match codex with
       | Some cred when not (has_permission cred.role CanAdmin) ->
           Some
             (Printf.sprintf
                "codex is role=%s, so requests authenticated as codex cannot satisfy %s."
                (agent_role_to_string cred.role)
                admin_permission)
       | _ -> None);
      (match codex_mcp_client with
       | Some cred when not (has_permission cred.role CanAdmin) ->
           Some
             (Printf.sprintf
                "codex-mcp-client is role=%s, so dashboard save flows using that bearer will fail on admin-only routes such as POST /api/v1/cascade/config/raw."
                (agent_role_to_string cred.role))
       | _ -> None);
      (if not dashboard_dev_token_available then
         Some
           "Dashboard dev-token bootstrap is unavailable because the bind host is non-loopback or HTTP strict auth is enabled."
       else
         None);
      (if auth_cfg.enabled && auth_cfg.require_token then
         match codex_mcp.token_status with
         | "unset" ->
             Some
               "Codex MCP bearer env var MASC_MCP_TOKEN is unset; Codex should use bearer_token_env_var, not `codex mcp login`."
         | "invalid_or_expired" ->
             Some
               "Codex MCP bearer env var MASC_MCP_TOKEN is set, but it does not resolve to a live credential in this base path."
         | "live" -> None
         | _ -> None
       else
         None);
    ]
    |> List.filter_map Fun.id
    |> (fun values ->
         values
         @ List.filter_map mcp_client_warning mcp_clients
         @ Codex_mcp_config_doctor.warnings codex_mcp.config)
    |> dedupe_keep_order
  in
  let next_actions =
    [
      (if not auth_cfg.enabled then
         Some
           (Printf.sprintf
              "Enable room auth and set require_token=true in %s before relying on admin HTTP mutation routes."
              (Auth.auth_config_file base_path))
       else
         None);
      (if auth_cfg.enabled && not auth_cfg.require_token then
         Some
           (Printf.sprintf
              "Set require_token=true in %s so token-bound admin HTTP routes can authorize bearer tokens."
              (Auth.auth_config_file base_path))
       else
         None);
      (if auth_cfg.enabled && auth_cfg.require_token
          && (match codex_mcp_client with
              | Some cred -> not (has_permission cred.role CanAdmin)
              | None -> false) then
         Some
           "Use dashboard-dev or another admin bearer for POST /api/v1/cascade/config/raw; the codex-mcp-client worker bearer cannot satisfy CanAdmin."
       else
         None);
      (if auth_cfg.enabled && auth_cfg.require_token
          && dashboard_dev_token_available then
         Some
           "On loopback dev setups, fetch an admin bearer from GET /api/v1/dashboard/dev-token before using admin-only dashboard actions."
       else
         None);
      (if auth_cfg.enabled && auth_cfg.require_token
          && not dashboard_dev_token_available then
         Some
           "Follow docs/LOCAL-DASHBOARD-AUTH-RUNBOOK.md to bootstrap an admin bearer under the live auth root."
       else
         None);
      (if auth_cfg.enabled && auth_cfg.require_token
          && not (String.equal codex_mcp.token_status "live") then
         Some
           "For Codex MCP, run `masc-mcp login --agent codex-mcp-client --role worker --shell` and export MASC_MCP_TOKEN; do not run `codex mcp login masc`."
       else
         None);
      Some "For Codex MCP pipeline drift, inspect the codex_mcp.config.stages section from `masc-mcp doctor auth --json`.";
      Some "Rerun `masc-mcp doctor auth` after editing auth files or rotating tokens.";
    ]
    |> List.filter_map Fun.id
    |> (fun values ->
         values
         @ List.filter_map mcp_client_next_action mcp_clients
         @ Codex_mcp_config_doctor.next_actions codex_mcp.config)
    |> dedupe_keep_order
  in
  let status =
    if auth_cfg.enabled && auth_cfg.require_token
       && not token_bound_admin_http_ready then
      Error
    else if warnings = [] then
      Ok
    else
      Warn
  in
  {
    status;
    base_path;
    auth_dir;
    auth_config_path = Auth.auth_config_file base_path;
    auth_enabled = auth_cfg.enabled;
    require_token = auth_cfg.require_token;
    default_role = agent_role_to_string Worker;
    initial_admin;
    bind_host;
    bind_is_loopback;
    http_auth_strict;
    dashboard_dev_token_available;
    dashboard_dev_token_file_present;
    admin_token_env_configured = Env_config_core.admin_token_opt () <> None;
    admin_token_env_status;
    admin_token_env_agent;
    admin_token_env_role;
    token_bound_admin_http_ready;
    admin_bearer_sources;
    credential_count = List.length credentials;
    role_counts = role_counts_of_credentials credentials;
    watched_agents;
    codex_mcp;
    mcp_clients;
    warnings;
    next_actions;
  }

let watched_agent_to_yojson (agent : watched_agent) =
  `Assoc
    [
      ("agent_name", `String agent.agent_name);
      ("credential_present", `Bool agent.credential_present);
      (option_field "role" agent.credential_role);
      ( "can_admin",
        match agent.can_admin with
        | Some value -> `Bool value
        | None -> `Null );
      (option_field "expires_at" agent.expires_at);
      ("raw_token_file_present", `Bool agent.raw_token_file_present);
    ]

let codex_mcp_to_yojson codex_mcp =
  `Assoc
    [
      ("server_name", `String codex_mcp.server_name);
      ("auth_model", `String codex_mcp.auth_model);
      ("token_env_var", `String codex_mcp.token_env_var);
      ("token_env_configured", `Bool codex_mcp.token_env_configured);
      ("token_status", `String codex_mcp.token_status);
      (option_field "token_agent" codex_mcp.token_agent);
      (option_field "token_role" codex_mcp.token_role);
      ( "token_can_read_state",
        match codex_mcp.token_can_read_state with
        | Some value -> `Bool value
        | None -> `Null );
      ("login_supported", `Bool codex_mcp.login_supported);
      ("login_note", `String codex_mcp.login_note);
      ("config", Codex_mcp_config_doctor.to_yojson codex_mcp.config);
    ]

let mcp_client_to_yojson (client : mcp_client) =
  `Assoc
    [
      ("client_name", `String client.client_name);
      ("agent_name", `String client.agent_name);
      ("token_env_var", `String client.token_env_var);
      ("token_file_path", `String client.token_file_path);
      ("credential_present", `Bool client.credential_present);
      (option_field "credential_role" client.credential_role);
      ("raw_token_file_present", `Bool client.raw_token_file_present);
      ("token_source", `String client.token_source);
      ("token_status", `String client.token_status);
      (option_field "token_agent" client.token_agent);
      (option_field "token_role" client.token_role);
      ( "token_can_read_state",
        match client.token_can_read_state with
        | Some value -> `Bool value
        | None -> `Null );
      ("identity_ready", `Bool client.identity_ready);
    ]

let to_yojson (report : t) =
  `Assoc
    [
      ("status", `String (status_to_string report.status));
      ("base_path", `String report.base_path);
      ("auth_dir", `String report.auth_dir);
      ("auth_config_path", `String report.auth_config_path);
      ("auth_enabled", `Bool report.auth_enabled);
      ("require_token", `Bool report.require_token);
      ("default_role", `String report.default_role);
      (option_field "initial_admin" report.initial_admin);
      ("bind_host", `String report.bind_host);
      ("bind_is_loopback", `Bool report.bind_is_loopback);
      ("http_auth_strict", `Bool report.http_auth_strict);
      ( "dashboard_dev_token",
        `Assoc
          [
            ("available", `Bool report.dashboard_dev_token_available);
            ("file_present", `Bool report.dashboard_dev_token_file_present);
          ] );
      ( "admin_token_env",
        `Assoc
          [
            ("configured", `Bool report.admin_token_env_configured);
            ("status", `String report.admin_token_env_status);
            (option_field "agent" report.admin_token_env_agent);
            (option_field "role" report.admin_token_env_role);
          ] );
      ("token_bound_admin_http_ready", `Bool report.token_bound_admin_http_ready);
      ( "admin_bearer_sources",
        `List (List.map (fun value -> `String value) report.admin_bearer_sources) );
      ("credential_count", `Int report.credential_count);
      ( "role_counts",
        `Assoc
          (List.map
             (fun (role, count) -> (role, `Int count))
             report.role_counts) );
      ( "watched_agents",
        `List (List.map watched_agent_to_yojson report.watched_agents) );
      ("codex_mcp", codex_mcp_to_yojson report.codex_mcp);
      ( "mcp_clients",
        `List (List.map mcp_client_to_yojson report.mcp_clients) );
      ("warnings", `List (List.map (fun value -> `String value) report.warnings));
      ("next_actions", `List (List.map (fun value -> `String value) report.next_actions));
    ]

let render_text (report : t) =
  let buf = Buffer.create 1024 in
  let add_line line =
    Buffer.add_string buf line;
    Buffer.add_char buf '\n'
  in
  let yes_no value = if value then "yes" else "no" in
  let option_value = Option.value ~default:"(unset)" in
  add_line "MASC Auth Doctor";
  add_line (Printf.sprintf "status: %s" (status_to_string report.status));
  add_line (Printf.sprintf "base_path: %s" report.base_path);
  add_line (Printf.sprintf "auth_dir: %s" report.auth_dir);
  add_line (Printf.sprintf "auth_config_path: %s" report.auth_config_path);
  add_line (Printf.sprintf "auth_enabled: %s" (yes_no report.auth_enabled));
  add_line (Printf.sprintf "require_token: %s" (yes_no report.require_token));
  add_line (Printf.sprintf "default_role: %s" report.default_role);
  add_line
    (Printf.sprintf "initial_admin: %s"
       (option_value report.initial_admin));
  add_line (Printf.sprintf "bind_host: %s" report.bind_host);
  add_line
    (Printf.sprintf "bind_is_loopback: %s"
       (yes_no report.bind_is_loopback));
  add_line
    (Printf.sprintf "http_auth_strict: %s"
       (yes_no report.http_auth_strict));
  add_line
    (Printf.sprintf "dashboard_dev_token: available=%s file_present=%s"
       (yes_no report.dashboard_dev_token_available)
       (yes_no report.dashboard_dev_token_file_present));
  add_line
    (Printf.sprintf
       "admin_token_env: configured=%s status=%s agent=%s role=%s"
       (yes_no report.admin_token_env_configured)
       report.admin_token_env_status
       (option_value report.admin_token_env_agent)
       (option_value report.admin_token_env_role));
  add_line
    (Printf.sprintf "token_bound_admin_http_ready: %s"
       (yes_no report.token_bound_admin_http_ready));
  add_line
    (Printf.sprintf "admin_bearer_sources: %s"
       (match report.admin_bearer_sources with
        | [] -> "(none)"
        | values -> String.concat ", " values));
  add_line
    (Printf.sprintf "credential_count: %d" report.credential_count);
  add_line
    (Printf.sprintf "role_counts: %s"
       (match report.role_counts with
        | [] -> "(none)"
        | values ->
            values
            |> List.map (fun (role, count) ->
                   Printf.sprintf "%s=%d" role count)
            |> String.concat ", "));
  add_line "";
  add_line "watched_agents:";
  List.iter
    (fun (agent : watched_agent) ->
      add_line
        (Printf.sprintf
           "- %s: credential=%s role=%s can_admin=%s raw_token_file=%s expires_at=%s"
           agent.agent_name
           (yes_no agent.credential_present)
           (option_value agent.credential_role)
           (match agent.can_admin with
            | Some value -> yes_no value
            | None -> "(n/a)")
           (yes_no agent.raw_token_file_present)
           (option_value agent.expires_at)))
    report.watched_agents;
  add_line "";
  add_line "codex_mcp:";
  add_line
    (Printf.sprintf "- server_name: %s" report.codex_mcp.server_name);
  add_line
    (Printf.sprintf "- auth_model: %s" report.codex_mcp.auth_model);
  add_line
    (Printf.sprintf "- token_env_var: %s"
       report.codex_mcp.token_env_var);
  add_line
    (Printf.sprintf "- token_env_configured: %s"
       (yes_no report.codex_mcp.token_env_configured));
  add_line
    (Printf.sprintf "- token_status: %s"
       report.codex_mcp.token_status);
  add_line
    (Printf.sprintf "- token_agent: %s"
       (option_value report.codex_mcp.token_agent));
  add_line
    (Printf.sprintf "- token_role: %s"
       (option_value report.codex_mcp.token_role));
  add_line
    (Printf.sprintf "- token_can_read_state: %s"
       (match report.codex_mcp.token_can_read_state with
        | Some value -> yes_no value
        | None -> "(n/a)"));
  add_line
    (Printf.sprintf "- login_supported: %s"
       (yes_no report.codex_mcp.login_supported));
  add_line (Printf.sprintf "- login_note: %s" report.codex_mcp.login_note);
  add_line "- config:";
  add_line
    (Printf.sprintf "  path: %s"
       (option_value report.codex_mcp.config.config_path));
  add_line
    (Printf.sprintf "  file_present: %s"
       (yes_no report.codex_mcp.config.file_present));
  add_line
    (Printf.sprintf "  server_names: %s"
       (match report.codex_mcp.config.server_names with
        | [] -> "(none)"
        | names -> String.concat ", " names));
  add_line "  stages:";
  List.iter
    (fun (stage : Codex_mcp_config_doctor.stage) ->
      add_line
        (Printf.sprintf "  - %s: %s - %s" stage.name
           (Codex_mcp_config_doctor.stage_status_to_string stage.status)
           stage.detail))
    report.codex_mcp.config.stages;
  add_line "";
  add_line "mcp_clients:";
  List.iter
    (fun (client : mcp_client) ->
      add_line
        (Printf.sprintf
           "- %s: agent=%s env=%s token_file=%s credential=%s token_source=%s token_status=%s token_agent=%s identity_ready=%s"
           client.client_name client.agent_name client.token_env_var
           client.token_file_path
           (yes_no client.credential_present)
           client.token_source client.token_status
           (option_value client.token_agent)
           (yes_no client.identity_ready)))
    report.mcp_clients;
  if report.warnings <> [] then begin
    add_line "";
    add_line "warnings:";
    List.iter
      (fun warning -> add_line (Printf.sprintf "- %s" warning))
      report.warnings
  end;
  if report.next_actions <> [] then begin
    add_line "";
    add_line "next_actions:";
    List.iter
      (fun action -> add_line (Printf.sprintf "- %s" action))
      report.next_actions
  end;
  Buffer.contents buf |> String.trim

let exit_code (report : t) =
  match report.status with
  | Ok -> 0
  | Warn | Error -> 1
