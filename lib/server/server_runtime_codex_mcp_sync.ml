(** Codex MCP config and raw client token bootstrap sync helpers. *)

let sync_codex_mcp_config_env_key = "MASC_SYNC_CODEX_MCP_CONFIG"
let codex_config_path_env_key = "MASC_CODEX_CONFIG_PATH"

type codex_mcp_config_sync_status =
  | Codex_mcp_config_updated
  | Codex_mcp_config_unchanged
  | Codex_mcp_config_server_missing
  | Codex_mcp_config_header_missing

let split_lines_with_trailing_newline content =
  let has_trailing_newline =
    String.ends_with ~suffix:"\n" content
  in
  let lines = String.split_on_char '\n' content in
  let lines =
    if has_trailing_newline then
      match List.rev lines with
      | "" :: rest -> List.rev rest
      | _ -> lines
    else
      lines
  in
  (lines, has_trailing_newline)

let leading_indent line =
  let rec loop idx =
    if idx >= String.length line then String.length line
    else
      match line.[idx] with
      | ' ' | '\t' -> loop (idx + 1)
      | _ -> idx
  in
  String.sub line 0 (loop 0)

let is_toml_section_header trimmed =
  String.length trimmed >= 2 && trimmed.[0] = '['

let is_http_headers_binding trimmed =
  let key = "http_headers" in
  let key_len = String.length key in
  if String.length trimmed < key_len then
    false
  else if not (String.equal (String.sub trimmed 0 key_len) key) then
    false
  else
    match String.get trimmed key_len with
    | exception Invalid_argument _ -> true
    | ' ' | '\t' | '=' -> true
    | _ -> false

let is_bearer_token_env_var_binding trimmed =
  let key = "bearer_token_env_var" in
  let key_len = String.length key in
  if String.length trimmed < key_len then
    false
  else if not (String.equal (String.sub trimmed 0 key_len) key) then
    false
  else
    match String.get trimmed key_len with
    | exception Invalid_argument _ -> true
    | ' ' | '\t' | '=' -> true
    | _ -> false

let is_authorization_header_binding trimmed =
  let key = "authorization" in
  let key_len = String.length key in
  if String.length trimmed < key_len then
    false
  else if
    not
      (String.equal
         (String.lowercase_ascii (String.sub trimmed 0 key_len))
         key)
  then
    false
  else
    match String.get trimmed key_len with
    | exception Invalid_argument _ -> true
    | ' ' | '\t' | '=' -> true
    | _ -> false

let codex_mcp_headers_line indent =
  Printf.sprintf
    "%shttp_headers = { \"Accept\" = \"application/json, text/event-stream\", \"X-MASC-Agent\" = \"codex-mcp-client\" }"
    indent

let codex_mcp_bearer_env_line indent =
  Printf.sprintf "%sbearer_token_env_var = \"MASC_MCP_TOKEN\"" indent

