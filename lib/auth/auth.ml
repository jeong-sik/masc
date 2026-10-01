(** MASC Authentication & Authorization Module *)

open Masc_domain

(* Crypto utilities, file I/O, config, credential CRUD, token
   verification — formerly re-exported via Auth_credential shim. *)

include Auth_credential_base
include Auth_credential_token

let keeper_credential_write_authority config ~credentials ~agent_name stored
    (credential : agent_credential) =
  let ( let* ) = Result.bind in
  let refused detail = Error (System (System_error.ValidationError
      (Printf.sprintf "Keeper credential storage authority for %s: %s" agent_name detail))) in
  if not (String.equal credential.agent_name agent_name) then
    refused "requested name is not the credential's canonical owner"
  else
    (* A noncanonical UUID on an unselected owner can still alias this write
       target on a case-insensitive store, including before either file exists. *)
    let* () = List.fold_left (fun checked (owner_stored, owner) ->
      let* () = checked in
      let* _target = credential_owned_uuid_target ~leaf_policy:Follow_regular_symlink config owner.agent_name owner_stored owner in
      Ok ()) (Ok ()) credentials in
    let* _target = credential_owned_uuid_target ~leaf_policy:Follow_regular_symlink config agent_name stored credential in
    match credential.id with
    | None -> Ok ()
    | Some id ->
        if String.equal (credential_uuid_file config id) (credential_file config agent_name) then
          refused "UUID payload and named credential share a path"
        else if List.exists (fun (_, (owner : agent_credential)) ->
          not (String.equal owner.agent_name agent_name)
          && Option.equal Credential_id.equal owner.id credential.id) credentials then
          refused "another current owner has the same UUID"
        else Ok ()
;;

let ensure_keeper_credential_in_transaction
    ((Credential_transaction config) as transaction) ~credentials ~find_token ~agent_name =
  let create_fresh_keeper_token transaction existing =
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
    let ( let* ) = Result.bind in
    let* () = keeper_credential_write_authority config ~credentials ~agent_name
        (Stored_credential cred) cred in
    publish_file_backed_credential_in_transaction transaction cred ~raw_token
    |> Result.map_error file_backed_publication_error
    |> Result.map (fun () -> raw_token, cred)
  in
    let ( let* ) = Result.bind in
    let* present = credential_path_exists (credential_file config agent_name) in
    let* () = if not present then Ok () else
      let* stored = read_stored_credential ~leaf_policy:Follow_regular_symlink config agent_name (credential_file config agent_name) in
      let* resolved = resolve_stored_credential ~leaf_policy:Follow_regular_symlink config agent_name stored in
      match resolved with
      | None -> Error (System (System_error.ValidationError
          (Printf.sprintf "Keeper credential storage authority for %s cannot be resolved" agent_name)))
      | Some credential -> keeper_credential_write_authority config ~credentials ~agent_name stored credential in
    let* current = current_credential_in_transaction transaction agent_name in
    let* raw = raw_token_in_transaction transaction agent_name in
    let* () = match current, raw with
      | Some credential, Some raw_token
        when constant_time_string_equal credential.token (sha256_hash raw_token) ->
          validate_file_backed_bearer raw_token
      | Some _, Some _ | Some _, None | None, Some _ | None, None -> Ok () in
    let* _internal = credential_read_result (fun () -> ensure_internal_keeper_token config) in
    match current, raw with
    | Some credential, Some raw_token
      when constant_time_string_equal credential.token (sha256_hash raw_token) ->
      (match find_token ~token:raw_token with
       | Ok credential -> Ok (raw_token, credential)
       | Error (Auth _) -> create_fresh_keeper_token transaction current
       | Error _ as error -> error)
    | Some _, Some _ | Some _, None | None, Some _ | None, None ->
      create_fresh_keeper_token transaction current
;;

let ensure_keeper_credential config ~agent_name =
  with_credential_transaction config (fun transaction ->
    let ( let* ) = Result.bind in
    let* snapshot = credential_store_snapshot_in_transaction ~leaf_policy:Follow_regular_symlink transaction in
    ensure_keeper_credential_in_transaction transaction ~agent_name
      ~credentials:snapshot.current_credentials
      ~find_token:(find_static_credential_in_transaction ~leaf_policy:Follow_regular_symlink transaction))
  |> Result.join
;;

