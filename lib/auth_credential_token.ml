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
    if not (String.equal left.token right.token)
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
  Otel_metric_store.inc_counter
    Otel_metric_store.metric_auth_credential_hash_collision
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

(** Find credential by raw token (hash lookup + expiry check).

    #9786 runtime complement: when N>=2 credentials share the
    token hash, [List.find_opt] silently routed to the first
    match - the root of the [bearer token belongs to X]
    regression.  We now compare the full credential before
    treating two hash matches as equal; if the credentials differ,
    the lookup fails with [InvalidToken] and a structured collision
    event is emitted so operators can detect brute-force attempts.
    When N>=2 credentials are fully identical we still warn and
    increment {!Otel_metric_store.metric_auth_credential_ambiguous_lookup}
    so the duplicate-token audit path remains observable. *)
let find_credential_by_token config ~token : (agent_credential, masc_error) result =
  let token_hash = sha256_hash token in
  let idx = credential_token_index config in
  (* DET-OK: absent token hash is represented as an empty match list. *)
  let matches =
    Hashtbl.find_opt idx token_hash |> Option.value ~default:[]
  in
  match matches with
  | [] -> Error (Auth (Auth_error.InvalidToken "Token mismatch"))
  | first :: rest ->
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
       Otel_metric_store.inc_counter
         Otel_metric_store.metric_auth_credential_ambiguous_lookup
         ~labels:[ "first_match", first.agent_name ]
         ());
    (match check_credential_collisions ~token_hash_prefix:(token_hash_prefix_of token_hash) first rest with
     | Error e -> Error e
     | Ok () ->
       (match first.expires_at with
        | None -> Ok first
        | Some exp_str ->
          let now = now_iso () in
          if now > exp_str
          then Error (Auth (Auth_error.TokenExpired first.agent_name))
          else Ok first))
;;

(** Resolve agent_name from raw token *)
let resolve_agent_from_token config ~token : (string, masc_error) result =
  match find_credential_by_token config ~token with
  | Ok cred -> Ok cred.agent_name
  | Error e -> Error e
;;

let expires_at_for_auth_config auth_cfg =
  if auth_cfg.token_expiry_hours > 0
  then (
    let expiry =
      Time_compat.now ()
      +. (float_of_int auth_cfg.token_expiry_hours *. Masc_time_constants.hour)
    in
    Some (Masc_domain.iso8601_of_unix_seconds expiry))
  else None
;;

let save_raw_token_credential_with_expiry config ~agent_name ~role ~raw_token ~expires_at
  : (agent_credential, masc_error) result
  =
  let cred =
    { id = None
    ; agent_id = None
    ; agent_name
    ; token = sha256_hash raw_token
    ; role
    ; created_at = now_iso ()
    ; expires_at
    }
  in
  try
    save_credential config cred;
    Ok cred
  with
  | Eio.Cancel.Cancelled _ as e -> raise e
  | exn ->
    let msg =
      Printf.sprintf "Failed to save agent credential: %s" (Printexc.to_string exn)
    in
    Log.Auth.error "%s" msg;
    Error (System (System_error.IoError msg))
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

(** #10304: rotate shared bearer tokens detected by
    {!audit_token_uniqueness} into per-agent unique tokens.  Each
    agent in a shared group gets a fresh raw token so its persisted
    credential carries an unambiguous bearer.  Returns one
    [rotation_outcome] per group in audit order; per-agent results
    are reported individually so a single I/O failure does not abort
    the batch (the audit will still flag that agent on the next
    run). *)
type rotation_outcome =
  { token_hash_prefix : string
  ; rotated_agents : (string * (unit, masc_error) result) list
  }

let save_rotated_raw_token config (cred : agent_credential) ~raw_token
  : (agent_credential, masc_error) result
  =
  let auth_cfg = load_auth_config config in
  let rotated =
    { cred with
      token = sha256_hash raw_token
    ; created_at = now_iso ()
    ; expires_at = expires_at_for_auth_config auth_cfg
    }
  in
  try
    persist_raw_token config ~agent_name:rotated.agent_name raw_token;
    save_credential config rotated;
    Ok rotated
  with
  | Eio.Cancel.Cancelled _ as e -> raise e
  | exn ->
    let msg =
      Printf.sprintf
        "Failed to rotate agent credential for %s: %s"
        rotated.agent_name
        (Printexc.to_string exn)
    in
    Log.Auth.error "%s" msg;
    Error (System (System_error.IoError msg))
