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
let internal_keeper_token_hash_file config =
  Filename.concat (auth_dir config) "internal_keeper.token.hash"
let internal_keeper_token_env_key = "MASC_INTERNAL_MCP_TOKEN"

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
      Fun.protect ~finally:(fun () -> close_out_noerr oc) (fun () ->
          output_string oc content));
  chmod path 0o600

let load_internal_keeper_token_hash config =
  let file = internal_keeper_token_hash_file config in
  if file_exists file then
    try
      let hash = String.trim (read_text_file file) in
      if hash = "" then None else Some hash
    with Sys_error _ -> None
  else
    None

let save_internal_keeper_token_hash config ~raw_token =
  ensure_auth_dirs config;
  let file = internal_keeper_token_hash_file config in
  save_private_text_file file (sha256_hash raw_token)

let verify_internal_keeper_token config ~token =
  match load_internal_keeper_token_hash config with
  | Some stored_hash -> String.equal stored_hash (sha256_hash token)
  | None -> false

let ensure_internal_keeper_token config =
  let existing_env =
    match Sys.getenv_opt internal_keeper_token_env_key with
    | Some raw ->
        let trimmed = String.trim raw in
        if trimmed = "" then None else Some trimmed
    | None -> None
  in
  match existing_env with
  | Some raw_token ->
      save_internal_keeper_token_hash config ~raw_token;
      raw_token
  | None ->
      let raw_token = generate_token () in
      save_internal_keeper_token_hash config ~raw_token;
      Unix.putenv internal_keeper_token_env_key raw_token;
      raw_token

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

let persist_auth_config config (auth_cfg : auth_config) =
  ensure_auth_dirs config;
  let file = auth_config_file config in
  let json = auth_config_to_yojson auth_cfg in
  save_private_text_file file (Yojson.Safe.pretty_to_string json)

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
  persist_auth_config config auth_cfg

(* ============================================ *)
(* Credential management                        *)
(* ============================================ *)

(** Get credential file path for an agent *)
let credential_file config agent_name =
  Filename.concat (agents_dir config) (agent_name ^ ".json")

let trim_nonempty value =
  let trimmed = String.trim value in
  if trimmed = "" then None else Some trimmed

(* Inline copy of Nickname.is_generated_nickname / extract_agent_type.
   Auth lives below masc_coord in the module graph and cannot depend on
   it. The nickname pattern — three or more hyphen-separated segments,
   first segment is the agent type — is small enough to duplicate here
   without drift risk. Keeper aliases use a different canonical shape
   (keeper-<name>-agent) and must resolve to the middle segment so
   keeper-scoped credentials can be stored under the stable keeper name
   rather than the transport alias. Covered by the nickname fallback
   tests. *)
let is_generated_nickname_shape name =
  List.length (String.split_on_char '-' name) >= 3

let extract_agent_type_prefix name =
  match String.split_on_char '-' name with
  | "keeper" :: rest -> (
      match List.rev rest with
      | "agent" :: middle_rev ->
          List.rev middle_rev
          |> String.concat "-"
          |> trim_nonempty
      | _ -> Some "keeper")
  | prefix :: _ when prefix <> "" -> Some prefix
  | _ -> None

let credential_agent_name agent_name =
  match extract_agent_type_prefix agent_name with
  | Some prefix when prefix <> agent_name -> prefix
  | _ -> agent_name

let raw_token_file config agent_name =
  Filename.concat (auth_dir config) (agent_name ^ ".token")

(* Dashboard loopback dev-token was historically issued under
   [dashboard-dev] while the UI defaults to [dashboard]. Keep the old
   credential valid for [dashboard] requests so already-open browser
   sessions survive restarts and token-file migration. *)
let legacy_credential_aliases = function
  | "dashboard" -> [ "dashboard-dev" ]
  | _ -> []
let load_credential_from_path config agent_name path : agent_credential option =
  if file_exists path then
    try
      let content = read_text_file path in
      let json = Yojson.Safe.from_string content in
      match agent_credential_of_yojson json with
      | Ok cred -> Some cred
      | Error msg ->
          Log.Auth.warn "[load_credential] parse error for %s: %s" agent_name msg;
          None
    with Sys_error _ | Yojson.Json_error _ -> None
  else
    None

(** Load agent credential.

    Tries an exact filename match first. If that misses and [agent_name]
    looks like a generated nickname ({agent_type}-{adj}-{animal}[...]),
    retry with just the agent_type prefix — shared-token aliases
    provisioned for stable keeper names (e.g. [adversary.json]) then
    cover every dynamically generated nickname in that family
    (e.g. [adversary-fair-tapir]).

    Without this fallback, Coord.join's nickname output caused a
    chronic "No credential found for <type>-<adj>-<animal>" noise band
    at ~0.3/min on the live fleet (2026-04-20). *)
