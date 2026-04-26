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

let auth_dir config = Common.auth_dir_from_base_path ~base_path:config
let agents_dir config = Common.agents_dir_from_base_path ~base_path:config
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

let nickname_adjectives = [|
  "swift"; "brave"; "calm"; "eager"; "fierce";
  "gentle"; "happy"; "jolly"; "keen"; "lucky";
  "merry"; "noble"; "proud"; "quick"; "witty";
  "bold"; "cool"; "deft"; "fair"; "grand";
  "hale"; "jade"; "kind"; "lean"; "neat";
  "pale"; "rare"; "sage"; "tame"; "warm";
|]

let nickname_animals = [|
  "fox"; "bear"; "wolf"; "hawk"; "lion";
  "tiger"; "eagle"; "otter"; "panda"; "koala";
  "raven"; "falcon"; "badger"; "beaver"; "whale";
  "shark"; "crane"; "heron"; "moose"; "viper";
  "cobra"; "gecko"; "lemur"; "llama"; "manta";
  "orca"; "rhino"; "sloth"; "tapir"; "zebra";
|]

let array_contains arr value =
  let rec loop idx =
    idx < Array.length arr
    && (String.equal arr.(idx) value || loop (idx + 1))
  in
  loop 0

let is_hex4 value =
  String.length value = 4
  && String.for_all
       (function
         | '0' .. '9' | 'a' .. 'f' -> true
         | _ -> false)
       value

let extract_generated_nickname_prefix name =
  let parts = String.split_on_char '-' name in
  let join_prefix prefix_rev =
    match List.rev prefix_rev with
    | [] -> None
    | prefix -> String.concat "-" prefix |> trim_nonempty
  in
  match List.rev parts with
  | animal :: adjective :: prefix_rev
    when array_contains nickname_animals animal
         && array_contains nickname_adjectives adjective ->
      join_prefix prefix_rev
  | suffix :: animal :: adjective :: prefix_rev
    when is_hex4 suffix
         && array_contains nickname_animals animal
         && array_contains nickname_adjectives adjective ->
      join_prefix prefix_rev
  | prefix :: _ when prefix <> "" -> Some prefix
  | _ -> None

(* Inline copy of Nickname.is_generated_nickname / extract_agent_type.
   Auth lives below masc_coord in the module graph and cannot depend on
   it. The nickname pattern — stable-prefix + adjective + animal
   [+ hex4] — is duplicated here so auth can canonicalize generated
   aliases without depending on Nickname. Keeper aliases use a
   different canonical shape
   (keeper-<name>-agent) and must resolve to the middle segment so
   keeper-scoped credentials can be stored under the stable keeper name
   rather than the transport alias. Covered by the nickname fallback
   tests. *)
let is_generated_nickname_shape name =
  List.length (String.split_on_char '-' name) >= 3

let keeper_transport_alias_stable_name name =
  match String.split_on_char '-' name with
  | "keeper" :: rest -> (
      match List.rev rest with
      | "agent" :: middle_rev ->
          List.rev middle_rev
          |> String.concat "-"
          |> trim_nonempty
      | _ -> None)
  | _ -> None

let extract_agent_type_prefix name =
  match keeper_transport_alias_stable_name name with
  | Some stable_name -> Some stable_name
  | None -> (
      match String.split_on_char '-' name with
      | "keeper" :: _ -> Some "keeper"
      | _ -> extract_generated_nickname_prefix name)

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
let load_credential_from_path_raw config agent_name path : agent_credential option =
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

let credential_uuid_file config cid =
  Filename.concat (agents_dir config) (Credential_id.to_string cid ^ ".json")

let redirect_target_file config target =
  if Filename.basename target = target && Filename.check_suffix target ".json" then
    Some (Filename.concat (agents_dir config) target)
  else
    None

let load_redirect_target config path =
  if not (file_exists path) then
    None
  else
    try
      match Yojson.Safe.from_string (read_text_file path) with
      | `Assoc fields -> (
          match List.assoc_opt "redirect_to" fields with
          | Some (`String target) -> redirect_target_file config target
          | _ -> None)
      | _ -> None
    with Sys_error _ | Yojson.Json_error _ -> None

