(** MASC Authentication & Authorization Module *)

open Types

(* ============================================ *)
(* Crypto utilities                             *)
(* ============================================ *)

(** Generate a cryptographically random token (hex string) *)
let generate_token () =
  let random_bytes = Mirage_crypto_rng.generate 32 in
  let hex = Buffer.create 64 in
  String.iter (fun c -> Buffer.add_string hex (Printf.sprintf "%02x" (Char.code c))) random_bytes;
  Buffer.contents hex

(** SHA256 hash of a string using Digestif *)
let sha256_hash input =
  Digestif.SHA256.(digest_string input |> to_hex)

(* ============================================ *)
(* Auth directory management                    *)
(* ============================================ *)

let auth_dir config = Filename.concat config ".masc/auth"
let agents_dir config = Filename.concat (auth_dir config) "agents"
let room_secret_file config = Filename.concat (auth_dir config) "room_secret.hash"
let auth_config_file config = Filename.concat (auth_dir config) "config.json"
let initial_admin_file config = Filename.concat (auth_dir config) "initial_admin"

let run_blocking_io f = Eio_guard.run_in_systhread f
let file_exists path = run_blocking_io (fun () -> Sys.file_exists path)
let read_text_file path = Fs_compat.load_file path
let write_text_file path content = Fs_compat.save_file path content

let chmod path perm = run_blocking_io (fun () -> Unix.chmod path perm)
let read_dir path = run_blocking_io (fun () -> Sys.readdir path)
let remove_file path = run_blocking_io (fun () -> Sys.remove path)

(** Ensure auth directories exist *)
let ensure_auth_dirs config =
  let auth = auth_dir config in
  let agents = agents_dir config in
  Fs_compat.mkdir_p auth;
  Fs_compat.mkdir_p agents

(** Write the initial admin agent name (bootstrap grace).
    The agent who enables auth is always granted full permission. *)
let write_initial_admin config agent_name =
  ensure_auth_dirs config;
  let file = initial_admin_file config in
  write_text_file file (String.trim agent_name);
  chmod file 0o600

let save_private_text_file path content =
  run_blocking_io (fun () ->
      let oc =
        open_out_gen [ Open_wronly; Open_creat; Open_trunc; Open_text ] 0o600
          path
      in
      Fun.protect ~finally:(fun () -> close_out oc) (fun () ->
          output_string oc content));
  chmod path 0o600

(** Read the initial admin agent name, if set. *)
let read_initial_admin config : string option =
  let file = initial_admin_file config in
  if file_exists file then
    try
      let name = String.trim (read_text_file file) in
      if name = "" then None else Some name
    with Sys_error _ -> None
  else
    None

(* ============================================ *)
(* Auth config management                       *)
(* ============================================ *)

(** Load auth config *)
let load_auth_config config : auth_config =
  let file = auth_config_file config in
  if file_exists file then
    try
      let content = read_text_file file in
      let json = Yojson.Safe.from_string content in
      match auth_config_of_yojson json with
      | Ok cfg -> cfg
      | Error msg ->
        Log.Auth.warn "[load_auth_config] parse error for %s: %s" file msg;
        default_auth_config
    with Sys_error _ | Yojson.Json_error _ -> default_auth_config
  else
    default_auth_config

(** Save auth config *)
let save_auth_config config (auth_cfg : auth_config) =
  ensure_auth_dirs config;
  let file = auth_config_file config in
  let json = auth_config_to_yojson auth_cfg in
  save_private_text_file file (Yojson.Safe.pretty_to_string json)

(* ============================================ *)
(* Credential management                        *)
(* ============================================ *)

(** Get credential file path for an agent *)
let credential_file config agent_name =
  Filename.concat (agents_dir config) (agent_name ^ ".json")

(** Load agent credential *)
let load_credential config agent_name : agent_credential option =
  let file = credential_file config agent_name in
  if file_exists file then
    try
      let content = read_text_file file in
      let json = Yojson.Safe.from_string content in
      match agent_credential_of_yojson json with
      | Ok cred -> Some cred
      | Error msg ->
        Log.Auth.warn "[load_credential] parse error for %s: %s" agent_name msg;
        None
    with Sys_error _ | Yojson.Json_error _ -> None
  else
    None

(** Save agent credential *)
let save_credential config (cred : agent_credential) =
  ensure_auth_dirs config;
  let file = credential_file config cred.agent_name in
  let json = agent_credential_to_yojson cred in
  save_private_text_file file (Yojson.Safe.pretty_to_string json)

(** Delete agent credential *)
let delete_credential config agent_name =
  let file = credential_file config agent_name in
  if file_exists file then remove_file file

