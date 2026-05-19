(** See [auth_credential_store.mli] for the contract. *)

open Masc_domain

module Storage = Auth_storage
module Nickname_helpers = Auth_nickname

let trim_nonempty = Nickname_helpers.trim_nonempty
let agents_dir = Storage.agents_dir
let auth_dir = Storage.auth_dir
let file_exists = Storage.file_exists
let read_text_file = Storage.read_text_file
let read_dir = Storage.read_dir
let remove_file = Storage.remove_file
let ensure_auth_dirs = Storage.ensure_auth_dirs
let save_private_text_file = Storage.save_private_text_file

(** Get credential file path for an agent *)
let credential_file config agent_name =
  Filename.concat (agents_dir config) (agent_name ^ ".json")
;;

let raw_token_file config agent_name =
  Filename.concat (auth_dir config) (agent_name ^ ".token")
;;

(* Dashboard loopback dev-token was historically issued under
   [dashboard-dev] while the UI defaults to [dashboard]. Keep the old
   credential valid for [dashboard] requests so already-open browser
   sessions survive restarts and token-file migration. *)
let legacy_credential_aliases = function
  | "dashboard" -> [ "dashboard-dev" ]
  | _ -> []
;;

let load_credential_from_path config agent_name path : agent_credential option =
  if file_exists path
  then (
    try
      let content = read_text_file path in
      let json = Yojson.Safe.from_string content in
      match agent_credential_of_yojson json with
      | Ok cred -> Some cred
      | Error msg ->
        Log.Auth.warn "[load_credential] parse error for %s: %s" agent_name msg;
        None
    with
    | Sys_error _ | Yojson.Json_error _ -> None)
  else None
;;

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
  if file_exists path
  then (
    try
      let content = read_text_file path in
      let json = Yojson.Safe.from_string content in
      match agent_credential_of_yojson json with
      | Ok cred -> Some cred
      | Error msg ->
        Log.Auth.warn "[load_credential] parse error for %s: %s" agent_name msg;
        None
    with
    | Sys_error _ | Yojson.Json_error _ -> None)
  else None
;;

let credential_uuid_file config cid =
  Filename.concat (agents_dir config) (Credential_id.to_string cid ^ ".json")
;;

let redirect_target_file config target =
  if Filename.basename target = target && Filename.check_suffix target ".json"
  then Some (Filename.concat (agents_dir config) target)
  else None
;;

let load_redirect_target config path =
  if not (file_exists path)
  then None
  else (
    try
      match Yojson.Safe.from_string (read_text_file path) with
      | `Assoc fields ->
        (match List.assoc_opt "redirect_to" fields with
         | Some (`String target) -> redirect_target_file config target
         | _ -> None)
      | _ -> None
    with
    | Sys_error _ | Yojson.Json_error _ -> None)
;;

let remove_file_if_exists path = if file_exists path then remove_file path

let load_credential config agent_name : agent_credential option =
  let file = credential_file config agent_name in
  if not (file_exists file)
  then None
  else (
    try
      let content = read_text_file file in
      let json = Yojson.Safe.from_string content in
      (* Redirect stub: { "redirect_to": "<uuid>.json" } — single
         [List.assoc_opt] walk replaces the [mem_assoc + assoc] pair
         (two passes, second raises [Not_found]). *)
      match json with
      | `Assoc fields ->
        (match List.assoc_opt "redirect_to" fields with
         | Some (`String target) ->
           (match redirect_target_file config target with
            | Some redirect_path ->
              load_credential_from_path_raw config agent_name redirect_path
            | None -> None)
         | Some _ -> None
         | None -> load_credential_from_path_raw config agent_name file)
      | _ -> load_credential_from_path_raw config agent_name file
    with
    | Sys_error _ | Yojson.Json_error _ -> None)
;;

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
         agent_name
         cred.agent_name
         (String.concat ";" aliases)
     | None -> ());
    result
;;

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
  match cred.id with
  | Some cid ->
    let uuid_file = credential_uuid_file config cid in
    (match previous_target with
     | Some old_file when old_file <> uuid_file -> remove_file_if_exists old_file
     | _ -> ());
    save_private_text_file uuid_file json_str;
    let stub =
      `Assoc [ "redirect_to", `String (Credential_id.to_string cid ^ ".json") ]
    in
    save_private_text_file stub_file (Yojson.Safe.pretty_to_string stub)
  | None ->
    Option.iter remove_file_if_exists previous_target;
    save_private_text_file stub_file json_str
;;

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
let ensure_credential_alias config ~canonical_name ~alias_name : (unit, masc_error) result
  =
  if String.equal canonical_name alias_name
  then Ok ()
  else (
    let canonical_file = credential_file config canonical_name in
    if not (file_exists canonical_file)
    then
      Error
        (System
           (System_error.IoError
              (Printf.sprintf
                 "canonical credential not found for alias setup: canonical=%s alias=%s"
                 canonical_name
                 alias_name)))
    else (
      match load_redirect_target config canonical_file with
      | None ->
        Error
          (System
             (System_error.IoError
                (Printf.sprintf
                   "canonical credential %s is not a redirect stub; cannot create alias \
                    %s without a UUID-backed credential"
                   canonical_name
                   alias_name)))
      | Some uuid_file ->
        let uuid_basename = Filename.basename uuid_file in
        let alias_file = credential_file config alias_name in
        let desired_stub = `Assoc [ "redirect_to", `String uuid_basename ] in
        let already_correct =
          match load_redirect_target config alias_file with
          | Some existing when Filename.basename existing = uuid_basename -> true
          | _ -> false
        in
        if already_correct
        then Ok ()
        else (
          try
            ensure_auth_dirs config;
            save_private_text_file alias_file (Yojson.Safe.pretty_to_string desired_stub);
            Ok ()
          with
          | Eio.Cancel.Cancelled _ as e -> raise e
          | exn ->
            Error
              (System
                 (System_error.IoError
                    (Printf.sprintf
                       "Failed to write alias %s -> %s: %s"
                       alias_name
                       canonical_name
                       (Printexc.to_string exn)))))))
;;

let load_raw_token config ~agent_name =
  let file = raw_token_file config agent_name in
  if file_exists file
  then (
    try read_text_file file |> trim_nonempty with
    | Sys_error _ -> None)
  else None
;;

let persist_raw_token config ~agent_name raw_token =
  ensure_auth_dirs config;
  save_private_text_file (raw_token_file config agent_name) raw_token
;;

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
;;

(** List all credentials.

    De-duplicates by [agent_name] so that a UUID-backed credential
    plus its redirect stub do not appear twice in the result. *)
let list_credentials config : agent_credential list =
  let dir = agents_dir config in
  if file_exists dir
  then
    read_dir dir
    |> Array.to_list
    |> List.filter (fun f -> Filename.check_suffix f ".json")
    |> List.filter_map (fun f ->
      let name = Filename.chop_suffix f ".json" in
      load_credential config name)
    |> List.fold_left
         (fun acc cred ->
            if List.exists (fun c -> c.agent_name = cred.agent_name) acc
            then acc
            else cred :: acc)
         []
    |> List.rev
  else []
;;