let remove_file_if_exists path =
  if file_exists path then remove_file path

let load_credential config agent_name : agent_credential option =
  let file = credential_file config agent_name in
  if not (file_exists file) then None
  else
    try
      let content = read_text_file file in
      let json = Yojson.Safe.from_string content in
      (* Redirect stub: { "redirect_to": "<uuid>.json" } *)
      match json with
      | `Assoc fields when List.mem_assoc "redirect_to" fields -> (
          match List.assoc "redirect_to" fields with
          | `String target -> (
              match redirect_target_file config target with
              | Some redirect_path ->
                  load_credential_from_path_raw config agent_name redirect_path
              | None -> None)
          | _ -> None)
      | _ -> load_credential_from_path_raw config agent_name file
    with Sys_error _ | Yojson.Json_error _ -> None

let load_credential_with_aliases config agent_name : agent_credential option =
  match load_credential config agent_name with
  | Some _ as c -> c
  | None ->
      let aliases = legacy_credential_aliases agent_name in
      let result = List.find_map (load_credential config) aliases in
      (match result with
       | Some cred ->
           (* Observability for RFC P2-b: every silent alias-fallback hit
              indicates a dual-identity caller (e.g. requested
              [keeper-sangsu-agent] while only bare [sangsu] credential
              exists, or vice versa). The fallback preserves availability
              by routing to the legacy credential, but [cred.agent_name]
              reveals the file the request was served from — different
              from the requested name. P2-a's [load_credential_of]
              surfaces this as [Credential_mismatch]; this warn measures
              how often the legacy fallback is still load-bearing while
              migrations are in flight. *)
           Log.Auth.warn
             "[identity_drift:alias_fallback] requested=%s resolved=%s aliases_tried=[%s]"
             agent_name cred.agent_name (String.concat ";" aliases)
       | None -> ());
      result

type load_credential_error =
  | Credential_missing of { ctx_agent_name : string }
  | Credential_mismatch of {
      ctx_agent_name : string;
      resolved_credential_stem : string;
    }

let pp_load_credential_error fmt = function
  | Credential_missing { ctx_agent_name } ->
      Format.fprintf fmt
        "Credential_missing { ctx_agent_name = %S }" ctx_agent_name
  | Credential_mismatch { ctx_agent_name; resolved_credential_stem } ->
      Format.fprintf fmt
        "Credential_mismatch { ctx_agent_name = %S; resolved_credential_stem \
         = %S }"
        ctx_agent_name resolved_credential_stem

let show_load_credential_error err =
  Format.asprintf "%a" pp_load_credential_error err

let load_credential_of config ~ctx_agent_name ~resolved_credential_stem :
    (agent_credential, load_credential_error) result =
  if String.equal resolved_credential_stem ctx_agent_name then
    match load_credential config ctx_agent_name with
    | Some cred -> Ok cred
    | None -> Error (Credential_missing { ctx_agent_name })
  else
    Error
      (Credential_mismatch { ctx_agent_name; resolved_credential_stem })

(** Save agent credential.

    When [cred.id] is present the credential is stored under
    [{uuid}.json] and a redirect stub [{agent_name}.json] is written so
    legacy lookup paths still resolve. *)
let save_credential config (cred : agent_credential) =
  ensure_auth_dirs config;
  let json = agent_credential_to_yojson cred in
  let json_str = Yojson.Safe.pretty_to_string json in
  let stub_file = credential_file config cred.agent_name in
  let previous_target = load_redirect_target config stub_file in
  (match cred.id with
  | Some cid ->
      let uuid_file = credential_uuid_file config cid in
      (match previous_target with
       | Some old_file when old_file <> uuid_file -> remove_file_if_exists old_file
       | _ -> ());
      save_private_text_file uuid_file json_str;
      let stub = `Assoc [("redirect_to", `String (Credential_id.to_string cid ^ ".json"))] in
      save_private_text_file stub_file (Yojson.Safe.pretty_to_string stub)
  | None ->
      Option.iter remove_file_if_exists previous_target;
      save_private_text_file stub_file json_str)

