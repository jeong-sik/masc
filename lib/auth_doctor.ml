open Types

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

let canonicalize_path path =
  try Unix.realpath path with
  | Unix.Unix_error _ | Sys_error _ | Invalid_argument _ -> path

let file_exists path =
  try Sys.file_exists path with
  | Sys_error _ -> false

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
  [ Reader; Worker; Admin ]
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

let admin_bearer_sources ~auth_dir ~dashboard_dev_token_available
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
    |> List.filter_map (fun (cred : agent_credential) ->
           let token_file =
             raw_token_file_path ~auth_dir cred.agent_name
           in
           if file_exists token_file then
             Some (Printf.sprintf "token_file:%s" cred.agent_name)
           else
             None)
  in
  env_sources @ dashboard_sources @ token_file_sources
  |> dedupe_keep_order

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
    admin_bearer_sources ~auth_dir ~dashboard_dev_token_available
      ~admin_token_env_state credentials
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
    ]
    |> List.filter_map Fun.id
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
      Some "Rerun `masc-mcp doctor auth` after editing auth files or rotating tokens.";
    ]
    |> List.filter_map Fun.id
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
    default_role = agent_role_to_string auth_cfg.default_role;
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
    warnings;
    next_actions;
  }

let watched_agent_to_yojson agent =
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
    (fun agent ->
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