let load_credential config agent_name : agent_credential option =
  let file = credential_file config agent_name in
  match load_credential_from_path config agent_name file with
  | Some _ as c -> c
  | None ->
    if is_generated_nickname_shape agent_name then
      match extract_agent_type_prefix agent_name with
      | Some prefix when prefix <> agent_name ->
        let fallback = credential_file config prefix in
        load_credential_from_path config prefix fallback
      | _ -> None
    else None

let load_credential_with_aliases config agent_name : agent_credential option =
  match load_credential config agent_name with
  | Some _ as c -> c
  | None ->
      legacy_credential_aliases agent_name
      |> List.find_map (load_credential config)

(** Save agent credential *)
let save_credential config (cred : agent_credential) =
  ensure_auth_dirs config;
  let file = credential_file config cred.agent_name in
  let json = agent_credential_to_yojson cred in
  save_private_text_file file (Yojson.Safe.pretty_to_string json)

let load_raw_token config ~agent_name =
  let file = raw_token_file config agent_name in
  if file_exists file then
    try
      read_text_file file |> trim_nonempty
    with Sys_error _ -> None
  else
    None

let persist_raw_token config ~agent_name raw_token =
  ensure_auth_dirs config;
  save_private_text_file (raw_token_file config agent_name) raw_token

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

let expires_at_for_auth_config auth_cfg =
  if auth_cfg.token_expiry_hours > 0 then
    let expiry = Time_compat.now () +. (float_of_int auth_cfg.token_expiry_hours *. 3600.0) in
    let tm = Unix.gmtime expiry in
    Some
      (Printf.sprintf "%04d-%02d-%02dT%02d:%02d:%02dZ"
         (tm.Unix.tm_year + 1900) (tm.Unix.tm_mon + 1) tm.Unix.tm_mday
         tm.Unix.tm_hour tm.Unix.tm_min tm.Unix.tm_sec)
  else
    None

let save_raw_token_credential config ~agent_name ~role ~raw_token :
    (agent_credential, masc_error) result =
  let auth_cfg = load_auth_config config in
  let cred =
    {
      agent_name;
      token = sha256_hash raw_token;
      role;
      created_at = now_iso ();
      expires_at = expires_at_for_auth_config auth_cfg;
    }
  in
  try
    save_credential config cred;
    Ok cred
  with Eio.Cancel.Cancelled _ as e -> raise e | exn ->
    let msg =
      Printf.sprintf "Failed to save agent credential: %s"
        (Printexc.to_string exn)
    in
    Log.Auth.error "%s" msg;
    Error (IoError msg)

(* ============================================ *)
(* Token operations                             *)
(* ============================================ *)

(** Create a new token for an agent *)
let create_token config ~agent_name ~role : (string * agent_credential, masc_error) result =
  let raw_token = generate_token () in
  match save_raw_token_credential config ~agent_name ~role ~raw_token with
  | Ok cred -> Ok (raw_token, cred)
  | Error e -> Error e

let missing_credential_error config ~agent_name ~token : masc_error =
  match find_credential_by_token config ~token with
  | Ok owner when owner.agent_name <> agent_name ->
      Unauthorized
        (Printf.sprintf
           "No credential found for %s (bearer token belongs to %s)"
           agent_name owner.agent_name)
  | _ -> Unauthorized ("No credential found for " ^ agent_name)

(** Verify a token *)
let verify_token config ~agent_name ~token : (agent_credential, masc_error) result =
  match load_credential_with_aliases config agent_name with
  | None -> Error (missing_credential_error config ~agent_name ~token)
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

let ensure_keeper_credential config ~agent_name :
    (string * agent_credential, masc_error) result =
  let raw_token = ensure_internal_keeper_token config in
  let target_agent_name = credential_agent_name agent_name in
  Ok
    ( raw_token,
      {
        agent_name = target_agent_name;
        token = sha256_hash raw_token;
        role = Worker;
        created_at = now_iso ();
        expires_at = None;
      } )

(** Refresh a token (generate new one, update credential) *)
let refresh_token config ~agent_name ~old_token : (string * agent_credential, masc_error) result =
  match verify_token config ~agent_name ~token:old_token with
  | Error (TokenExpired _) ->
      (* Allow refresh even if expired *)
      (match load_credential_with_aliases config agent_name with
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
  else if
    match token with
    | Some raw -> verify_internal_keeper_token config ~token:raw
    | None -> false
  then
    if has_permission Worker permission then
      Ok ()
    else
      Error (Forbidden { agent = agent_name; action = show_permission permission })
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
          (* Optional-token mode: anonymous callers are always treated as
             non-admin workers. *)
          if has_permission Worker permission then
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
  else if
    match token with
    | Some raw -> verify_internal_keeper_token config ~token:raw
    | None -> false
  then
    Ok Worker
  else
    match verify_optional_token config ~agent_name ~token with
    | Error e -> Error e
    | Ok (Some cred) -> Ok cred.role
    | Ok None ->
        if auth_cfg.require_token then
          Error (Unauthorized "Token required")
        else
          Ok Worker

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