(** #10440: write a short-form alias [<alias_name>.json] as a
    redirect stub pointing at the same UUID file as
    [<canonical_name>.json].

    Issue #10440 documented credential file asymmetry: 6/14
    keepers had a short-form [<keeper>.json] (created via some
    other path) and 8/14 had only the long-form
    [keeper-<n>-agent.json]. Callers that look up by
    [agent_name=<keeper>] hit ENOENT for the 8 long-form-only
    keepers, which is the [feedback_keeper-credential-name-drift]
    fail mode. This helper writes the short-form alias once at
    bootstrap so all 14 keepers resolve via a single
    [load_credential] call.

    Idempotent: pre-existing alias with the same redirect target
    is a no-op; a stale alias pointing elsewhere is overwritten so
    operators can recover from manual file edits.

    Returns [Error] if the canonical credential is itself a
    direct (non-redirect) credential, since "alias" semantics
    require both sides to share the same UUID file. *)
let ensure_credential_alias config ~canonical_name ~alias_name :
    (unit, masc_error) result =
  if String.equal canonical_name alias_name then Ok ()
  else
    let canonical_file = credential_file config canonical_name in
    if not (file_exists canonical_file) then
      Error
        (IoError
           (Printf.sprintf
              "canonical credential not found for alias setup: \
               canonical=%s alias=%s"
              canonical_name alias_name))
    else
      match load_redirect_target config canonical_file with
      | None ->
          Error
            (IoError
               (Printf.sprintf
                  "canonical credential %s is not a redirect stub; \
                   cannot create alias %s without a UUID-backed \
                   credential"
                  canonical_name alias_name))
      | Some uuid_file ->
          let uuid_basename = Filename.basename uuid_file in
          let alias_file = credential_file config alias_name in
          let desired_stub =
            `Assoc [ ("redirect_to", `String uuid_basename) ]
          in
          let already_correct =
            match load_redirect_target config alias_file with
            | Some existing when Filename.basename existing = uuid_basename ->
                true
            | _ -> false
          in
          if already_correct then Ok ()
          else
            (try
               ensure_auth_dirs config;
               save_private_text_file alias_file
                 (Yojson.Safe.pretty_to_string desired_stub);
               Ok ()
             with
             | Eio.Cancel.Cancelled _ as e -> raise e
             | exn ->
                 Error
                   (IoError
                      (Printf.sprintf
                         "Failed to write alias %s -> %s: %s"
                         alias_name canonical_name
                         (Printexc.to_string exn))))

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
  let redirect_target = load_redirect_target config file in
  let credential_target =
    match load_credential config agent_name with
    | Some { id = Some cid; _ } -> Some (credential_uuid_file config cid)
    | _ -> None
  in
  remove_file_if_exists file;
  Option.iter remove_file_if_exists redirect_target;
  Option.iter remove_file_if_exists credential_target

(** List all credentials.

    De-duplicates by [agent_name] so that a UUID-backed credential
    plus its redirect stub do not appear twice in the result. *)
let list_credentials config : agent_credential list =
  let dir = agents_dir config in
  if file_exists dir then
    read_dir dir
    |> Array.to_list
    |> List.filter (fun f -> Filename.check_suffix f ".json")
    |> List.filter_map (fun f ->
        let name = Filename.chop_suffix f ".json" in
        load_credential config name)
    |> List.fold_left
         (fun acc cred ->
            if List.exists (fun c -> c.agent_name = cred.agent_name) acc then
              acc
            else
              cred :: acc)
         []
    |> List.rev
  else
    []

(** #9786: detect credentials sharing the same bearer token.

    The 2026-04-23 audit found [codex-mcp-client] and [admin]
    tokens being presented for [keeper-sangsu-agent] /
    [nick0cave-sage-heron] requests — symptom of multiple
    credentials hashing to the same token, or a single MCP
    client connection being reused across agent identities.

    [find_credential_by_token]'s [List.find_opt] returns the FIRST
    matching credential, so when two credentials share a token the
    second agent's auth silently routes to the first agent's
    identity — which is exactly the [bearer token belongs to X]
    rejection observed in #9786 once the requested name does not
    match the routed credential's owner.

    This audit walks the credential store and returns groups of
    [(token_hash_prefix, agent_names)] where [List.length
    agent_names >= 2].  Empty list means every credential's token
    hash is unique. *)
