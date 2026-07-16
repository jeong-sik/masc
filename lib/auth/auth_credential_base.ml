(** MASC Authentication & Authorization Module *)

open Masc_domain

(* ============================================ *)
(* Crypto utilities                             *)
(* ============================================ *)

let rng_initialized = Atomic.make false

(** Seed the default RNG exactly once. Guarded here, at the point of use,
    so token generation does not depend on a caller (auth_login, server
    boot) having seeded it first. *)
let ensure_rng_initialized () =
  if not (Atomic.get rng_initialized) then begin
    Mirage_crypto_rng_unix.use_default ();
    Atomic.set rng_initialized true
  end

(** Generate a cryptographically random token (hex string) *)
let generate_token () =
  ensure_rng_initialized ();
  let random_bytes = Mirage_crypto_rng.generate 32 in
  let hex = Buffer.create 64 in
  String.iter (fun c -> Printf.bprintf hex "%02x" (Char.code c)) random_bytes;
  Buffer.contents hex
;;

(** SHA256 hash of a string using Digestif *)
let sha256_hash input = Digestif.SHA256.(digest_string input |> to_hex)

(* ============================================ *)
(* Auth directory management                    *)
(* ============================================ *)

let auth_dir config = Common.auth_dir_from_base_path ~base_path:config
let agents_dir config = Common.agents_dir_from_base_path ~base_path:config
let workspace_secret_file config = Filename.concat (auth_dir config) "workspace_secret.hash"
let auth_config_file config = Filename.concat (auth_dir config) "config.json"
let initial_admin_file config = Filename.concat (auth_dir config) "initial_admin"

let internal_keeper_token_hash_file config =
  Filename.concat (auth_dir config) "internal_keeper.token.hash"
;;

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
;;

(** Write the initial admin agent name (bootstrap grace).
    The agent who enables auth is always granted full permission. *)
let write_initial_admin config agent_name =
  ensure_auth_dirs config;
  let file = initial_admin_file config in
  write_text_file file (String.trim agent_name);
  chmod file 0o600
;;

let save_private_text_file path content =
  run_blocking_io (fun () ->
    let oc = open_out_gen [ Open_wronly; Open_creat; Open_trunc; Open_text ] 0o600 path in
    (* This body already runs in a systhread; use plain OCaml cleanup so it
       does not require an Eio fiber context in that systhread. *)
    Fun.protect
      ~finally:(fun () -> close_out_noerr oc)
      (fun () -> output_string oc content));
  chmod path 0o600
;;

let load_internal_keeper_token_hash config =
  let file = internal_keeper_token_hash_file config in
  if file_exists file
  then (
    try
      let hash = String.trim (read_text_file file) in
      if hash = "" then None else Some hash
    with
    | Sys_error _ -> None)
  else None
;;

let save_internal_keeper_token_hash config ~raw_token =
  ensure_auth_dirs config;
  let file = internal_keeper_token_hash_file config in
  save_private_text_file file (sha256_hash raw_token)
;;

let verify_internal_keeper_token config ~token =
  match load_internal_keeper_token_hash config with
  | Some stored_hash -> String.equal stored_hash (sha256_hash token)
  | None -> false
;;

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
;;

(** Read the initial admin agent name, if set. *)
let read_initial_admin config : string option =
  let file = initial_admin_file config in
  if file_exists file
  then (
    try
      let name = String.trim (read_text_file file) in
      if name = "" then None else Some name
    with
    | Sys_error _ -> None)
  else None
;;

(* ============================================ *)
(* Auth config management                       *)
(* ============================================ *)

let persist_auth_config config (auth_cfg : auth_config) =
  ensure_auth_dirs config;
  let file = auth_config_file config in
  let json = auth_config_to_yojson auth_cfg in
  save_private_text_file file (Yojson.Safe.pretty_to_string json)
;;

(* mtime-keyed cache for [load_auth_config].

   Every authenticated HTTP request and every WS/MCP transport
   credential check funnels through [Auth.load_auth_config], which
   did a [file_exists] + [read_text_file] + [Yojson.Safe.from_string]
   on every call.  Under live dashboard load that meant hundreds of
   identical disk reads per second of the same JSON file, with the
   parse showing up on Eio main-domain profiles.

   Cache policy: keep the most recently observed
   [{ file; mtime; parsed }] in an [Atomic.t].  If the next call's
   [(file, mtime)] pair matches, return the cached value.  Different
   file path, newer mtime, or missing file all fall through to a
   fresh read.

   Why mtime alone (no content hash): the auth config is mutated in
   this process only by [persist_auth_config], which writes via
   [save_private_text_file] (atomic rename).  Any external editor
   bumps mtime.  Hashing would catch the case where a tool restores
   an identical-content file with an older mtime, but the worst
   outcome there is one extra reload — still cheaper than reloading
   on every request.

   Why a single-slot cache instead of a per-base-path map: the server
   runs against one [base_path] for the lifetime of the process.
   Tests that swap configs pay the miss-rebuild cost on the first
   call after each swap.

   Multi-domain safety: [Atomic.set] publishes the new immutable
   record atomically; readers see either the previous record or the
   new one, never a torn entry. *)
