(** Auth tools - Authentication and authorization *)

open Tool_args

type context = {
  config: Room.config;
  agent_name: string;
}

type result = bool * string

let target_agent_name ctx args =
  match get_string args "agent_name" ctx.agent_name |> String.trim with
  | "" -> ctx.agent_name
  | name -> name

let handle_auth_enable ctx args =
  let require_token = get_bool args "require_token" false in
  let (secret, bootstrap_token) =
    Auth.enable_auth ctx.config.base_path ~require_token ~agent_name:ctx.agent_name
  in
  let token_msg = match bootstrap_token with
    | Some token ->
        Printf.sprintf "\nBootstrap Admin Token for `%s` (SAVE THIS):\n`%s`\n" ctx.agent_name token
    | None -> ""
  in
  let msg = Printf.sprintf {|🔐 **Authentication Enabled**

Room Secret (SAVE THIS - shown only once):
`%s`
%s
Share this secret securely with authorized agents.
Require token for actions: %b

Use `masc_auth_create_token` to create agent tokens.
|} secret token_msg require_token in
  (true, msg)

let handle_auth_disable ctx _args =
  Auth.disable_auth ctx.config.base_path;
  (true, "🔓 Authentication disabled. All agents can perform any action.")

let handle_auth_status ctx _args =
  let cfg = Auth.load_auth_config ctx.config.base_path in
  let status = if cfg.enabled then "✅ Enabled" else "❌ Disabled" in
  let require = if cfg.require_token then "Yes" else "No (optional)" in
  let default = Types.agent_role_to_string cfg.default_role in
  let bind_host = Server_auth.http_auth_bind_host () in
  let bind_scope =
    if Server_auth.http_auth_bind_is_loopback () then "loopback" else "non-loopback"
  in
  let http_strict =
    if Server_auth.http_auth_strict_enabled () then "Yes" else "No"
  in
  let msg = Printf.sprintf {|🔐 **Authentication Status**

Status: %s
Require Token: %s
Default Role: %s
Token Expiry: %d hours
HTTP Auth Strict: %s
Bind Host: %s (%s)
|} status require default cfg.token_expiry_hours http_strict bind_host
      bind_scope
  in
  (true, msg)

let create_token_failures = Hashtbl.create 16

let handle_auth_create_token ctx args =
  let target_agent = target_agent_name ctx args in
  let failures = match Hashtbl.find_opt create_token_failures target_agent with Some f -> f | None -> 0 in
  if failures >= 3 then
    (false, Printf.sprintf "Circuit breaker open: masc_auth_create_token failed %d times for %s. Check auth directories permissions or secret key configuration." failures target_agent)
  else
    let role_str = get_string args "role" "worker" in
    let role = match Types.agent_role_of_string role_str with
      | Ok r -> r
      | Error _ -> Types.Worker
    in
    Log.Auth.info "Creating token for agent '%s' with role '%s' (requested by '%s')"
      target_agent (Types.agent_role_to_string role) ctx.agent_name;
    try
      match Auth.create_token ctx.config.base_path ~agent_name:target_agent ~role with
      | Ok (raw_token, cred) ->
          Hashtbl.replace create_token_failures target_agent 0;
          let expires = match cred.expires_at with
            | Some exp -> exp
            | None -> "never"
          in
          Log.Auth.info "Token created successfully for agent '%s'" target_agent;
          let msg = Printf.sprintf {|🔑 **Token Created for %s**

Token (SAVE THIS - shown only once):
`%s`

Role: %s
Expires: %s

Pass this token in requests to authenticate.
|} target_agent raw_token (Types.agent_role_to_string role) expires in
          (true, msg)
      | Error e ->
          Hashtbl.replace create_token_failures target_agent (failures + 1);
          let err_msg = Types.masc_error_to_string e in
          Log.Auth.error "Token creation failed for agent '%s': %s" target_agent err_msg;
          (false, Printf.sprintf "Auth token creation failed: %s" err_msg)
    with Eio.Cancel.Cancelled _ as e -> raise e | exn ->
      Hashtbl.replace create_token_failures target_agent (failures + 1);
      let trace = Printexc.get_backtrace () in
      Log.Auth.error "Token creation crashed for agent '%s': %s" target_agent (Printexc.to_string exn);
      (false, Printf.sprintf "Auth credential save crashed: %s\n%s" (Printexc.to_string exn) trace)

let handle_auth_refresh ctx args =
  let target_agent = target_agent_name ctx args in
  if target_agent <> ctx.agent_name then
    (false, "agent_name must match the authenticated agent for refresh")
  else
    let token = get_string args "token" "" in
    match Auth.refresh_token ctx.config.base_path ~agent_name:target_agent ~old_token:token with
    | Ok (new_token, cred) ->
        let expires = match cred.expires_at with
          | Some exp -> exp
          | None -> "never"
        in
        let msg = Printf.sprintf {|🔄 **Token Refreshed for %s**

New Token:
`%s`

Expires: %s
|} target_agent new_token expires in
        (true, msg)
    | Error e ->
        (false, Types.masc_error_to_string e)

let handle_auth_revoke ctx args =
  let target_agent = target_agent_name ctx args in
  match Auth.load_credential ctx.config.base_path target_agent with
  | None ->
      (false, Printf.sprintf "No credential found for %s" target_agent)
  | Some _ ->
      Auth.delete_credential ctx.config.base_path target_agent;
      (true, Printf.sprintf "🗑️ Token revoked for %s" target_agent)

let handle_auth_list ctx _args =
  let creds = Auth.list_credentials ctx.config.base_path in
  if creds = [] then
    (true, "No agent credentials found.")
  else begin
    let buf = Buffer.create 512 in
    Buffer.add_string buf "👥 **Agent Credentials**\n";
    Buffer.add_string buf "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n";
    List.iter (fun (c : Types.agent_credential) ->
      let expires = match c.expires_at with Some exp -> exp | None -> "never" in
      Buffer.add_string buf (Printf.sprintf "  • %s (%s) - expires: %s\n"
        c.agent_name (Types.agent_role_to_string c.role) expires)
    ) creds;
    (true, Buffer.contents buf)
  end

let dispatch ctx ~name ~args : result option =
  match name with
  | "masc_auth_enable" -> Some (handle_auth_enable ctx args)
  | "masc_auth_disable" -> Some (handle_auth_disable ctx args)
  | "masc_auth_status" -> Some (handle_auth_status ctx args)
  | "masc_auth_create_token" -> Some (handle_auth_create_token ctx args)
  | "masc_auth_refresh" -> Some (handle_auth_refresh ctx args)
  | "masc_auth_revoke" -> Some (handle_auth_revoke ctx args)
  | "masc_auth_list" -> Some (handle_auth_list ctx args)
  | _ -> None

let schemas = Tool_schemas_auth.schemas

(* ================================================================ *)
(* Tool_spec registration                                           *)
(* ================================================================ *)

let () =
  List.iter
    (fun (s : Types.tool_schema) ->
      Tool_spec.register
        (Tool_spec.create
           ~name:s.name
           ~description:s.description
           ~module_tag:Tool_dispatch.Mod_auth
           ~input_schema:s.input_schema
           ()))
    schemas
