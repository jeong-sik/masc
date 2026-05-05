open Masc_domain

type auth_change =
  | Auth_already_required
  | Auth_enabled
  | Require_token_enabled

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
  codex_server_name : string;
  codex_token_env_var : string;
  codex_login_supported : bool;
}

let codex_server_name = "masc"

let codex_token_env_var = "MASC_MCP_TOKEN"

let mcp_token_env_var_for_agent = function
  | "claude" -> "MASC_CLAUDE_MCP_TOKEN"
  | "gemini" -> "MASC_GEMINI_MCP_TOKEN"
  | "codex" | "codex-mcp-client" -> codex_token_env_var
  | _ -> codex_token_env_var

let is_local_mcp_client_agent = function
  | "claude" | "gemini" | "codex" | "codex-mcp-client" -> true
  | _ -> false

let rng_initialized = Atomic.make false

let ensure_rng_initialized () =
  if not (Atomic.get rng_initialized) then begin
    Mirage_crypto_rng_unix.use_default ();
    Atomic.set rng_initialized true
  end

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
    let _room_secret, _bootstrap_token =
      Auth.enable_auth base_path ~require_token:true ~agent_name
    in
    Ok Auth_enabled
  else (
    Auth.save_auth_config base_path { cfg with require_token = true };
    Ok Require_token_enabled)

let mint ~base_path ~host ~port ~agent_name ~role () =
  ensure_rng_initialized ();
  let base_path = normalize_base_path base_path in
  match ensure_required_bearer_auth ~base_path ~agent_name with
  | Error err -> Error err
  | Ok auth_change -> (
      let create_token =
        if is_local_mcp_client_agent agent_name then
          Auth.create_token_without_expiry
        else
          Auth.create_token
      in
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
              mcp_token_env_var = mcp_token_env_var_for_agent cred.agent_name;
              codex_server_name;
              codex_token_env_var;
              codex_login_supported = false;
            })

let to_yojson report =
  `Assoc
    [
      ("status", `String "ok");
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
            ("server_name", `String report.codex_server_name);
            ("agent_name", `String report.agent_name);
            ("auth_model", `String "bearer_token_env");
            ("token_env_var", `String report.mcp_token_env_var);
          ] );
      ( "codex_mcp",
        `Assoc
          [
            ("server_name", `String report.codex_server_name);
            ("auth_model", `String "bearer_token_env");
            ("token_env_var", `String report.codex_token_env_var);
            ("login_supported", `Bool report.codex_login_supported);
            ( "login_note",
              `String
                "`codex mcp login` is OAuth-only; masc-mcp uses bearer token auth." );
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
      Printf.sprintf "- server_name: %s" report.codex_server_name;
      Printf.sprintf "- agent_name: %s" report.agent_name;
      Printf.sprintf "- token_env_var: %s" report.mcp_token_env_var;
      "- auth_model: bearer_token_env";
      "";
      "codex_mcp:";
      Printf.sprintf "- server_name: %s" report.codex_server_name;
      Printf.sprintf "- token_env_var: %s" report.codex_token_env_var;
      "- auth_model: bearer_token_env";
      "- login_supported: no";
      "- note: `codex mcp login` is OAuth-only; use the exported bearer token instead.";
    ]