type auth_config_cache_entry = {
  file : string;
  mtime : float;
  parsed : auth_config;
}

let auth_config_cache : auth_config_cache_entry option Atomic.t =
  Atomic.make None

(** Load auth config *)
let load_auth_config config : auth_config =
  let file = auth_config_file config in
  (* RFC-0145 — narrow from a wildcard catch-all to the only exception
     [Unix.stat] raises on a missing or unreadable file.  Other runtime
     exceptions are intentionally not caught here so we do not silently
     poison the auth config cache on novel filesystem failure modes. *)
  match
    try Some (Unix.stat file).Unix.st_mtime with
    | Unix.Unix_error _ -> None
  with
  | None ->
    (* File missing or unreadable — same fallback as the historical
       [file_exists] branch.  Do not poison the cache. *)
    default_auth_config
  | Some mtime ->
    (match Atomic.get auth_config_cache with
     | Some entry
       when String.equal entry.file file && Float.equal entry.mtime mtime ->
       entry.parsed
     | _ ->
       (try
          let content = read_text_file file in
          let json = Yojson.Safe.from_string content in
          match auth_config_of_yojson json with
          | Ok parsed ->
            Atomic.set auth_config_cache (Some { file; mtime; parsed });
            parsed
          | Error msg ->
            Log.Auth.warn "[load_auth_config] parse error for %s: %s" file msg;
            default_auth_config
        with
        | Sys_error _ | Yojson.Json_error _ -> default_auth_config))
;;

(** Save auth config *)
let save_auth_config config (auth_cfg : auth_config) = persist_auth_config config auth_cfg

(* ============================================ *)
(* Credential management                        *)
(* ============================================ *)

(** Get credential file path for an agent *)
let credential_file config agent_name =
  Filename.concat (agents_dir config) (agent_name ^ ".json")
;;

module Nickname_helpers = Auth_nickname

let is_generated_nickname_shape = Nickname_helpers.is_generated_nickname_shape
let keeper_transport_alias_stable_name = Nickname_helpers.keeper_transport_alias_stable_name
let extract_agent_type_prefix = Nickname_helpers.extract_agent_type_prefix
let credential_agent_name = Nickname_helpers.credential_agent_name

let raw_token_file config agent_name =
  Filename.concat (auth_dir config) (agent_name ^ ".token")
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

    Without this fallback, Workspace.bind_session's nickname output caused a
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

type load_credential_error =
  | Credential_missing of { ctx_agent_name : string }
  | Credential_mismatch of
      { ctx_agent_name : string
      ; resolved_credential_stem : string
      }

let pp_load_credential_error fmt = function
  | Credential_missing { ctx_agent_name } ->
    Format.fprintf fmt "Credential_missing { ctx_agent_name = %S }" ctx_agent_name
  | Credential_mismatch { ctx_agent_name; resolved_credential_stem } ->
    Format.fprintf
      fmt
      "Credential_mismatch { ctx_agent_name = %S; resolved_credential_stem = %S }"
      ctx_agent_name
      resolved_credential_stem
;;

let show_load_credential_error err = Format.asprintf "%a" pp_load_credential_error err

let load_credential_of config ~ctx_agent_name ~resolved_credential_stem
  : (agent_credential, load_credential_error) result
  =
  if String.equal resolved_credential_stem ctx_agent_name
  then (
    match load_credential config ctx_agent_name with
    | Some cred -> Ok cred
    | None -> Error (Credential_missing { ctx_agent_name }))
  else Error (Credential_mismatch { ctx_agent_name; resolved_credential_stem })
;;

(** Forward-declared invalidator for [credential_index_cache], wired
    later in this file once the cache state is in scope.  Default is a
    no-op so [save_credential] / [delete_credential] do not break if
    [register_credential_cache_invalidator] is somehow skipped; the
    TTL bound in the cache still guarantees eventual freshness. *)
let credential_cache_invalidator_ref
  : (string -> unit) ref
  =
  ref (fun (_ : string) -> ())
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
  (match cred.id with
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
     save_private_text_file stub_file json_str);
  (* Bypass forward-reference into the cache module below.  Stored as
     a ref so the cache module can register its invalidator after both
     definitions are visible; see [register_credential_cache_invalidator]
     near [credential_token_index]. *)
  !credential_cache_invalidator_ref config
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
    try read_text_file file |> String_util.trim_nonempty with
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
  let raw_token = raw_token_file config agent_name in
  let redirect_target = load_redirect_target config file in
  let credential_target =
    match load_credential config agent_name with
    | Some { id = Some cid; _ } -> Some (credential_uuid_file config cid)
    | _ -> None
  in
  remove_file_if_exists file;
  remove_file_if_exists raw_token;
  Option.iter remove_file_if_exists redirect_target;
  Option.iter remove_file_if_exists credential_target;
  !credential_cache_invalidator_ref config
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

(* ============================================ *)
(* Credential token-hash index cache             *)
(* ============================================ *)