let sync_codex_mcp_auth_header_content content =
  let lines, has_trailing_newline =
    split_lines_with_trailing_newline content
  in
  let add_missing_section_bindings ~seen_header ~seen_bearer_env ~changed acc =
    let acc, seen_header, changed =
      if seen_header then
        (acc, seen_header, changed)
      else
        (codex_mcp_headers_line "" :: acc, true, true)
    in
    let acc, seen_bearer_env, changed =
      if seen_bearer_env then
        (acc, seen_bearer_env, changed)
      else
        (codex_mcp_bearer_env_line "" :: acc, true, true)
    in
    (acc, seen_header, seen_bearer_env, changed)
  in
  let rec loop ~in_masc_section ~seen_masc_section ~seen_header
      ~seen_bearer_env ~changed acc =
    function
    | [] ->
        let acc, seen_header, _seen_bearer_env, changed =
          if in_masc_section then
            add_missing_section_bindings ~seen_header ~seen_bearer_env ~changed
              acc
          else
            (acc, seen_header, seen_bearer_env, changed)
        in
        let status =
          if not seen_masc_section then
            Codex_mcp_config_server_missing
          else if not seen_header then
            Codex_mcp_config_header_missing
          else if changed then
            Codex_mcp_config_updated
          else
            Codex_mcp_config_unchanged
        in
        let rendered = String.concat "\n" (List.rev acc) in
        let rendered =
          if has_trailing_newline then rendered ^ "\n" else rendered
        in
        (rendered, status)
    | line :: rest ->
        let trimmed = String.trim line in
        let entering_masc_section =
          String.equal trimmed "[mcp_servers.masc]"
        in
        let leaving_masc_section =
          in_masc_section
          && is_toml_section_header trimmed
          && not entering_masc_section
        in
        let acc, seen_header, seen_bearer_env, changed =
          if leaving_masc_section then
            add_missing_section_bindings ~seen_header ~seen_bearer_env ~changed
              acc
          else
            (acc, seen_header, seen_bearer_env, changed)
        in
        let in_masc_section =
          if entering_masc_section then true
          else if leaving_masc_section then false
          else in_masc_section
        in
        let seen_masc_section = seen_masc_section || entering_masc_section in
        let seen_header, seen_bearer_env =
          if entering_masc_section then (false, false)
          else (seen_header, seen_bearer_env)
        in
        let line, seen_header, seen_bearer_env, changed =
          if in_masc_section && is_http_headers_binding trimmed then
            let next = codex_mcp_headers_line (leading_indent line) in
            ( next,
              true,
              seen_bearer_env,
              changed || not (String.equal next line) )
          else if in_masc_section && is_bearer_token_env_var_binding trimmed then
            let next = codex_mcp_bearer_env_line (leading_indent line) in
            ( next,
              seen_header,
              true,
              changed || not (String.equal next line) )
          else
            (line, seen_header, seen_bearer_env, changed)
        in
        (* Drop bare Authorization bindings from [mcp_servers.masc]: a literal
           Authorization header conflicts with bearer_token_env_var and would
           persist raw token values in the config file. *)
        if in_masc_section && is_authorization_header_binding trimmed then
          loop ~in_masc_section ~seen_masc_section ~seen_header
            ~seen_bearer_env ~changed:true acc rest
        else
          loop ~in_masc_section ~seen_masc_section ~seen_header
            ~seen_bearer_env ~changed (line :: acc) rest
  in
  loop ~in_masc_section:false ~seen_masc_section:false ~seen_header:false
    ~seen_bearer_env:false ~changed:false [] lines

let codex_config_path_opt () =
  match Sys.getenv_opt codex_config_path_env_key |> Env_config_core.trim_opt with
  | Some path -> Some path
  | None ->
      Option.map
        (fun home -> Filename.concat home ".codex/config.toml")
        ((Host_config.from_env ()).home)

let sync_codex_mcp_config ~agent_name =
  if
    not
      (Env_config_core.get_bool ~default:false sync_codex_mcp_config_env_key)
  then
    ()
  else
    match codex_config_path_opt () with
    | None ->
        Log.Server.info
          "startup skipped Codex MCP config sync: HOME is not set"
    | Some config_path ->
        if not (Sys.file_exists config_path) then
          Log.Server.info
            "startup skipped Codex MCP config sync: %s does not exist"
            config_path
        else
          try
            let content = Fs_compat.load_file config_path in
            let updated, status = sync_codex_mcp_auth_header_content content in
            (match status with
             | Codex_mcp_config_updated ->
                 Auth.save_private_text_file config_path updated;
                 Log.Server.warn
                   "startup synced Codex MCP bearer-token env config for %s in %s"
                   agent_name config_path
             | Codex_mcp_config_unchanged ->
                 Log.Server.info
                   "startup Codex MCP bearer-token env config already current for %s"
                   agent_name
             | Codex_mcp_config_server_missing ->
                 Log.Server.info
                   "startup skipped Codex MCP config sync: [mcp_servers.masc] missing in %s"
                   config_path
             | Codex_mcp_config_header_missing ->
                 Log.Server.info
                   "startup skipped Codex MCP config sync: masc http_headers missing in %s"
                   config_path)
          with
          | Eio.Cancel.Cancelled _ as e -> raise e
          | exn ->
              Log.Server.error
                "startup failed Codex MCP config sync for %s: %s"
                agent_name (Printexc.to_string exn)