(** #10304: indexed credential view used by both
    {!audit_token_uniqueness} (detection) and {!rotate_shared_tokens}
    (prevention).  Returns [(token_hash, credentials)] so rotation
    can preserve credential IDs / roles while minting fresh bearer
    material. *)
let group_credentials_by_token config : (string * agent_credential list) list =
  let creds = list_credentials config in
  let by_token : (string, agent_credential list) Hashtbl.t = Hashtbl.create 16 in
  List.iter
    (fun (cred : agent_credential) ->
      let prev =
        Hashtbl.find_opt by_token cred.token |> Option.value ~default:[]
      in
      Hashtbl.replace by_token cred.token (cred :: prev))
    creds;
  Hashtbl.fold
    (fun token_hash entries acc -> (token_hash, entries) :: acc)
    by_token []

let token_hash_prefix_of token_hash =
  if String.length token_hash >= 12 then String.sub token_hash 0 12
  else token_hash

let audit_token_uniqueness config : (string * string list) list =
  group_credentials_by_token config
  |> List.filter_map (fun (token_hash, entries) ->
         match entries with
         | [] | [ _ ] -> None
         | xs ->
             let names =
               List.map (fun (cred : agent_credential) -> cred.agent_name) xs
               |> List.sort String.compare
             in
             Some (token_hash_prefix_of token_hash, names))
  |> List.sort (fun (a, _) (b, _) -> String.compare a b)

(* #10304: rotation_outcome type + rotate_shared_tokens defined
   later in the file (after save_raw_token_credential).  This block
   intentionally left as a forward-pointer comment so the audit and
   rotation surfaces are co-located in the API but the
   implementation respects definition order. *)

(** Find credential by raw token (hash lookup + expiry check).

    #9786 runtime complement: when N>=2 credentials share the
    token hash, [List.find_opt] silently routed to the first
    match - the root of the [bearer token belongs to X]
    regression.  We keep the legacy first-match return so
    existing callers do not need migration, but we WARN and
    increment {!Prometheus.metric_auth_credential_ambiguous_lookup}
    so an alert can fire on the live blast radius rather than
    just the one-shot boot audit. *)
let find_credential_by_token config ~token : (agent_credential, masc_error) result =
  let token_hash = sha256_hash token in
  let matches =
    List.filter (fun cred -> cred.token = token_hash)
      (list_credentials config)
  in
  match matches with
  | [] -> Error (InvalidToken "Token mismatch")
  | first :: rest ->
      (match rest with
       | [] -> ()
       | _ :: _ ->
           let names =
             List.map
               (fun (c : agent_credential) -> c.agent_name)
               matches
           in
           Log.Misc.warn
             "auth: token shared by %d agents [%s] - routing to %s \
              (first match); rotate via Auth.create_token to disambiguate \
              (#9786)"
             (List.length matches)
             (String.concat ", " names)
             first.agent_name;
           Prometheus.inc_counter
             Prometheus.metric_auth_credential_ambiguous_lookup
             ~labels:[ ("first_match", first.agent_name) ]
             ());
      (match first.expires_at with
       | None -> Ok first
       | Some exp_str ->
           let now = now_iso () in
           if now > exp_str then Error (TokenExpired first.agent_name)
           else Ok first)

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
      id = None;
      agent_id = None;
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

(** #10304: rotate shared bearer tokens detected by
    {!audit_token_uniqueness} into per-agent unique tokens.  Each
    agent in a shared group gets a fresh raw token so its persisted
    credential carries an unambiguous bearer.  Returns one
    [rotation_outcome] per group in audit order; per-agent results
    are reported individually so a single I/O failure does not abort
    the batch (the audit will still flag that agent on the next
    run). *)
type rotation_outcome = {
  token_hash_prefix : string;
  rotated_agents : (string * (unit, masc_error) result) list;
}