;;

let rotate_shared_tokens_matching config ~include_agent : rotation_outcome list =
  group_credentials_by_token config
  |> List.filter_map (fun (token_hash, entries) ->
    let entries =
      List.filter (fun (cred : agent_credential) -> include_agent cred.agent_name) entries
    in
    match entries with
    | [] | [ _ ] -> None
    | xs ->
      let prefix = token_hash_prefix_of token_hash in
      (* Sort by name so rotation order is stable across runs —
                operators diffing successive logs see no phantom
                reorderings. *)
      let sorted =
        List.sort
          (fun (a : agent_credential) (b : agent_credential) ->
             String.compare a.agent_name b.agent_name)
          xs
      in
      Some (prefix, sorted))
  |> List.sort (fun (a, _) (b, _) -> String.compare a b)
  |> List.map (fun (token_hash_prefix, sorted_entries) ->
    let rotated_agents =
      List.map
        (fun (cred : agent_credential) ->
           let raw_token = generate_token () in
           match save_rotated_raw_token config cred ~raw_token with
           | Ok _ -> cred.agent_name, Ok ()
           | Error e -> cred.agent_name, Error e)
        sorted_entries
    in
    { token_hash_prefix; rotated_agents })
;;

let rotate_shared_tokens config : rotation_outcome list =
  rotate_shared_tokens_matching config ~include_agent:(fun _ -> true)
;;

let rotate_shared_tokens_for_agents config ~agent_names : rotation_outcome list =
  let include_agent agent_name = List.exists (String.equal agent_name) agent_names in
  rotate_shared_tokens_matching config ~include_agent
;;

(* #9786: record bearer-token mismatch for observability.  Shared
   helper so both reject sites feed the same counter with the same
   label shape.  Non-mismatch rejects (no owner found at all) are
   NOT counted here — they have a different root cause. *)
let record_bearer_token_mismatch ~expected_agent ~actual_agent =
  Otel_metric_store.inc_counter
    Otel_metric_store.metric_auth_bearer_token_mismatch
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

let missing_credential_error config ~agent_name ~token : masc_error =
  match find_credential_by_token config ~token with
  | Ok owner when owner.agent_name <> agent_name ->
    record_bearer_token_mismatch ~expected_agent:agent_name ~actual_agent:owner.agent_name;
    Auth
      (Auth_error.Unauthorized
         { reason = Actor_mismatch
         ; message = bearer_token_owner_mismatch_message
              ~requested_agent:agent_name
              ~token_owner:owner.agent_name
         })
  | _ -> Auth (Auth_error.Unauthorized
      { reason = Missing_token
      ; message = "No credential found for " ^ agent_name
      })
;;

(** Verify a token.

    Looks up the credential by exact [agent_name] match only. Generated
    nicknames may use a token owned by their stable prefix, but only when
    the supplied token itself resolves to that prefix. This keeps joined
    nickname continuity without letting an unrelated bearer token
    impersonate another generated family. Keeper transport aliases
    (keeper-<name>-agent) additionally accept an existing stable keeper
    token even after an exact alias credential has been bootstrapped,
    because these aliases are transport identity, not separate runtime
    actors. *)
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
  | None -> verify_token_owner_alias config ~agent_name ~token
  | Some cred ->
    let token_hash = sha256_hash token in
    if cred.token <> token_hash
    then
      if Option.is_some (keeper_transport_alias_stable_name agent_name)
      then verify_token_owner_alias config ~agent_name ~token
      else Error (Auth (Auth_error.InvalidToken "Token mismatch"))
    else (
      (* Check expiry *)
      match cred.expires_at with
      | None -> Ok cred
      | Some exp_str ->
        (* Simple ISO string comparison works for UTC *)
        let now = now_iso () in
        if now > exp_str
        then Error (Auth (Auth_error.TokenExpired agent_name))
        else Ok cred)
;;
