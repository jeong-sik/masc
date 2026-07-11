(** MASC Authentication & Authorization Module *)

open Masc_domain

(* Crypto utilities, file I/O, config, credential CRUD, token
   verification — formerly re-exported via Auth_credential shim. *)

include Auth_credential_base
include Auth_credential_token

let ensure_keeper_credential config ~agent_name
  : (string * agent_credential, masc_error) result
  =
  ignore (ensure_internal_keeper_token config);
  let existing = load_credential config agent_name in
  let create_fresh_keeper_token () =
    let raw_token = generate_token () in
    let id, agent_id =
      match existing with
      | Some cred ->
        ( (match cred.id with
           | Some id -> id
           | None -> Credential_id.generate ())
        , cred.agent_id )
      | None -> Credential_id.generate (), None
    in
    let cred =
      { id = Some id
      ; agent_id
      ; agent_name
      ; token = sha256_hash raw_token
      ; role = Worker
      ; created_at = now_iso ()
      ; expires_at = None
      }
    in
    persist_raw_token config ~agent_name raw_token;
    save_credential config cred;
    raw_token, cred
  in
  let result =
    try
      match load_raw_token config ~agent_name with
      | Some raw_token ->
        (match verify_token config ~agent_name ~token:raw_token with
         | Ok cred when String.equal cred.agent_name agent_name -> Ok (raw_token, cred)
         | Ok _ | Error _ -> Ok (create_fresh_keeper_token ()))
      | None -> Ok (create_fresh_keeper_token ())
    with
    | Eio.Cancel.Cancelled _ as e -> raise e
    | exn ->
      let msg =
        Printf.sprintf "Failed to save keeper credential: %s" (Printexc.to_string exn)
      in
      Log.Auth.error "%s" msg;
      Error (System (System_error.IoError msg))
  in
  result
;;

type credential_status =
  | Credential_present of agent_credential
  | Credential_missing

let audit_keeper_credentials config ~keeper_names =
  List.map
    (fun keeper_name ->
       let status =
         match load_credential config keeper_name with
         | Some cred -> Credential_present cred
         | None -> Credential_missing
       in
       keeper_name, status)
    keeper_names
;;

(** Refresh a token (generate new one, update credential) *)
let refresh_token config ~agent_name ~old_token
  : (string * agent_credential, masc_error) result
  =
  match verify_token config ~agent_name ~token:old_token with
  | Error (Auth (Auth_error.TokenExpired _)) ->
    (* Allow refresh even if expired *)
    (match load_credential config agent_name with
     | None ->
       Error (Auth (Auth_error.Unauthorized
         { reason = Missing_token
         ; message = "No credential found for " ^ agent_name
         }))
     | Some old_cred -> create_token config ~agent_name ~role:old_cred.role)
  | Error e -> Error e
  | Ok old_cred -> create_token config ~agent_name ~role:old_cred.role
;;

(* ============================================ *)
(* Authorization                                *)
(* ============================================ *)

(** Check if agent has permission for an action *)
let verify_optional_token config ~agent_name ~token
  : (agent_credential option, masc_error) result
  =
  match token with
  | None -> Ok None
  | Some raw ->
    (match verify_token config ~agent_name ~token:raw with
     | Ok cred -> Ok (Some cred)
     | Error e -> Error e)
;;

(** Verify a caller-presented secret against the workspace root secret
    minted once by [init_workspace_secret] (and shown to the operator at
    that time). This is the only proof-of-possession the bootstrap/recovery
    grace below accepts.

    Compares against [cached_hash] (the [auth_config.workspace_secret_hash]
    the caller already loaded via [load_auth_config]/[resolve_role_with_
    auth_config]) instead of re-reading [workspace_secret_file] on every
    call - this sits on the hot path for every authenticated request, and a
    per-call blocking read can raise on a permission error or a partial
    write, turning an auth check into a request failure. Falls back to a
    guarded on-disk read only when the config predates the cache (or a
    concurrent write raced this read); that read fails closed (verification
    fails) rather than raising. *)
let verify_workspace_secret config ~cached_hash secret : bool =
  let hash = sha256_hash secret in
  match cached_hash with
  | Some stored_hash -> constant_time_string_equal hash stored_hash
  | None ->
    let file = workspace_secret_file config in
    (try
       if Sys.file_exists file
       then constant_time_string_equal hash (String.trim (In_channel.with_open_text file In_channel.input_all))
       else false
     with _ -> false)