(** List all credentials *)
let list_credentials config : agent_credential list =
  let dir = agents_dir config in
  if file_exists dir then
    read_dir dir
    |> Array.to_list
    |> List.filter (fun f -> Filename.check_suffix f ".json")
    |> List.filter_map (fun f ->
        let name = Filename.chop_suffix f ".json" in
        load_credential config name
      )
  else
    []

(** Find credential by raw token (hash lookup + expiry check) *)
let find_credential_by_token config ~token : (agent_credential, masc_error) result =
  let token_hash = sha256_hash token in
  match List.find_opt (fun cred -> cred.token = token_hash) (list_credentials config) with
  | None -> Error (InvalidToken "Token mismatch")
  | Some cred ->
      (match cred.expires_at with
       | None -> Ok cred
       | Some exp_str ->
           let now = now_iso () in
           if now > exp_str then Error (TokenExpired cred.agent_name) else Ok cred)

(** Resolve agent_name from raw token *)
let resolve_agent_from_token config ~token : (string, masc_error) result =
  match find_credential_by_token config ~token with
  | Ok cred -> Ok cred.agent_name
  | Error e -> Error e

(* ============================================ *)
(* Token operations                             *)
(* ============================================ *)

(** Create a new token for an agent *)
let create_token config ~agent_name ~role : (string * agent_credential, masc_error) result =
  let auth_cfg = load_auth_config config in
  let raw_token = generate_token () in
  let token_hash = sha256_hash raw_token in
  let now = now_iso () in
  let expires_at =
    if auth_cfg.token_expiry_hours > 0 then
      let expiry = Time_compat.now () +. (float_of_int auth_cfg.token_expiry_hours *. 3600.0) in
      let tm = Unix.gmtime expiry in
      Some (Printf.sprintf "%04d-%02d-%02dT%02d:%02d:%02dZ"
        (tm.Unix.tm_year + 1900) (tm.Unix.tm_mon + 1) tm.Unix.tm_mday
        tm.Unix.tm_hour tm.Unix.tm_min tm.Unix.tm_sec)
    else
      None
  in
  let cred = {
    agent_name;
    token = token_hash;
    role;
    created_at = now;
    expires_at;
  } in
  (try
     save_credential config cred;
     Ok (raw_token, cred)  (* Return raw token to user, store hash *)
   with Eio.Cancel.Cancelled _ as e -> raise e | exn ->
     let msg = Printf.sprintf "Failed to save agent credential: %s" (Printexc.to_string exn) in
     Log.Auth.error "%s" msg;
     Error (IoError msg))

(** Verify a token *)
let verify_token config ~agent_name ~token : (agent_credential, masc_error) result =
  match load_credential config agent_name with
  | None -> Error (Unauthorized ("No credential found for " ^ agent_name))
  | Some cred ->
      let token_hash = sha256_hash token in
      if cred.token <> token_hash then
        Error (InvalidToken "Token mismatch")
      else
        (* Check expiry *)
        match cred.expires_at with
        | None -> Ok cred
        | Some exp_str ->
            (* Simple ISO string comparison works for UTC *)
            let now = now_iso () in
            if now > exp_str then
              Error (TokenExpired agent_name)
            else
              Ok cred

(** Refresh a token (generate new one, update credential) *)
let refresh_token config ~agent_name ~old_token : (string * agent_credential, masc_error) result =
  match verify_token config ~agent_name ~token:old_token with
  | Error (TokenExpired _) ->
      (* Allow refresh even if expired *)
      (match load_credential config agent_name with
       | None -> Error (Unauthorized ("No credential found for " ^ agent_name))
       | Some old_cred -> create_token config ~agent_name ~role:old_cred.role)
  | Error e -> Error e
  | Ok old_cred -> create_token config ~agent_name ~role:old_cred.role

(* ============================================ *)
(* Authorization                                *)
(* ============================================ *)

(** Check if agent has permission for an action *)
let verify_optional_token config ~agent_name ~token :
    (agent_credential option, masc_error) result =
  match token with
  | None -> Ok None
  | Some raw ->
      match verify_token config ~agent_name ~token:raw with
      | Ok cred -> Ok (Some cred)
      | Error e -> Error e

let check_permission config ~agent_name ~token ~permission : (unit, masc_error) result =
  let auth_cfg = load_auth_config config in
  if not auth_cfg.enabled then
    (* Auth disabled - allow everything *)
    Ok ()
  else if (match read_initial_admin config with
           | Some admin -> String.equal agent_name admin
           | None -> false) then
    (* Bootstrap grace: the agent who enabled auth always has full access *)
    (ignore permission; Ok ())
  else
    match verify_optional_token config ~agent_name ~token with
    | Error e -> Error e
    | Ok (Some cred) ->
        if has_permission cred.role permission then
          Ok ()
        else
          Error (Forbidden { agent = agent_name; action = show_permission permission })
    | Ok None ->
        if not auth_cfg.require_token then
          (* Optional-token mode: fall back to the room's default role only
             when no token was presented. *)
          if has_permission auth_cfg.default_role permission then
            Ok ()
          else
            Error (Forbidden { agent = agent_name; action = show_permission permission })
        else
          Error (Unauthorized "Token required")