let save_rotated_raw_token config (cred : agent_credential) ~raw_token :
    (agent_credential, masc_error) result =
  let auth_cfg = load_auth_config config in
  let rotated =
    {
      cred with
      token = sha256_hash raw_token;
      created_at = now_iso ();
      expires_at = expires_at_for_auth_config auth_cfg;
    }
  in
  try
    persist_raw_token config ~agent_name:rotated.agent_name raw_token;
    save_credential config rotated;
    Ok rotated
  with Eio.Cancel.Cancelled _ as e -> raise e | exn ->
    let msg =
      Printf.sprintf "Failed to rotate agent credential for %s: %s"
        rotated.agent_name (Printexc.to_string exn)
    in
    Log.Auth.error "%s" msg;
    Error (IoError msg)

let rotate_shared_tokens_matching config ~include_agent : rotation_outcome list =
  group_credentials_by_token config
  |> List.filter_map (fun (token_hash, entries) ->
         let entries =
           List.filter
             (fun (cred : agent_credential) -> include_agent cred.agent_name)
             entries
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
               | Ok _ -> (cred.agent_name, Ok ())
               | Error e -> (cred.agent_name, Error e))
             sorted_entries
         in
         { token_hash_prefix; rotated_agents })

let rotate_shared_tokens config : rotation_outcome list =
  rotate_shared_tokens_matching config ~include_agent:(fun _ -> true)

let rotate_shared_tokens_for_agents config ~agent_names : rotation_outcome list =
  let include_agent agent_name =
    List.exists (String.equal agent_name) agent_names
  in
  rotate_shared_tokens_matching config ~include_agent

(* #9786: record bearer-token mismatch for observability.  Shared
   helper so both reject sites feed the same counter with the same
   label shape.  Non-mismatch rejects (no owner found at all) are
   NOT counted here — they have a different root cause. *)
let record_bearer_token_mismatch ~expected_agent ~actual_agent =
  Prometheus.inc_counter
    Prometheus.metric_auth_bearer_token_mismatch
    ~labels:[
      ("expected_agent", expected_agent);
      ("actual_agent", actual_agent);
    ]
    ()

let missing_credential_error config ~agent_name ~token : masc_error =
  match find_credential_by_token config ~token with
  | Ok owner when owner.agent_name <> agent_name ->
      record_bearer_token_mismatch
        ~expected_agent:agent_name ~actual_agent:owner.agent_name;
      Unauthorized
        (Printf.sprintf
           "No credential found for %s (bearer token belongs to %s)"
           agent_name owner.agent_name)
  | _ -> Unauthorized ("No credential found for " ^ agent_name)

(** Verify a token.

    Looks up the credential by exact [agent_name] match first. If that
    misses, hard-coded legacy aliases (dashboard → dashboard-dev) are
    accepted. Generated nicknames may also use a token owned by their
    stable prefix, but only when the supplied token itself resolves to
    that prefix. This keeps joined nickname continuity without letting an
    unrelated bearer token impersonate another generated family. Keeper
    transport aliases (keeper-<name>-agent) additionally accept an
    existing stable keeper token even after an exact alias credential has
    been bootstrapped, because these aliases are transport identity, not
    separate runtime actors. *)
let verify_token_owner_alias config ~agent_name ~token =
  match find_credential_by_token config ~token with
  | Ok owner when String.equal owner.agent_name (credential_agent_name agent_name) ->
      Ok owner
  | Ok owner ->
      (* #9786: same mismatch counter as [missing_credential_error] —
         this path fires when no credential file exists for the
         requested agent but the presented token resolves to some
         other agent.  Equivalent operator signal. *)
      record_bearer_token_mismatch
        ~expected_agent:agent_name ~actual_agent:owner.agent_name;
      Error
        (Unauthorized
           (Printf.sprintf
              "No credential found for %s (bearer token belongs to %s)"
              agent_name owner.agent_name))
  | Error e -> Error e