;;

let check_permission config ~agent_name ~token ~permission : (unit, masc_error) result =
  let auth_cfg = load_auth_config config in
  if not auth_cfg.enabled
  then
    (* Auth disabled - allow everything *)
    Ok ()
  else if
    match token with
    | Some raw ->
      verify_workspace_secret config ~cached_hash:auth_cfg.workspace_secret_hash raw
    | None -> false
  then (
    (* Recovery grace: presenting the workspace secret proves possession of
       the root credential minted at [enable_auth] time, so the caller can
       always regain admin access (prevents BUG-025's circular permission
       deadlock if the bootstrap admin's own token has expired/been lost).
       The previous version of this branch matched [agent_name] against
       [read_initial_admin] with no proof of possession at all — any
       unauthenticated caller could self-declare that name via a plain
       request header and be granted Admin outright. *)
    ignore permission;
    Ok ())
  else if
    match token with
    | Some raw -> verify_internal_keeper_token config ~token:raw
    | None -> false
  then
    if has_permission Worker permission
    then Ok ()
    else
      Error
        (Auth
           (Auth_error.Forbidden
              { agent = agent_name; action = permission_to_string permission }))
  else (
    match verify_optional_token config ~agent_name ~token with
    | Error e -> Error e
    | Ok (Some cred) ->
      if has_permission cred.role permission
      then Ok ()
      else
        Error
          (Auth
             (Auth_error.Forbidden
                { agent = agent_name; action = permission_to_string permission }))
    | Ok None ->
      if not auth_cfg.require_token
      then
        (* Optional-token mode: anonymous callers are always treated as
             non-admin workers. *)
        if has_permission Worker permission
        then Ok ()
        else
          Error
            (Auth
               (Auth_error.Forbidden
                  { agent = agent_name; action = permission_to_string permission }))
      else Error (Auth (Auth_error.Unauthorized
        { reason = Missing_token; message = "Token required" })))
;;

(** Tool auth is always strict: unknown internal tools require at least
    worker-level permission, and unknown external tools are denied. *)
let is_tool_auth_strict_enabled () = true

(* #10205 finding 1: SSOT for the internal-tool prefix vocabulary.
   Unmapped dotted game-view namespaces ([decision.], [experiment.], [client.])
   were retired from the MCP front door; do not preserve them as implicit
   strict-auth internals.  Keeper runtime tools are NOT a prefix: a [keeper_*]
   prefix alone is not enough to cross auth — the catalog must own the tool.
   That check stays separate. *)
let internal_tool_prefixes = [ "masc_" ]

let has_internal_tool_prefix tool_name =
  List.exists
    (fun pref -> String.starts_with ~prefix:pref tool_name)
    internal_tool_prefixes
;;

let is_known_or_internal_tool_name tool_name =
  has_internal_tool_prefix tool_name
  || Option.is_some (Tool_catalog.registered_metadata tool_name)
;;

let unknown_tool_class tool_name =
  if String.trim tool_name = "" then "empty" else "external"
;;

let record_strict_unknown_tool_denial ~agent_name ~tool_name =
  Auth_metric_store.inc_counter
    Auth_metric_store.metric_auth_strict_unknown_tool_denials
    ~labels:[ "agent_name", agent_name; "tool_class", unknown_tool_class tool_name ]
    ()
;;

(** Check permission for a tool call *)
let authorize_tool config ~agent_name ~token ~tool_name : (unit, masc_error) result =
  if is_known_or_internal_tool_name tool_name
  then
    check_permission
      config
      ~agent_name
      ~token
      ~permission:(Tool_catalog.required_permission tool_name)
  else (
    let () = record_strict_unknown_tool_denial ~agent_name ~tool_name in
    Error
      (Auth
         (Auth_error.Forbidden
            { agent = agent_name; action = "use unknown non-masc tool: " ^ tool_name })))
;;

(* ============================================ *)
(* Unified policy-based authorization (v2)      *)
(* ============================================ *)

(** Resolve the effective role for an agent from auth context.
    Returns Error for invalid tokens (no silent downgrade). *)
let resolve_role_with_auth_config config ~auth_cfg ~agent_name ~token
  : (agent_role, masc_error) result
  =
  if not auth_cfg.enabled
  then Ok Admin (* Auth disabled = full access *)
  else if
    match token with
    | Some raw ->
      verify_workspace_secret config ~cached_hash:auth_cfg.workspace_secret_hash raw
    | None -> false
  then Ok Admin (* Recovery grace via workspace secret possession; see check_permission *)
  else if
    match token with
    | Some raw -> verify_internal_keeper_token config ~token:raw
    | None -> false
  then Ok Worker
  else (
    match verify_optional_token config ~agent_name ~token with
    | Error e -> Error e
    | Ok (Some cred) -> Ok cred.role
    | Ok None ->
      if auth_cfg.require_token
      then Error (Auth (Auth_error.Unauthorized
        { reason = Missing_token; message = "Token required" }))
      else Ok Worker)
;;

let resolve_role config ~agent_name ~token : (agent_role, masc_error) result =
  let auth_cfg = load_auth_config config in
  resolve_role_with_auth_config config ~auth_cfg ~agent_name ~token
;;

let authorize_tool_for_role ~agent_name ~role ~tool_name : (unit, masc_error) result =
  if is_known_or_internal_tool_name tool_name
  then
    let required_permission = Tool_catalog.required_permission tool_name in
    if has_permission role required_permission
    then Ok ()
    else
      Error
        (Auth
           (Auth_error.Forbidden
              { agent = agent_name
              ; action = permission_to_string required_permission ^ ":" ^ tool_name
              }))
  else (
    let () = record_strict_unknown_tool_denial ~agent_name ~tool_name in
    Error
      (Auth
         (Auth_error.Forbidden
            { agent = agent_name; action = "use unknown non-masc tool: " ^ tool_name })))
;;

(** Role-based tool authorization.
    Resolves the caller role and enforces generic internal-tool access.
    Invalid/expired tokens are rejected (not silently downgraded).

    Known tools require the permission declared by [Tool_catalog]; unknown
    internal names default to Worker-level [CanBroadcast]. *)
let authorize_tool_v2 config ~agent_name ~token ~tool_name : (unit, masc_error) result =
  match resolve_role config ~agent_name ~token with
  | Error e -> Error e
  | Ok role -> authorize_tool_for_role ~agent_name ~role ~tool_name
;;

(* ============================================ *)
(* Workspace secret                                  *)
(* ============================================ *)

(** Initialize workspace secret *)
let init_workspace_secret config : string =
  ensure_auth_dirs config;
  let secret = generate_token () in
  let hash = sha256_hash secret in
  save_private_text_file (workspace_secret_file config) hash;
  (* Update auth config with hash *)
  let cfg = load_auth_config config in
  save_auth_config config { cfg with workspace_secret_hash = Some hash };
  secret (* Return raw secret to show user once *)
;;

(* [verify_workspace_secret] now lives earlier in this file, above
   [check_permission], since the bootstrap/recovery grace branch there
   depends on it. *)

(* ============================================ *)
(* High-level auth operations                   *)
(* ============================================ *)

(** Enable authentication for a workspace.
    Creates a bootstrap admin token for the enabling agent to prevent
    circular permission deadlock (BUG-025). *)
let enable_auth config ~require_token ~agent_name : string * string option =
  let secret = init_workspace_secret config in
  let cfg = load_auth_config config in
  save_auth_config config { cfg with enabled = true; require_token };
  let bootstrap_token =
    if agent_name <> ""
    then (
      write_initial_admin config agent_name;
      match create_token config ~agent_name ~role:Admin with
      | Ok (token, _cred) -> Some token
      | Error e ->
        Log.Auth.warn
          "[enable_auth] bootstrap token creation failed for %s: %s"
          agent_name
          (Masc_domain.show_masc_error e);
        None)
    else None
  in
  secret, bootstrap_token
;;

(** Disable authentication *)
let disable_auth config =
  let cfg = load_auth_config config in
  save_auth_config config { cfg with enabled = false };
  let file = initial_admin_file config in
  if Sys.file_exists file then Sys.remove file
;;

(** Check if auth is enabled *)
let is_auth_enabled config : bool =
  let cfg = load_auth_config config in
  cfg.enabled
;;