let permission_for_tool tool_name =
  Tool_permission_map.permission_for_tool tool_name

(** Strict tool auth mode:
    - 0/false: legacy fail-open for unknown tools
    - 1/true: unknown masc_* tools require at least worker-level permission *)
let is_tool_auth_strict_enabled () =
  Env_config_core.tool_auth_strict ()

let is_masc_tool_name tool_name =
  String.starts_with ~prefix:"masc_" tool_name

let is_protocol_canonical_tool_name tool_name =
  String.starts_with ~prefix:"decision." tool_name
  || String.starts_with ~prefix:"experiment." tool_name
  || String.starts_with ~prefix:"client." tool_name

(** Check permission for a tool call *)
let authorize_tool config ~agent_name ~token ~tool_name : (unit, masc_error) result =
  match permission_for_tool tool_name with
  | None ->
      if not (is_tool_auth_strict_enabled ()) then
        Ok ()  (* Legacy fail-open *)
      else if is_masc_tool_name tool_name || is_protocol_canonical_tool_name tool_name then
        (* Conservative default in strict mode for unmapped internal tools. *)
        check_permission config ~agent_name ~token ~permission:CanBroadcast
      else
        Error (Forbidden { agent = agent_name; action = "use unknown non-masc tool" })
  | Some perm -> check_permission config ~agent_name ~token ~permission:perm

(* ============================================ *)
(* Unified policy-based authorization (v2)      *)
(* ============================================ *)

(** Resolve the effective role for an agent from auth context.
    Returns Error for invalid tokens (no silent downgrade). *)
let resolve_role_with_auth_config config ~auth_cfg ~agent_name ~token :
    (agent_role, masc_error) result =
  if not auth_cfg.enabled then
    Ok Admin  (* Auth disabled = full access *)
  else if (match read_initial_admin config with
           | Some admin -> String.equal agent_name admin
           | None -> false) then
    Ok Admin  (* Bootstrap admin = full access *)
  else
    match verify_optional_token config ~agent_name ~token with
    | Error e -> Error e
    | Ok (Some cred) -> Ok cred.role
    | Ok None ->
        if auth_cfg.require_token then
          Error (Unauthorized "Token required")
        else
          Ok auth_cfg.default_role

let resolve_role config ~agent_name ~token : (agent_role, masc_error) result =
  let auth_cfg = load_auth_config config in
  resolve_role_with_auth_config config ~auth_cfg ~agent_name ~token

let authorize_tool_for_role ~agent_name ~role ~tool_name :
    (unit, masc_error) result =
  let policy = Tool_access_role.policy_for_role role in
  if not (Tool_access_policy.allows_name policy tool_name) then
    Error (Forbidden { agent = agent_name; action = tool_name })
  else if not (is_tool_auth_strict_enabled ()) then
    Ok ()  (* Non-strict: policy check is sufficient *)
  else
    (* Strict mode: additional gate for unmapped tools *)
    match permission_for_tool tool_name with
    | Some _ -> Ok ()  (* Mapped tool — policy already checked *)
    | None ->
        if is_masc_tool_name tool_name
           || is_protocol_canonical_tool_name tool_name then
          (* Unmapped internal tool: require at least Worker *)
          if has_permission role CanBroadcast then Ok ()
          else Error (Forbidden { agent = agent_name; action = tool_name })
        else
          Error
            (Forbidden
               {
                 agent = agent_name;
                 action = "use unknown non-masc tool: " ^ tool_name;
               })

(** Policy-based tool authorization.
    Replaces authorize_tool with a single Tool_access_policy check.
    Invalid/expired tokens are rejected (not silently downgraded).

    Strict mode (MASC_TOOL_AUTH_STRICT, default=true):
    Tools not mapped by permission_for_tool are subject to additional
    checks — unmapped masc_* tools require at least Worker, and
    unmapped non-masc tools are forbidden. *)
let authorize_tool_v2 config ~agent_name ~token ~tool_name : (unit, masc_error) result =
  match resolve_role config ~agent_name ~token with
  | Error e -> Error e
  | Ok role -> authorize_tool_for_role ~agent_name ~role ~tool_name

(* ============================================ *)
(* Coord secret (for room-level auth)            *)
(* ============================================ *)