let verify_token config ~agent_name ~token : (agent_credential, masc_error) result =
  let cred_opt =
    match load_credential config agent_name with
    | Some _ as c -> c
    | None ->
        legacy_credential_aliases agent_name
        |> List.find_map (load_credential config)
  in
  match cred_opt with
  | None -> verify_token_owner_alias config ~agent_name ~token
  | Some cred ->
      let token_hash = sha256_hash token in
      if cred.token <> token_hash then
        if Option.is_some (keeper_transport_alias_stable_name agent_name) then
          verify_token_owner_alias config ~agent_name ~token
        else
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
  ignore (ensure_internal_keeper_token config);
  let existing = load_credential config agent_name in
  let create_fresh_keeper_token () =
    let raw_token = generate_token () in
    let id, agent_id =
      match existing with
      | Some cred ->
          ( (match cred.id with Some id -> id | None -> Credential_id.generate ()),
            cred.agent_id )
      | None -> (Credential_id.generate (), None)
    in
    let cred =
      {
        id = Some id;
        agent_id;
        agent_name;
        token = sha256_hash raw_token;
        role = Worker;
        created_at = now_iso ();
        expires_at = None;
      }
    in
    persist_raw_token config ~agent_name raw_token;
    save_credential config cred;
    (raw_token, cred)
  in
  try
    match load_raw_token config ~agent_name with
    | Some raw_token -> (
        match verify_token config ~agent_name ~token:raw_token with
        | Ok cred when String.equal cred.agent_name agent_name ->
            Ok (raw_token, cred)
        | Ok _ | Error _ -> Ok (create_fresh_keeper_token ()))
    | None -> Ok (create_fresh_keeper_token ())
  with Eio.Cancel.Cancelled _ as e -> raise e | exn ->
    let msg =
      Printf.sprintf "Failed to save keeper credential: %s"
        (Printexc.to_string exn)
    in
    Log.Auth.error "%s" msg;
    Error (IoError msg)

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
    - 1/true: unknown internal tools require at least worker-level permission *)
let is_tool_auth_strict_enabled () =
  Env_config_core.tool_auth_strict ()

(* #10205 finding 1: SSOT for the internal-tool prefix vocabulary.
   Adding a new internal namespace (e.g. [foo.]) was previously a
   two-predicate edit ([is_masc_tool_name] +
   [is_protocol_canonical_tool_name]) glued by a [||] chain at the
   call site.  Keep the prefixes in one list so the next addition
   is a single edit; predicate identity does not matter to callers,
   which only consume {!is_unmapped_internal_tool_name}.

   Keeper runtime tools are NOT a prefix: a [keeper_*] prefix
   alone is not enough to cross auth — the catalog must own the
   tool.  That check stays separate. *)
let internal_tool_prefixes = [
  "masc_";
  "decision.";
  "experiment.";
  "client.";
]

let has_internal_tool_prefix tool_name =
  List.exists
    (fun pref -> String.starts_with ~prefix:pref tool_name)
    internal_tool_prefixes

let is_unmapped_internal_tool_name tool_name =
  has_internal_tool_prefix tool_name
  || Tool_catalog.is_on_surface Tool_catalog.Keeper_internal tool_name

let unknown_tool_class tool_name =
  if String.trim tool_name = "" then "empty" else "external"

let record_strict_unknown_tool_denial ~agent_name ~tool_name =
  Prometheus.inc_counter
    Prometheus.metric_auth_strict_unknown_tool_denials
    ~labels:
      [ ("agent_name", agent_name); ("tool_class", unknown_tool_class tool_name) ]
    ()

(** Check permission for a tool call *)
let authorize_tool config ~agent_name ~token ~tool_name : (unit, masc_error) result =
  match permission_for_tool tool_name with
  | None ->
      if not (is_tool_auth_strict_enabled ()) then
        Ok ()  (* Legacy fail-open *)
      else if is_unmapped_internal_tool_name tool_name then
        (* Conservative default in strict mode for unmapped internal tools. *)
        check_permission config ~agent_name ~token ~permission:CanBroadcast
      else
        let () = record_strict_unknown_tool_denial ~agent_name ~tool_name in
        Error
          (Forbidden
             {
               agent = agent_name;
               action = "use unknown non-masc tool: " ^ tool_name;
             })
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
        if is_unmapped_internal_tool_name tool_name then
          (* Unmapped internal tool: require at least Worker *)
          if has_permission role CanBroadcast then Ok ()
          else Error (Forbidden { agent = agent_name; action = tool_name })
        else
          let () = record_strict_unknown_tool_denial ~agent_name ~tool_name in
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
    checks — unmapped internal tools require at least Worker, and
    unmapped external tools are forbidden. *)
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