let sync_client_token_file ~base_path ~agent_name ~role =
  let token_file =
    Filename.concat (Auth.auth_dir base_path) (agent_name ^ ".token")
  in
  let existing_credential = Auth.load_credential base_path agent_name in
  let existing_role =
    match existing_credential with Some cred -> cred.role | None -> role
  in
  let persist_raw_token raw_token =
    Fs_compat.mkdir_p (Auth.auth_dir base_path);
    Auth.save_private_text_file token_file raw_token
  in
  let create_and_persist ~reason =
    match
      Auth.create_token_without_expiry base_path ~agent_name
        ~role:existing_role
    with
    | Ok (raw_token, _cred) ->
        (try
           persist_raw_token raw_token;
           Log.Server.warn
             "startup %s raw bearer token file for %s at %s"
             reason agent_name token_file
         with
         | Eio.Cancel.Cancelled _ as e -> raise e
         | exn ->
           Log.Server.error
             "startup failed to persist raw bearer token file for %s at %s: %s"
             agent_name token_file (Printexc.to_string exn))
    | Error err ->
        Log.Server.error
          "startup failed to mint raw bearer token for %s: %s"
          agent_name (Masc_domain.masc_error_to_string err)
  in
  let normalize_existing raw_token (cred : Masc_domain.agent_credential) =
    try
      (match cred.expires_at with
       | None -> ()
       | Some _ ->
           Auth.save_credential base_path { cred with expires_at = None };
           Log.Server.warn
             "startup removed expiry from MCP client bearer credential for %s"
             agent_name);
      persist_raw_token raw_token;
      Log.Server.info
        "startup verified raw bearer token file for %s at %s"
        agent_name token_file
    with
    | Eio.Cancel.Cancelled _ as e -> raise e
    | exn ->
      Log.Server.error
        "startup failed to normalize raw bearer token file for %s at %s: %s"
        agent_name token_file (Printexc.to_string exn)
  in
  let current_raw =
    if Fs_compat.file_exists token_file then
      try
        let raw = String.trim (Fs_compat.load_file token_file) in
        if raw = "" then None else Some raw
      with
      | Eio.Cancel.Cancelled _ as e -> raise e
      | exn ->
        Log.Server.warn
          "startup failed to read raw bearer token file for %s at %s: %s"
          agent_name token_file (Printexc.to_string exn);
        None
    else
      None
  in
  (match current_raw with
   | Some raw_token -> (
       match Auth.verify_token base_path ~agent_name ~token:raw_token with
       | Ok cred -> normalize_existing raw_token cred
       | Error _ -> (
           match Auth.load_credential base_path agent_name with
           | Some (cred : Masc_domain.agent_credential)
             when String.equal cred.token (Auth.sha256_hash raw_token) ->
               normalize_existing raw_token cred
           | _ -> create_and_persist ~reason:"repaired"))
   | None -> create_and_persist ~reason:"created");
  if String.equal agent_name "codex-mcp-client" then
    sync_codex_mcp_config ~agent_name

let sync_mcp_client_token_files ~base_path =
  [
    ("codex-mcp-client", Masc_domain.Worker);
    ("claude", Masc_domain.Worker);
    ("gemini", Masc_domain.Worker);
  ]
  |> List.iter (fun (agent_name, role) ->
         sync_client_token_file ~base_path ~agent_name ~role)