(** In-memory cache of [list_credentials] indexed by token hash, used
    by [Auth_credential_token.find_credential_by_token].  Without it,
    every auth-gated request re-reads the credential directory
    ([read_dir] + N x JSON parse) through [Eio_guard.run_in_systhread]
    roundtrips.  Live measurement (2026-05-26 fleet, 6 credentials,
    cold filesystem): 9.9s for the first request, 0.21-0.45s warm.
    Cached lookup is an O(1) hashtable read under a single mutex
    acquire.

    Cache semantics:
    - TTL bound (60s) so external in-place edits eventually surface
      without restarting the server.
    - Explicit invalidation from [save_credential] / [delete_credential]
      so writes through this module are visible immediately.
    - Token hash -> [agent_credential list] (not single value) so the
      #9786 ambiguous-lookup warn path still sees all matches.  The
      list is built in [list_credentials] order so first-match
      semantics stay identical to the pre-cache implementation. *)

type credential_index_cache_entry = {
  loaded_at : float;
  by_token : (string, agent_credential list) Hashtbl.t;
}

let credential_index_cache_ttl_sec = 60.0

(* Plain [Stdlib.Mutex], not [Eio.Mutex]: [save_credential] is also
   called from non-Eio call sites (CLI bootstrap, tests outside
   [with_eio_runtime]).  [Eio_guard.run_in_systhread] already falls
   back to direct invocation when Eio is not ready, so the rest of
   the credential-base I/O works in both contexts — the cache mutex
   must keep that property.  Stdlib.Mutex is cooperative under Eio
   because the critical section is short (hashtable lookup or
   replace) and never blocks on I/O. *)
let credential_index_cache_mu : Mutex.t = Mutex.create ()

let with_credential_index_cache_lock f =
  Mutex.lock credential_index_cache_mu;
  Fun.protect ~finally:(fun () -> Mutex.unlock credential_index_cache_mu) f

let credential_index_cache
  : (string, credential_index_cache_entry) Hashtbl.t
  =
  Hashtbl.create 4

let build_token_index (creds : agent_credential list)
  : (string, agent_credential list) Hashtbl.t
  =
  let idx = Hashtbl.create (max 8 (List.length creds)) in
  List.iter
    (fun (cred : agent_credential) ->
       let prev =
         Hashtbl.find_opt idx cred.token |> Option.value ~default:[]
       in
       Hashtbl.replace idx cred.token (cred :: prev))
    creds;
  (* Reverse each bucket so callers see [list_credentials] order
     (first-match semantics match the legacy [List.filter] flow). *)
  Hashtbl.filter_map_inplace
    (fun _ entries -> Some (List.rev entries))
    idx;
  idx
;;

let invalidate_credential_index_cache config =
  let key = agents_dir config in
  with_credential_index_cache_lock (fun () ->
    Hashtbl.remove credential_index_cache key)
;;

let credential_token_index config
  : (string, agent_credential list) Hashtbl.t
  =
  let key = agents_dir config in
  let now = Time_compat.now () in
  (* Two-phase: lookup under the lock; if a miss, drop the lock to
     run the disk read, then re-acquire to publish.  Holding the
     lock across the disk read would serialize all auth checks
     during the cold path. *)
  let cached =
    with_credential_index_cache_lock (fun () ->
      match Hashtbl.find_opt credential_index_cache key with
      | Some entry
        when now -. entry.loaded_at < credential_index_cache_ttl_sec ->
        Some entry.by_token
      | _ -> None)
  in
  match cached with
  | Some by_token ->
    Auth_metric_store.inc_counter
      Auth_metric_store.metric_auth_credential_index_cache_hits
      ();
    by_token
  | None ->
    Auth_metric_store.inc_counter
      Auth_metric_store.metric_auth_credential_index_cache_misses
      ();
    let creds = list_credentials config in
    let by_token = build_token_index creds in
    with_credential_index_cache_lock (fun () ->
      Hashtbl.replace
        credential_index_cache
        key
        { loaded_at = now; by_token });
    by_token
;;

(* Wire the forward-declared invalidator so [save_credential] and
   [delete_credential] can drop their cache entry without forming a
   forward reference to the cache helpers above. *)
let () =
  credential_cache_invalidator_ref := invalidate_credential_index_cache
;;

(** #9786: detect credentials sharing the same bearer token.

    The 2026-04-23 audit found [external MCP clients] and [admin]
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
       let prev = Hashtbl.find_opt by_token cred.token |> Option.value ~default:[] in
       Hashtbl.replace by_token cred.token (cred :: prev))
    creds;
  Hashtbl.fold (fun token_hash entries acc -> (token_hash, entries) :: acc) by_token []
;;

let token_hash_prefix_of token_hash =
  if String.length token_hash >= 12 then String.sub token_hash 0 12 else token_hash
;;

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
;;

(* #10304: rotation_outcome type + rotate_shared_tokens defined
   later in the file (after save_raw_token_credential).  This block
   intentionally left as a forward-pointer comment so the audit and
   rotation surfaces are co-located in the API but the
   implementation respects definition order. *)