(** Initialize room secret *)
let init_room_secret config : string =
  ensure_auth_dirs config;
  let secret = generate_token () in
  let hash = sha256_hash secret in
  save_private_text_file (room_secret_file config) hash;
  (* Update auth config with hash *)
  let cfg = load_auth_config config in
  save_auth_config config { cfg with room_secret_hash = Some hash };
  secret  (* Return raw secret to show user once *)

(** Verify room secret *)
let verify_room_secret config secret : bool =
  let hash = sha256_hash secret in
  let file = room_secret_file config in
  if Sys.file_exists file then
    let stored_hash = String.trim (In_channel.with_open_text file In_channel.input_all) in
    hash = stored_hash
  else
    false

(* ============================================ *)
(* High-level auth operations                   *)
(* ============================================ *)

(** Enable authentication for a room.
    Creates a bootstrap admin token for the enabling agent to prevent
    circular permission deadlock (BUG-025). *)
let enable_auth config ~require_token ~agent_name : string * string option =
  let secret = init_room_secret config in
  let cfg = load_auth_config config in
  save_auth_config config { cfg with enabled = true; require_token };
  let bootstrap_token =
    if agent_name <> "" then begin
      write_initial_admin config agent_name;
      match create_token config ~agent_name ~role:Admin with
      | Ok (token, _cred) -> Some token
      | Error e ->
        Log.Auth.warn "[enable_auth] bootstrap token creation failed for %s: %s" agent_name (Types.show_masc_error e);
        None
    end else None
  in
  (secret, bootstrap_token)

type local_admin_bootstrap = {
  base_path : string;
  auth_root : string;
  auth_config_path : string;
  agents_root : string;
  credential_path : string;
  agent_name : string;
  require_token : bool;
  reused_auth : bool;
  room_secret : string option;
  bearer_token : string;
  dashboard_url : string;
}

let dashboard_login_url ~host ~port ~agent_name ~token =
  Printf.sprintf "http://%s:%d/dashboard?agent=%s&token=%s"
    host port agent_name token

let local_admin_bootstrap_to_yojson (bootstrap : local_admin_bootstrap) =
  `Assoc [
    ("base_path", `String bootstrap.base_path);
    ("auth_root", `String bootstrap.auth_root);
    ("auth_config_path", `String bootstrap.auth_config_path);
    ("agents_root", `String bootstrap.agents_root);
    ("credential_path", `String bootstrap.credential_path);
    ("agent_name", `String bootstrap.agent_name);
    ("require_token", `Bool bootstrap.require_token);
    ("reused_auth", `Bool bootstrap.reused_auth);
    ( "room_secret",
      match bootstrap.room_secret with
      | Some value -> `String value
      | None -> `Null );
    ("bearer_token", `String bootstrap.bearer_token);
    ("dashboard_url", `String bootstrap.dashboard_url);
  ]

let bootstrap_local_admin ?(host = "127.0.0.1") ?(port = 8935) config
    ~agent_name : (local_admin_bootstrap, masc_error) result =
  let base_path = Env_config.normalize_masc_base_path_input config in
  let existing_cfg = load_auth_config base_path in
  let room_secret, reused_auth, bearer_token_result =
    if existing_cfg.enabled then begin
      if not existing_cfg.require_token then
        save_auth_config base_path { existing_cfg with enabled = true; require_token = true };
      (None, true, create_token base_path ~agent_name ~role:Admin)
    end else begin
      let secret, bootstrap_token =
        enable_auth base_path ~require_token:true ~agent_name
      in
      let token_result =
        match bootstrap_token with
        | Some token ->
            (match verify_token base_path ~agent_name ~token with
             | Ok _ -> (
                 match load_credential base_path agent_name with
                 | Some cred -> Ok (token, cred)
                 | None -> create_token base_path ~agent_name ~role:Admin)
             | Error _ -> create_token base_path ~agent_name ~role:Admin)
        | None -> create_token base_path ~agent_name ~role:Admin
      in
      (Some secret, false, token_result)
    end
  in
  match bearer_token_result with
  | Error _ as err -> err
  | Ok (bearer_token, _cred) ->
      Ok
        {
          base_path;
          auth_root = auth_dir base_path;
          auth_config_path = auth_config_file base_path;
          agents_root = agents_dir base_path;
          credential_path = credential_file base_path agent_name;
          agent_name;
          require_token = true;
          reused_auth;
          room_secret;
          bearer_token;
          dashboard_url =
            dashboard_login_url ~host ~port ~agent_name ~token:bearer_token;
        }

(** Disable authentication *)
let disable_auth config =
  let cfg = load_auth_config config in
  save_auth_config config { cfg with enabled = false };
  let file = initial_admin_file config in
  if Sys.file_exists file then Sys.remove file

(** Check if auth is enabled *)
let is_auth_enabled config : bool =
  let cfg = load_auth_config config in
  cfg.enabled
