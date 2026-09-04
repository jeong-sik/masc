open Masc_domain

type auth_change =
  | Auth_already_required
  | Auth_enabled
  | Require_token_enabled

type token_lifetime =
  | With_expiry
  | Long_lived
  | Expires_in_hours of int

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

let auth_change_to_string = function
  | Auth_already_required -> "already_required"
  | Auth_enabled -> "auth_enabled"
  | Require_token_enabled -> "require_token_enabled"

let normalize_base_path path =
  Env_config_core.normalize_masc_base_path_input path

let single_quote_shell value =
  "'" ^ String.concat "'\\''" (String.split_on_char '\'' value) ^ "'"

let token_file_path ~base_path ~agent_name =
  Filename.concat (Auth.auth_dir base_path) (agent_name ^ ".token")

let persist_raw_token ~base_path ~agent_name raw_token =
  let path = token_file_path ~base_path ~agent_name in
  Fs_compat.mkdir_p (Filename.dirname path);
  Auth.save_private_text_file path raw_token;
  path

(* The read side of [persist_raw_token]. A client that logged in already has
   its bearer in the workspace it opens; without this it can only be handed the
   value again through the environment, which is the one channel that does not
   survive opening a new shell. Both sides derive the path from
   [token_file_path], so a rename cannot leave a reader looking in the old
   place. *)
let read_persisted_token ~base_path ~agent_name =
  let path = token_file_path ~base_path ~agent_name in
  match In_channel.with_open_bin path In_channel.input_all with
  | contents ->
      (match String.trim contents with
       | "" -> None
       | token -> Some token)
  | exception Sys_error _ -> None

let ensure_required_bearer_auth ~base_path ~agent_name ~role =
  let cfg = Auth.load_auth_config base_path in
  if cfg.enabled && cfg.require_token then
    Ok Auth_already_required
  else if not cfg.enabled then
    let _workspace_secret, _bootstrap_token =
      let bootstrap_agent_name =
        match role with
        | Admin -> agent_name
        | Worker -> ""
      in
      Auth.enable_auth base_path ~require_token:true
        ~agent_name:bootstrap_agent_name
    in
    Ok Auth_enabled
  else (
    Auth.save_auth_config base_path { cfg with require_token = true };
    Ok Require_token_enabled)

(* Two flags can name a lifetime, and they name different ones. Both at once is
   refused rather than resolved by precedence: whichever one lost would hand the
   operator a credential they did not ask for, and a bearer's lifetime is not a
   thing to guess at. *)
let lifetime_of_flags ~no_expiry ~expiry_hours =
  match (no_expiry, expiry_hours) with
  | true, Some _ ->
      Error "--no-expiry and --expiry-hours name different lifetimes; pass one"
  | true, None -> Ok Long_lived
  | false, Some hours -> Ok (Expires_in_hours hours)
  | false, None -> Ok With_expiry

let create_token_for_lifetime = function
  | With_expiry -> Auth.create_token
  | Long_lived -> Auth.create_token_without_expiry
  | Expires_in_hours hours ->
      fun config ~agent_name ~role ->
        Auth.create_token_expiring_in config ~agent_name ~role ~hours

let mint ~base_path ~host ~port ~agent_name ~role ~token_env_var
    ~token_lifetime () =
  let base_path = normalize_base_path base_path in
  match ensure_required_bearer_auth ~base_path ~agent_name ~role with
  | Error err -> Error err
  | Ok auth_change -> (
      let create_token = create_token_for_lifetime token_lifetime in
      match create_token base_path ~agent_name ~role with
      | Error err -> Error err
      | Ok (bearer_token, cred) ->
          let raw_token_file =
            persist_raw_token ~base_path ~agent_name bearer_token
          in
          (* [host] arrives from the --host flag, which is documented as the
             address to *bind* and offers 0.0.0.0 for it. These two URLs are
             what the operator opens and pastes, so they need an address that
             can be dialed (#30506). Only the URLs use it; the credential is
             decided by base_path, agent_name, and role. *)
          let advertised_host =
            Masc_network_defaults.normalize_advertised_host host
          in
          let dashboard_url =
            Uri.make ~scheme:"http" ~host:advertised_host ~port ~path:"/dashboard"
              ~query:[ ("agent", [ agent_name ]); ("token", [ bearer_token ]) ]
              ()
            |> Uri.to_string
          in
          let mcp_url =
            Uri.make ~scheme:"http" ~host:advertised_host ~port ~path:"/mcp" ()
            |> Uri.to_string
          in
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

type mcp_client =
  | Codex
  | Claude_desktop
  | Env

let mcp_client_of_string = function
  | "codex" -> Some Codex
  | "claude-desktop" -> Some Claude_desktop
  | "env" -> Some Env
  | _ -> None

(* A ready block a new user pastes into one MCP client, so connecting is one
   step instead of assembling the URL, bearer, and header by hand. [Env] is the
   portable shell-export form (any client that reads the token from the
   environment); [Codex] is the bearer-env TOML; [Claude_desktop] bridges over
   mcp-remote. These are the shapes docs/MCP-TEMPLATE.md and the README already
   document, kept here beside the other renderers so one test covers them. *)
let render_mcp_client_config report = function
  | Env -> render_shell report
  | Codex ->
      Printf.sprintf
        {|# Add to your Codex / bearer-env MCP client config (TOML):
[mcp_servers.masc]
url = "%s"
bearer_token_env_var = "%s"
http_headers = { "Accept" = "application/json, text/event-stream" }

# Then export the token in the shell that launches the client:
export %s=%s|}
        report.mcp_url report.mcp_token_env_var report.mcp_token_env_var
        report.bearer_token
  | Claude_desktop ->
      Printf.sprintf
        {|# Add to claude_desktop_config.json (bridges over mcp-remote):
{
  "mcpServers": {
    "masc": {
      "command": "npx",
      "args": ["-y", "mcp-remote", "%s"],
      "env": { "%s": "%s" }
    }
  }
}|}
        report.mcp_url report.mcp_token_env_var report.bearer_token

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
