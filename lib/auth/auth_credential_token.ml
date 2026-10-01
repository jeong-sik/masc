(** Token operations for MASC authentication. *)

open Masc_domain
open Auth_credential_base

(* ============================================ *)
(* Full credential comparison                   *)
(* ============================================ *)

(** Structured description of which credential fields differ between two
    credentials that share the same token hash.  Uses typed variants rather
    than string matching so callers can dispatch on the difference. *)
type credential_field_diff =
  | Agent_name of { left : string; right : string }
  | Role of { left : agent_role; right : agent_role }
  | Created_at of { left : string; right : string }
  | Expires_at of { left : string option; right : string option }
  | Agent_id of { left : string option; right : string option }
  | Credential_id of { left : string option; right : string option }
  | Token_hash of { left : string; right : string }

(** Observability payload emitted when two credentials hash to the same
    value but are not identical.  Includes a short hash prefix for
    correlation and the involved agent names so operators can triage. *)
type collision_log = {
  token_hash_prefix : string;
  left_agent : string;
  right_agent : string;
  field_diffs : credential_field_diff list;
}

(** Pure comparison result: [Equal] means the two credentials are
    identical on every field; [Different log] carries a typed record
    of the divergence. *)
type credential_comparison =
  | Equal
  | Different of collision_log