let ensure_keeper_credentials config ~agent_names =
  with_credential_transaction config (fun transaction ->
    let ( let* ) = Result.bind in
    let* snapshot = credential_store_snapshot_in_transaction ~leaf_policy:Follow_regular_symlink transaction in
    let credentials = List.map snd snapshot.current_credentials in
    let index = build_token_index credentials in
    let initially_shared = Hashtbl.fold (fun token owners hashes ->
      if List.length owners > 1 then token :: hashes else hashes) index [] in
    let find_token ~token =
      if List.mem (sha256_hash token) initially_shared then
        Error (Auth (Auth_error.InvalidToken "Credential bearer was shared at batch admission"))
      else find_static_credential_in_index index ~token in
    let by_name = Hashtbl.create (List.length credentials) in
    List.iter (fun (credential : agent_credential) ->
      Hashtbl.replace by_name credential.agent_name credential) credentials;
    let update (credential : agent_credential) =
      (match Hashtbl.find_opt by_name credential.agent_name with
       | None -> ()
       | Some previous ->
         (match Hashtbl.find_opt index previous.token with
          | None -> ()
          | Some entries -> Hashtbl.replace index previous.token
              (List.filter (fun (entry : agent_credential) ->
                not (String.equal entry.agent_name credential.agent_name)) entries)));
      let entries = match Hashtbl.find_opt index credential.token with
        | None -> [] | Some entries -> entries in
      Hashtbl.replace index credential.token (credential :: entries);
      Hashtbl.replace by_name credential.agent_name credential in
    let rec sync ownership = function
      | [] -> []
      | agent_name :: rest ->
        let result = ensure_keeper_credential_in_transaction transaction ~agent_name
            ~credentials:ownership
            ~find_token in
        (agent_name, result) ::
        (match result with
         | Ok (_, credential) ->
             update credential;
             let stored = match credential.id with
               | None -> Stored_credential credential
               | Some id -> Stored_redirect (credential_uuid_file config id) in
             let ownership = (stored, credential) :: List.filter (fun (_, owner) ->
               not (String.equal owner.agent_name credential.agent_name)) ownership in
             sync ownership rest
         | Error _ ->
             (* Preflight failures leave other Keepers independent. After any
                failure, re-read admitted authority before deciding whether
                the remaining names can safely use a rebuilt index. *)
             (match credential_store_snapshot_in_transaction ~leaf_policy:Follow_regular_symlink transaction with
              | Error error -> List.map (fun name -> name, Error error) rest
              | Ok snapshot ->
                  Hashtbl.clear index; Hashtbl.clear by_name;
                  List.iter (fun (_, credential) -> update credential) snapshot.current_credentials;
                  sync snapshot.current_credentials rest)) in
    Ok (sync snapshot.current_credentials agent_names))
  |> Result.join
;;

type credential_status =
  | Credential_present of agent_credential
  | Credential_missing

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
    (match read_regular_auth_file (workspace_secret_file config) with
     | Error _ -> false
     | Ok content -> constant_time_string_equal hash (String.trim content))
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

(** Tool auth is always strict: the catalog owns every callable tool name and
    its typed permission. Unregistered names are denied regardless of prefix. *)
let is_tool_auth_strict_enabled () = true

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
  match Tool_catalog.registered_metadata tool_name with
  | Some metadata ->
    check_permission
      config
      ~agent_name
      ~token
      ~permission:metadata.required_permission
  | None ->
    let () = record_strict_unknown_tool_denial ~agent_name ~tool_name in
    Error
      (Auth
         (Auth_error.Forbidden
            { agent = agent_name; action = "use unregistered tool: " ^ tool_name }))
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
  match Tool_catalog.registered_metadata tool_name with
  | Some metadata ->
    if has_permission role metadata.required_permission
    then Ok ()
    else Error (Auth (Auth_error.Forbidden { agent = agent_name; action = tool_name }))
  | None ->
    let () = record_strict_unknown_tool_denial ~agent_name ~tool_name in
    Error
      (Auth
         (Auth_error.Forbidden
            { agent = agent_name; action = "use unregistered tool: " ^ tool_name }))
;;

(** Role-based tool authorization.
    Resolves the caller role and enforces generic internal-tool access.
    Invalid/expired tokens are rejected (not silently downgraded).

    Each registered tool requires its catalog-owned typed permission; every
    unregistered name is forbidden. *)
let authorize_tool_v2 config ~agent_name ~token ~tool_name : (unit, masc_error) result =
  match resolve_role config ~agent_name ~token with
  | Error e -> Error e
  | Ok role -> authorize_tool_for_role ~agent_name ~role ~tool_name
;;

(* ============================================ *)
(* Workspace secret                                  *)
(* ============================================ *)

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
