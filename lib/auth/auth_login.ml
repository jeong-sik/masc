open Masc_domain

type auth_change =
  | Auth_already_required
  | Auth_enabled
  | Require_token_enabled

type token_lifetime =
  | With_expiry
  | Long_lived

type t = {
  base_path : string;
  auth_config_path : string;
  auth_change : auth_change;
  agent_name : string;
  role : agent_role;
  bearer_token : string;
  raw_token_file : string;
  dashboard_url : string;
  mcp_url : string;
  mcp_token_env_var : string;
}

let ensure_rng_initialized = Auth_credential_base.ensure_rng_initialized

let auth_change_to_string = function
  | Auth_already_required -> "already_required"
  | Auth_enabled -> "auth_enabled"
  | Require_token_enabled -> "require_token_enabled"

let normalize_base_path path =
  Env_config_core.normalize_masc_base_path_input path

let url_encode value =
  let buf = Buffer.create (String.length value) in
  String.iter
    (function
      | ('A' .. 'Z' | 'a' .. 'z' | '0' .. '9' | '-' | '_' | '.' | '~') as c
        ->
          Buffer.add_char buf c
      | c -> Printf.bprintf buf "%%%02X" (Char.code c))
    value;
  Buffer.contents buf

let single_quote_shell value =
  "'" ^ String.concat "'\\''" (String.split_on_char '\'' value) ^ "'"

let token_file_path ~base_path ~agent_name =
  Filename.concat (Auth.auth_dir base_path) (agent_name ^ ".token")

let persist_raw_token ~base_path ~agent_name raw_token =
  let path = token_file_path ~base_path ~agent_name in
  Fs_compat.mkdir_p (Filename.dirname path);
  Auth.save_private_text_file path raw_token;
  path

let ensure_required_bearer_auth ~base_path ~agent_name =
  let cfg = Auth.load_auth_config base_path in
  if cfg.enabled && cfg.require_token then
    Ok Auth_already_required
  else if not cfg.enabled then
    let _workspace_secret, _bootstrap_token =
      Auth.enable_auth base_path ~require_token:true ~agent_name
    in
    Ok Auth_enabled
  else (
    Auth.save_auth_config base_path { cfg with require_token = true };
    Ok Require_token_enabled)

let create_token_for_lifetime = function
  | With_expiry -> Auth.create_token
  | Long_lived -> Auth.create_token_without_expiry

let mint ~base_path ~host ~port ~agent_name ~role ~token_env_var
    ~token_lifetime () =
  ensure_rng_initialized ();
  let base_path = normalize_base_path base_path in
  match ensure_required_bearer_auth ~base_path ~agent_name with
  | Error err -> Error err
  | Ok auth_change -> (
      let create_token = create_token_for_lifetime token_lifetime in
      match create_token base_path ~agent_name ~role with
      | Error err -> Error err
      | Ok (bearer_token, cred) ->
          let raw_token_file =
            persist_raw_token ~base_path ~agent_name bearer_token
          in
          let agent_param = url_encode agent_name in
          let token_param = url_encode bearer_token in
          let dashboard_url =
            Printf.sprintf "http://%s:%d/dashboard?agent=%s&token=%s"
              host port agent_param token_param
          in
          let mcp_url = Printf.sprintf "http://%s:%d/mcp" host port in
          Ok
            {
              base_path;
              auth_config_path = Auth.auth_config_file base_path;
              auth_change;
              agent_name = cred.agent_name;
              role = cred.role;
              bearer_token;
              raw_token_file;
              dashboard_url;
              mcp_url;
              mcp_token_env_var = token_env_var;
            })

let to_yojson report =
  Tool_args.ok_assoc
    [
      ("base_path", `String report.base_path);
      ("auth_config_path", `String report.auth_config_path);
      ("auth_change", `String (auth_change_to_string report.auth_change));
      ("agent_name", `String report.agent_name);
      ("role", `String (agent_role_to_string report.role));
      ("bearer_token", `String report.bearer_token);
      ("raw_token_file", `String report.raw_token_file);
      ("dashboard_url", `String report.dashboard_url);
      ("mcp_url", `String report.mcp_url);
      ( "mcp_client",
        `Assoc
          [
            ("server_name", `String "masc");
            ("agent_name", `String report.agent_name);
            ("auth_model", `String "bearer_token_env");
            ("token_env_var", `String report.mcp_token_env_var);
          ] );
    ]

let render_shell report =
  String.concat "\n"
    [
      Printf.sprintf "export MASC_OPERATOR_AGENT=%s"
        (single_quote_shell report.agent_name);
      Printf.sprintf "export MASC_OPERATOR_TOKEN=%s"
        (single_quote_shell report.bearer_token);
      Printf.sprintf "export %s=%s" report.mcp_token_env_var
        (single_quote_shell report.bearer_token);
      Printf.sprintf "export MASC_DASHBOARD_URL=%s"
        (single_quote_shell report.dashboard_url);
    ]

let render_text report =
  String.concat "\n"
    [
      "MASC Login";
      "status: ok";
      Printf.sprintf "base_path: %s" report.base_path;
      Printf.sprintf "auth_config_path: %s" report.auth_config_path;
      Printf.sprintf "auth_change: %s"
        (auth_change_to_string report.auth_change);
      Printf.sprintf "agent_name: %s" report.agent_name;
      Printf.sprintf "role: %s" (agent_role_to_string report.role);
      Printf.sprintf "raw_token_file: %s" report.raw_token_file;
      Printf.sprintf "dashboard_url: %s" report.dashboard_url;
      Printf.sprintf "mcp_url: %s" report.mcp_url;
      "";
      "exports:";
      render_shell report;
      "";
      "mcp_client:";
      Printf.sprintf "- server_name: %s" "masc";
      Printf.sprintf "- agent_name: %s" report.agent_name;
      Printf.sprintf "- token_env_var: %s" report.mcp_token_env_var;
      "- auth_model: bearer_token_env";
    ]