let collision_log_to_yojson log =
  let field_diff_to_yojson = function
    | Agent_name { left; right } ->
      `Assoc
        [ "field", `String "agent_name"
        ; "left", `String left
        ; "right", `String right
        ]
    | Role { left; right } ->
      `Assoc
        [ "field", `String "role"
        ; "left", `String (agent_role_to_string left)
        ; "right", `String (agent_role_to_string right)
        ]
    | Created_at { left; right } ->
      `Assoc
        [ "field", `String "created_at"
        ; "left", `String left
        ; "right", `String right
        ]
    | Expires_at { left; right } ->
      `Assoc
        [ "field", `String "expires_at"
        ; "left", Option.fold ~none:`Null ~some:(fun s -> `String s) left
        ; "right", Option.fold ~none:`Null ~some:(fun s -> `String s) right
        ]
    | Agent_id { left; right } ->
      `Assoc
        [ "field", `String "agent_id"
        ; "left", Option.fold ~none:`Null ~some:(fun s -> `String s) left
        ; "right", Option.fold ~none:`Null ~some:(fun s -> `String s) right
        ]
    | Credential_id { left; right } ->
      `Assoc
        [ "field", `String "credential_id"
        ; "left", Option.fold ~none:`Null ~some:(fun s -> `String s) left
        ; "right", Option.fold ~none:`Null ~some:(fun s -> `String s) right
        ]
    | Token_hash { left; right } ->
      `Assoc
        [ "field", `String "token_hash"
        ; "left", `String left
        ; "right", `String right
        ]
  in
  `Assoc
    [ "token_hash_prefix", `String log.token_hash_prefix
    ; "left_agent", `String log.left_agent
    ; "right_agent", `String log.right_agent
    ; "field_diffs", `List (List.map field_diff_to_yojson log.field_diffs)
    ]
;;

(** Shared constant-time string equality for raw bearer tokens. *)
let constant_time_string_equal = Auth_credential_base.constant_time_string_equal

let validate_raw_token raw_token =
  if String.trim raw_token = ""
  then
    Error
      (Auth
         (Auth_error.InvalidToken
            "Raw token must not be blank or whitespace-only"))
  else Ok ()
;;

(** Compare two credentials field-by-field.  The caller supplies the
    token hash prefix for the collision log; the comparison itself is
    pure and depends only on the two records. *)
let compare_credentials ~token_hash_prefix left right : credential_comparison =
  let field_diffs = [] in
  let field_diffs =
    if not (String.equal left.agent_name right.agent_name)
    then Agent_name { left = left.agent_name; right = right.agent_name } :: field_diffs
    else field_diffs
  in
  let field_diffs =
    if left.role <> right.role
    then Role { left = left.role; right = right.role } :: field_diffs
    else field_diffs
  in
  let field_diffs =
    if not (String.equal left.created_at right.created_at)
    then Created_at { left = left.created_at; right = right.created_at } :: field_diffs
    else field_diffs
  in
  let field_diffs =
    if not (Option.equal String.equal left.expires_at right.expires_at)
    then Expires_at { left = left.expires_at; right = right.expires_at } :: field_diffs
    else field_diffs
  in
  let field_diffs =
    let id_to_string = Option.map Credential_id.to_string in
    if not (Option.equal String.equal (id_to_string left.id) (id_to_string right.id))
    then
      Credential_id { left = id_to_string left.id; right = id_to_string right.id }
      :: field_diffs
    else field_diffs
  in
  let field_diffs =
    let id_to_string = Option.map Agent_id.to_string in
    if not (Option.equal String.equal (id_to_string left.agent_id) (id_to_string right.agent_id))
    then
      Agent_id { left = id_to_string left.agent_id; right = id_to_string right.agent_id }
      :: field_diffs
    else field_diffs
  in
  let field_diffs =
    if not (constant_time_string_equal left.token right.token)
    then Token_hash { left = left.token; right = right.token } :: field_diffs
    else field_diffs
  in
  match field_diffs with
  | [] -> Equal
  | _ :: _ ->
    Different
      { token_hash_prefix
      ; left_agent = left.agent_name
      ; right_agent = right.agent_name
      ; field_diffs = List.rev field_diffs
      }
;;

let emit_collision_event collision_log =
  Log.Auth.emit
    Log.Warn
    ~details:(collision_log_to_yojson collision_log)
    ~category:Log.Routine
    "Token hash collision detected: full credential comparison rejected lookup";
  Auth_metric_store.inc_counter
    Auth_metric_store.metric_auth_credential_hash_collision
    ~labels:[ "left_agent", collision_log.left_agent; "right_agent", collision_log.right_agent ]
    ()
;;

(** Walk a list of credentials that share the same token hash.  If every
    pair compares equal, return [Ok ()].  On the first differing pair,
    emit a structured collision event and return [Error]. *)
let rec check_credential_collisions ~token_hash_prefix first = function
  | [] -> Ok ()
  | next :: rest ->
    (match compare_credentials ~token_hash_prefix first next with
     | Equal -> check_credential_collisions ~token_hash_prefix first rest
     | Different collision_log ->
       emit_collision_event collision_log;
       Error (Auth (Auth_error.InvalidToken "Token hash collision detected")))
;;

let credential_matches_live_disk config (cred : agent_credential) =
  match load_credential config cred.agent_name with
  | None -> false
  | Some current ->
    Option.equal Credential_id.equal current.id cred.id
    && Option.equal Agent_id.equal current.agent_id cred.agent_id
    && String.equal current.agent_name cred.agent_name
    && current.role = cred.role
    && String.equal current.created_at cred.created_at
    && Option.equal String.equal current.expires_at cred.expires_at
    && constant_time_string_equal current.token cred.token
;;

let fresh_matches_for_token_hash config token_hash matches =
  if List.for_all (credential_matches_live_disk config) matches
  then Ok matches
  else (
    invalidate_credential_index_cache config;
    let open Result.Syntax in
    let* idx = credential_token_index config in
    (* DET-OK: exact token-hash cache miss means there are no indexed
       credential candidates; this does not infer state from ambiguous input. *)
    match Hashtbl.find_opt idx token_hash with
    | Some matches ->
      if List.for_all (credential_matches_live_disk config) matches
      then Ok matches
      else Error (Auth (Auth_error.InvalidToken "Credential changed during token lookup"))
    | None -> Ok [])
;;

(** Find credential by raw token (hash lookup + expiry check).

    #9786 runtime complement: when N>=2 credentials share the
    token hash, [List.find_opt] silently routed to the first
    match - the root of the [bearer token belongs to X]
    regression.  We now compare the full credential before
    treating two hash matches as equal; if the credentials differ,
    the lookup fails with [InvalidToken] and a structured collision
    event is emitted so operators can detect brute-force attempts.
    When N>=2 credentials are fully identical we still warn and
    increment {!Auth_metric_store.metric_auth_credential_ambiguous_lookup}
    so the duplicate-token audit path remains observable. *)
let find_static_credential_by_token config ~token : (agent_credential, masc_error) result =
  let open Result.Syntax in
  let token_hash = sha256_hash token in
  let* idx = credential_token_index config in
  let* matches =
    Hashtbl.find_opt idx token_hash |> Option.value ~default:[]
    |> fresh_matches_for_token_hash config token_hash
  in
  match matches with
  | [] -> Error (Auth (Auth_error.InvalidToken "Token mismatch"))
  | first :: rest ->
    (match check_credential_collisions ~token_hash_prefix:(token_hash_prefix_of token_hash) first rest with
     | Error e -> Error e
     | Ok () ->
       (match rest with
        | [] -> ()
        | _ :: _ ->
          let names = List.map (fun (c : agent_credential) -> c.agent_name) matches in
          Log.Misc.warn
            "auth: token shared by %d agents [%s] - routing to %s (first match); rotate via \
             Auth.create_token to disambiguate (#9786)"
            (List.length matches)
            (String.concat ", " names)
            first.agent_name;
          Auth_metric_store.inc_counter
            Auth_metric_store.metric_auth_credential_ambiguous_lookup
            ~labels:[ "first_match", first.agent_name ]
            ());
       require_live_credential ~now:(Time_compat.now ()) first)
;;

let find_static_credential_in_index index ~token =
  let ( let* ) = Result.bind in
  let token_hash = sha256_hash token in
  match Hashtbl.find_opt index token_hash with
  | None | Some [] -> Error (Auth (Auth_error.InvalidToken "Token mismatch"))
  | Some (first :: rest) ->
    let* () = check_credential_collisions
        ~token_hash_prefix:(token_hash_prefix_of token_hash) first rest in
    require_live_credential ~now:(Time_compat.now ()) first
;;

let find_static_credential_in_transaction ?(leaf_policy = Owned_regular_only) transaction ~token =
  let ( let* ) = Result.bind in
  let* snapshot = credential_store_snapshot_in_transaction ~leaf_policy transaction in
  let index = build_token_index (List.map snd snapshot.current_credentials) in
  find_static_credential_in_index index ~token
;;

(** Resolve either an OAuth access token or the existing static bearer.
    OAuth owns a token whenever its exact hash file exists, including expired
    or revoked records; those typed failures must not silently fall through to
    static lookup. *)
let find_credential_by_token config ~token : (agent_credential, masc_error) result =
  match Auth_oauth.find_access_credential ~base_path:config ~token with
  | Ok (Some credential) -> Ok credential
  | Ok None -> find_static_credential_by_token config ~token
  | Error error -> Error error
;;

(** Resolve agent_name from raw token *)
let resolve_agent_from_token config ~token : (string, masc_error) result =
  match find_credential_by_token config ~token with
  | Ok cred -> Ok cred.agent_name
  | Error e -> Error e
;;

(* The bound is [Masc_domain]'s: the same pair the config decoder enforces, so a
   window a caller names and a window read off disk are accepted on identical
   terms. *)
let expires_at_in_hours hours : (string, masc_error) result =
  if hours < min_token_expiry_hours || hours > max_token_expiry_hours
  then
    Error
      (System
         (System_error.ValidationError
            (Printf.sprintf
               "token lifetime of %d hours is outside %d..%d"
               hours
               min_token_expiry_hours
               max_token_expiry_hours)))
  else (
    let expiry =
      Time_compat.now () +. (float_of_int hours *. Masc_time_constants.hour)
    in
    Ok (Masc_domain.iso8601_of_unix_seconds expiry))
;;

let expires_at_for_auth_config auth_cfg =
  (* A config that got past decoding cannot carry an out-of-range window, so a
     rejection here means the record was built in code rather than read from
     disk -- a bug, not bad input. *)
  match expires_at_in_hours auth_cfg.token_expiry_hours with
  | Ok expires_at -> Some expires_at
  | Error _ ->
    invalid_arg
      (Printf.sprintf
         "auth config token_expiry_hours is outside %d..%d"
         min_token_expiry_hours
         max_token_expiry_hours)
;;

let raw_token_credential ~agent_name ~role ~raw_token ~expires_at =
  { id = None
  ; agent_id = None
  ; agent_name
  ; token = sha256_hash raw_token
  ; role
  ; created_at = now_iso ()
  ; expires_at
  }
;;

let save_raw_token_credential_with_expiry config ~agent_name ~role ~raw_token ~expires_at
  : (agent_credential, masc_error) result
  =
  match validate_raw_token raw_token with
  | Error _ as error -> error
  | Ok () ->
    let cred = raw_token_credential ~agent_name ~role ~raw_token ~expires_at in
    (try
       save_credential config cred;
       Ok cred
     with
     | Eio.Cancel.Cancelled _ as e -> raise e
     | exn ->
       let msg =
         Printf.sprintf "Failed to save agent credential: %s" (Printexc.to_string exn)
       in
       Log.Auth.error "%s" msg;
       Error (System (System_error.IoError msg)))
;;

let save_raw_token_credential config ~agent_name ~role ~raw_token
  : (agent_credential, masc_error) result
  =
  let auth_cfg = load_auth_config config in
  save_raw_token_credential_with_expiry
    config
    ~agent_name
    ~role
    ~raw_token
    ~expires_at:(expires_at_for_auth_config auth_cfg)
;;

let save_raw_token_credential_without_expiry config ~agent_name ~role ~raw_token
  : (agent_credential, masc_error) result
  =
  save_raw_token_credential_with_expiry
    config
    ~agent_name
    ~role
    ~raw_token
    ~expires_at:None
;;

type file_backed_token_lifetime = Config_expiry | No_expiry | Expires_in_hours of int

let file_backed_expiry config = function
  | No_expiry -> Ok None
  | Expires_in_hours hours -> expires_at_in_hours hours |> Result.map Option.some
  | Config_expiry ->
    let ( let* ) = Result.bind in
    let* auth_cfg = credential_auth_config_result config in
    Ok (expires_at_for_auth_config auth_cfg)
;;

let publish_requested_file_backed_token config ~agent_name ~role ~lifetime ~raw_token =
  with_credential_transaction config (fun transaction ->
    let ( let* ) = Result.bind in
    let* _current = current_credential_in_transaction transaction agent_name in
    let* _raw = raw_token_in_transaction transaction agent_name in
    let* expires_at = file_backed_expiry config lifetime in
    let credential = raw_token_credential ~agent_name ~role ~raw_token ~expires_at in
    let* () = publish_file_backed_credential_in_transaction transaction credential ~raw_token
      |> Result.map_error file_backed_publication_error in
    Ok credential)
  |> Result.join
;;

let save_file_backed_raw_token_credential config ~agent_name ~role ~raw_token =
  let ( let* ) = Result.bind in
  let* () = validate_raw_token raw_token in
  let* () = validate_file_backed_bearer raw_token in
  publish_requested_file_backed_token config ~agent_name ~role ~raw_token ~lifetime:Config_expiry
;;

type login_auth_change = Auth_already_required | Auth_enabled | Require_token_enabled

let prepare_login_auth config auth_cfg ~agent_name ~role =
  if auth_cfg.enabled && auth_cfg.require_token then Ok Auth_already_required
  else if auth_cfg.enabled then
    credential_read_result (fun () ->
      save_auth_config config { auth_cfg with require_token = true };
      Require_token_enabled)
  else
    credential_read_result (fun () ->
      let _secret = init_workspace_secret config in
      let cfg = load_auth_config config in
      save_auth_config config { cfg with enabled = true; require_token = true };
      (match role with
       | Admin when agent_name <> "" -> write_initial_admin config agent_name
       | Admin | Worker | Player -> ());
      Auth_enabled)
;;

let create_file_backed_login_token config ~agent_name ~role ~lifetime =
  match role with
  | Player -> Error (Auth (Auth_error.Forbidden
      { agent = agent_name; action = "log in as a player; a player is invited" }))
  | Admin | Worker ->
    with_credential_transaction config (fun transaction ->
      let ( let* ) = Result.bind in
      let* _current = current_credential_in_transaction transaction agent_name in
      let* _raw = raw_token_in_transaction transaction agent_name in
      let* expires_at = file_backed_expiry config lifetime in
      let* auth_cfg = credential_auth_config_result config in
      let* auth_change = prepare_login_auth config auth_cfg ~agent_name ~role in
      let raw_token = generate_token () in
      let credential = raw_token_credential ~agent_name ~role ~raw_token ~expires_at in
      let* () = publish_file_backed_credential_in_transaction transaction credential ~raw_token
        |> Result.map_error file_backed_publication_error in
      Ok (raw_token, credential, auth_change))
    |> Result.join

;;

(* ============================================ *)
(* Token operations                             *)
(* ============================================ *)

(** Create a new token for an agent *)
let create_token config ~agent_name ~role : (string * agent_credential, masc_error) result
  =
  let raw_token = generate_token () in
  match save_raw_token_credential config ~agent_name ~role ~raw_token with
  | Ok cred -> Ok (raw_token, cred)
  | Error e -> Error e
;;

let create_token_without_expiry config ~agent_name ~role
  : (string * agent_credential, masc_error) result
  =
  let raw_token = generate_token () in
  match save_raw_token_credential_without_expiry config ~agent_name ~role ~raw_token with
  | Ok cred -> Ok (raw_token, cred)
  | Error e -> Error e
;;

let create_token_expiring_in config ~agent_name ~role ~hours
  : (string * agent_credential, masc_error) result
  =
  match expires_at_in_hours hours with
  | Error _ as error -> error
  | Ok expires_at ->
    let raw_token = generate_token () in
    (match
       save_raw_token_credential_with_expiry
         config
         ~agent_name
         ~role
         ~raw_token
         ~expires_at:(Some expires_at)
     with
     | Ok cred -> Ok (raw_token, cred)
     | Error e -> Error e)
;;

type create_token_error =
  | Credential_name_taken
  | Credential_not_created of masc_error

let create_token_expiring_in_if_absent config ~agent_name ~role ~hours =
  let not_created error = Credential_not_created error in
  match expires_at_in_hours hours with
  | Error error -> Error (not_created error)
  | Ok expires_at ->
    (try
       with_credential_transaction config (fun transaction ->
         match credential_exists_in_transaction transaction agent_name with
         | Error error -> Error (not_created error)
         | Ok true -> Error Credential_name_taken
         | Ok false ->
           let raw_token = generate_token () in
           let cred = raw_token_credential ~agent_name ~role ~raw_token
               ~expires_at:(Some expires_at) in
           save_credential_in_transaction transaction cred;
           Ok (raw_token, cred))
       |> Result.map_error not_created
       |> Result.join
     with
     | Eio.Cancel.Cancelled _ as exn -> raise exn
     | exn ->
       Error (not_created (System (System_error.IoError
         (Printf.sprintf "Failed to create agent credential: %s" (Printexc.to_string exn))))))
;;

type rotation_publication = Auth_credential_base.credential_publication =
  | Published
  | Not_published
  | Publication_unreadable of masc_error

type rotation_failure = Auth_credential_base.credential_publication_failure =
  { error : masc_error
  ; raw_token : rotation_publication
  ; credential : rotation_publication }

type rotation_outcome =
  { token_hash_prefix : string
  ; rotated_agents : (string * (unit, rotation_failure) result) list }

let rotation_failure_to_string = credential_publication_failure_to_string

let save_rotated_raw_token_in_transaction transaction ~auth_cfg (cred : agent_credential) ~raw_token =
  let rotated =
    { cred with token = sha256_hash raw_token
    ; created_at = now_iso ()
    ; expires_at = expires_at_for_auth_config auth_cfg } in
  publish_file_backed_credential_in_transaction transaction rotated ~raw_token
;;

let rotate_shared_tokens_matching config ~include_agent =
  with_credential_transaction config (fun transaction ->
    let ( let* ) = Result.bind in
    let* snapshot = credential_store_snapshot_in_transaction transaction in
    let* auth_cfg = credential_auth_config_result config in
    let groups = List.fold_left
        (fun groups (stored, (cred : agent_credential)) ->
          let entries = match List.assoc_opt cred.token groups with
              | Some entries -> entries
              | None -> [] in
            (cred.token, (stored, cred) :: entries) :: List.remove_assoc cred.token groups)
        [] snapshot.current_credentials in
    let groups = List.filter_map (fun (token_hash, entries) ->
      match entries with
      | [] | [ _ ] -> None
      | xs ->
        let selected = List.filter (fun (_, (credential : agent_credential)) ->
          include_agent credential.agent_name) xs in
        (match selected with
         | [] -> None
         | _ :: _ -> Some (token_hash_prefix_of token_hash,
             List.sort (fun (_, (a : agent_credential)) (_, b) ->
               String.compare a.agent_name b.agent_name) selected)))
        groups |> List.sort (fun (a, _) (b, _) -> String.compare a b) in
    (* Even an unselected legacy owner can name the selected UUID on a
       case-insensitive store. Enforce the canonical UUID/ownership contract
       for every current owner before any selected publisher writes. *)
    let* () = List.fold_left (fun checked (stored, credential) ->
      let* () = checked in
      let* _target = credential_owned_uuid_target config credential.agent_name stored credential in
      Ok ()) (Ok ()) snapshot.current_credentials in
    let rec validate targets = function
      | [] -> Ok ()
      | (_stored, credential) :: rest ->
        let* targets = match credential.id with
          | None -> Ok targets
          | Some id ->
            let target = credential_uuid_file config id in
            if String.equal target (credential_file config credential.agent_name) then
              Error (System (System_error.ValidationError
                (Printf.sprintf "cannot rotate %s: UUID payload and named redirect would share a path"
                  credential.agent_name)))
            else if List.exists (fun (_, (owner : agent_credential)) ->
              not (String.equal owner.agent_name credential.agent_name)
              && Option.equal Credential_id.equal owner.id credential.id)
                snapshot.current_credentials then
              Error (System (System_error.ValidationError
                (Printf.sprintf "cannot rotate %s: another current owner has the same UUID"
                  credential.agent_name)))
            else if List.mem target targets then
              Error (System (System_error.ValidationError
                (Printf.sprintf "cannot rotate %s: another selected owner would write the same UUID"
                  credential.agent_name)))
            else Ok (target :: targets) in
        validate targets rest in
    let* () = validate [] (List.concat_map snd groups) in
    Ok (List.map (fun (token_hash_prefix, entries) ->
      let rotated_agents = List.map (fun (_, (cred : agent_credential)) ->
        let raw_token = generate_token () in
        cred.agent_name, save_rotated_raw_token_in_transaction transaction ~auth_cfg cred ~raw_token) entries in
      { token_hash_prefix; rotated_agents }) groups))
  |> Result.join
;;

let rotate_shared_tokens config =
  rotate_shared_tokens_matching config ~include_agent:(fun _ -> true)
;;

let rotate_shared_tokens_for_agents config ~agent_names =
  let include_agent agent_name = List.exists (String.equal agent_name) agent_names in
  rotate_shared_tokens_matching config ~include_agent
;;

(* #9786: record bearer-token mismatch for observability.  Shared
   helper so both reject sites feed the same counter with the same
   label shape.  Non-mismatch rejects (no owner found at all) are
   NOT counted here — they have a different root cause. *)
let record_bearer_token_mismatch ~expected_agent ~actual_agent =
  Auth_metric_store.inc_counter
    Auth_metric_store.metric_auth_bearer_token_mismatch
    ~labels:[ "expected_agent", expected_agent; "actual_agent", actual_agent ]
    ()
;;

let bearer_token_owner_mismatch_message ~requested_agent ~token_owner =
  Printf.sprintf
    "No credential found for %s (bearer token belongs to %s). MCP identity mismatch: \
     mint/sync a bearer for %s (`masc login --agent %s --role worker --shell`, then \
     `sb mcp sync`) or send the token owner's identity."
    requested_agent
    token_owner
    requested_agent
    requested_agent
;;

(** Verify a token.

    Looks up the credential by exact [agent_name] match only. Generated
    nicknames may use a token owned by their stable prefix, but only when
    the supplied token itself resolves to that prefix. This keeps joined
    nickname continuity without letting an unrelated bearer token
    impersonate another generated family. Keeper transport aliases
    (keeper-<name>-agent) may use an existing stable keeper token only
    while no canonical alias credential exists. Once the canonical
    credential is bootstrapped, a different bare-owner token is stale
    dual-identity material and must not authenticate. *)
let verify_token_owner_alias config ~agent_name ~token =
  match find_credential_by_token config ~token with
  | Ok owner when String.equal owner.agent_name (credential_agent_name agent_name) ->
    Ok owner
  | Ok owner ->
    (* #9786: same mismatch counter as [missing_credential_error] —
         this path fires when no credential file exists for the
         requested agent but the presented token resolves to some
         other agent.  Equivalent operator signal. *)
    record_bearer_token_mismatch ~expected_agent:agent_name ~actual_agent:owner.agent_name;
    Error
      (Auth
         (Auth_error.Unauthorized
            { reason = Actor_mismatch
            ; message = bearer_token_owner_mismatch_message
                 ~requested_agent:agent_name
                 ~token_owner:owner.agent_name
            }))
  | Error e -> Error e
;;

let verify_token config ~agent_name ~token : (agent_credential, masc_error) result =
  match load_credential config agent_name with
  | None ->
    let ( let* ) = Result.bind in
    let* present = credential_path_exists (credential_file config agent_name) in
    if present then Error (Auth (Auth_error.InvalidToken
      "The exact credential exists but cannot be decoded; alias fallback is refused"))
    else (match Auth_oauth.find_access_credential ~base_path:config ~token with
     | Ok (Some credential) when String.equal credential.agent_name agent_name ->
       Ok credential
     | Ok (Some credential) ->
       record_bearer_token_mismatch
         ~expected_agent:agent_name
         ~actual_agent:credential.agent_name;
       Error
         (Auth
            (Auth_error.Unauthorized
               { reason = Actor_mismatch
               ; message =
                   bearer_token_owner_mismatch_message
                     ~requested_agent:agent_name
                     ~token_owner:credential.agent_name
               }))
     | Ok None -> verify_token_owner_alias config ~agent_name ~token
     | Error error -> Error error)
  | Some cred ->
    let token_hash = sha256_hash token in
    if not (constant_time_string_equal cred.token token_hash)
    then
      (match Auth_oauth.find_access_credential ~base_path:config ~token with
       | Ok (Some credential) when String.equal credential.agent_name agent_name ->
         Ok credential
       | Ok (Some credential) ->
         record_bearer_token_mismatch
           ~expected_agent:agent_name
           ~actual_agent:credential.agent_name;
         Error
           (Auth
              (Auth_error.Unauthorized
                 { reason = Actor_mismatch
                 ; message =
                     bearer_token_owner_mismatch_message
                       ~requested_agent:agent_name
                       ~token_owner:credential.agent_name
                 }))
       | Ok None -> Error (Auth (Auth_error.InvalidToken "Token mismatch"))
       | Error error -> Error error)
    else (
      let open Result.Syntax in
      let* credential = require_live_credential ~now:(Time_compat.now ()) cred in
      if credential_matches_live_disk config credential
      then Ok credential
      else Error (Auth (Auth_error.InvalidToken "Credential changed during token verification")))
;;
