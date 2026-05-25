(** MASC Authentication & Authorization Module *)

open Masc_domain

(* Crypto utilities, file I/O, config, credential CRUD, token
   verification — extracted to [Auth_credential] (godfile decomp). *)

include Auth_credential

(* ============================================ *)
(* Bare alias & archive                         *)
(* ============================================ *)


(* Extract the bare keeper nickname from a canonical agent_name of the
   form "keeper-<n>-agent". Returns None for non-canonical names. Kept
   as an inline helper to avoid adding a lib/auth -> lib/keeper
   dependency for a single string operation. *)
let bare_keeper_name_from_canonical canonical =
  let prefix = "keeper-" in
  let suffix = "-agent" in
  let plen = String.length prefix in
  let slen = String.length suffix in
  let len = String.length canonical in
  if
    len > plen + slen
    && String.sub canonical 0 plen = prefix
    && String.sub canonical (len - slen) slen = suffix
  then Some (String.sub canonical plen (len - plen - slen))
  else None
;;

(* Archive a credential file that we want to retire without deleting.
   Destination: auth_dir/.archive/<epoch>/<file>. Operator can review
   and restore. *)
let archive_credential_file config ~agent_name ~reason =
  let src = credential_file config agent_name in
  if not (file_exists src)
  then ()
  else (
    try
      let stamp = string_of_int (int_of_float (Unix.gettimeofday ())) in
      let dest_dir =
        Filename.concat (auth_dir config) (Filename.concat ".archive" stamp)
      in
      Fs_compat.mkdir_p dest_dir;
      let dest = Filename.concat dest_dir (agent_name ^ ".json") in
      Sys.rename src dest;
      Log.Auth.warn "archived credential %s -> %s (reason: %s)" src dest reason;
      if String.equal reason "bare-form keeper credential is dead after PR-3b1 starvation"
      then
        Prometheus.inc_counter
          Prometheus.metric_config_credential_archived_starvation
          ~labels:[ "keeper_name", agent_name ]
          ()
    with
    | Eio.Cancel.Cancelled _ as e -> raise e
    | exn ->
      Log.Auth.error
        "archive_credential_file failed for %s: %s"
        agent_name
        (Printexc.to_string exn))
;;

(* Boot self-heal of bare-form keeper credential files.

   Three policies cross this code path:

     PR-3a (#11146)   archive bare when token differs from canonical
                      (dual-identity guard).
     PR-3b1 (#11152)  starve runtime callers via canonicalize_if_keeper
                      in tool_coord.
     PR-3b2 (#11155)  archive bare unconditionally, on the assumption
                      that starvation killed every short-form caller.
     PR-#10440        ensure_credential_alias re-creates a bare-form
                      redirect stub on every boot so short-form
                      load_credential callers (auth_doctor, etc.)
                      resolve directly.

   PR-3b2 and PR-#10440 contradict: the alias writer puts a stub back
   on every boot and the archiver moves it on every boot, producing a
   ping-pong that accumulated 331 .archive/<epoch>/ folders in 17 days
   (measured 2026-05-14). Spec: AuthIdentityFSM.tla I1 IdentityBindsToken.

   This helper resolves the conflict by recognising a legitimate alias
   as alive: a bare-form file that is a redirect stub pointing to the
   *same* UUID file as the canonical credential is the PR-#10440 alias
   and must not be archived. Every other shape stays subject to PR-3b2:

     - direct credential (no redirect)               -> archive
     - redirect stub to a different UUID             -> archive (orphan)
     - redirect stub to the same UUID as canonical   -> KEEP (alias)
     - canonical missing or itself a direct cred     -> archive
       (alias semantics need both sides to share a UUID-backed cred). *)
(* Retention sweep for the .archive/<epoch>/ directories produced by
   [archive_credential_file]. Each epoch dir is flat (one .json per
   archived agent_name); this helper does not recurse so a stray
   nested directory would be left in place instead of being deleted
   wholesale. Returns [(kept, pruned)] for telemetry.

   Selection rule: sort epochs newest-first, always keep the most
   recent [min_keep], and among the remainder delete those whose
   epoch is older than [retention_days * 86400] seconds. *)
let prune_archive ~base_path ~retention_days ~min_keep : int * int =
  let archive_dir = Filename.concat (auth_dir base_path) ".archive" in
  if not (Sys.file_exists archive_dir && Sys.is_directory archive_dir)
  then 0, 0
  else (
    let now = Unix.gettimeofday () in
    let cutoff = now -. (float_of_int retention_days *. 86400.0) in
    let entries =
      try Sys.readdir archive_dir |> Array.to_list with
      | Sys_error _ -> []
    in
    let epoch_entries =
      List.filter_map
        (fun name ->
           match int_of_string_opt name with
           | Some epoch -> Some (epoch, Filename.concat archive_dir name)
           | None -> None)
        entries
      |> List.sort (fun (a, _) (b, _) -> compare b a)
    in
    let total = List.length epoch_entries in
    let prune_count = ref 0 in
    List.iteri
      (fun i (epoch, path) ->
         if i >= min_keep && float_of_int epoch < cutoff
         then (
           let inner =
             try Sys.readdir path |> Array.to_list with
             | Sys_error _ -> []
           in
           List.iter
             (fun name ->
                let file = Filename.concat path name in
                try Sys.remove file with
                | Sys_error _ -> ())
             inner;
           (try Fs_compat.rmdir path with
            | Sys_error _ -> ());
           if not (Sys.file_exists path) then incr prune_count))
      epoch_entries;
    total - !prune_count, !prune_count)
;;

type bare_alias_state =
  | Bare_absent
  | Bare_alive_alias
  | Bare_dead

(* Inspect the bare-form file at [agents/<bare>.json] without mutating
   it. Pure read; safe to call from audit paths.
   - [Bare_absent]      no file at the bare path.
   - [Bare_alive_alias] redirect stub aimed at the *same* UUID file
                         as the canonical credential (= PR-#10440
                         alias, must survive).
   - [Bare_dead]        any other shape: direct credential, redirect
                         to a different UUID, redirect with canonical
                         missing or not stub-shaped. *)
let classify_bare_for_canonical config ~canonical_name =
  match bare_keeper_name_from_canonical canonical_name with
  | None -> Bare_absent
  | Some bare_name ->
    let bare_file = credential_file config bare_name in
    if not (file_exists bare_file)
    then Bare_absent
    else (
      let canonical_file = credential_file config canonical_name in
      match
        load_redirect_target config bare_file,
        load_redirect_target config canonical_file
      with
      | Some bare_target, Some canonical_target
        when String.equal
               (Filename.basename bare_target)
               (Filename.basename canonical_target) -> Bare_alive_alias
      | _ -> Bare_dead)
;;

let inc_bare_alias_outcome ~outcome =
  Prometheus.inc_counter
    Prometheus.metric_auth_bare_alias_outcome_total
    ~labels:[ "outcome", outcome ]
    ~delta:1.0
    ()
;;

let archive_bare_for_canonical config ~canonical_name =
  match classify_bare_for_canonical config ~canonical_name with
  | Bare_absent ->
    inc_bare_alias_outcome ~outcome:"absent"
  | Bare_alive_alias ->
    inc_bare_alias_outcome ~outcome:"alive_skip"
  | Bare_dead ->
    inc_bare_alias_outcome ~outcome:"dead_archive";
    (match bare_keeper_name_from_canonical canonical_name with
     | None -> ()
     | Some bare_name ->
       archive_credential_file
         config
         ~agent_name:bare_name
         ~reason:"bare-form keeper credential is dead after PR-3b1 starvation")
;;

type bare_alias_audit_result =
  { alive_aliases : int
  ; dead_bares : int
  ; no_bares : int
  }

let empty_bare_alias_audit_result =
  { alive_aliases = 0; dead_bares = 0; no_bares = 0 }

let bare_alias_audit ~base_path ~canonical_names =
  let result =
    List.fold_left
      (fun acc canonical_name ->
         match classify_bare_for_canonical base_path ~canonical_name with
         | Bare_absent ->
           { acc with no_bares = acc.no_bares + 1 }
         | Bare_alive_alias ->
           { acc with alive_aliases = acc.alive_aliases + 1 }
         | Bare_dead ->
           { acc with dead_bares = acc.dead_bares + 1 })
      empty_bare_alias_audit_result
      canonical_names
  in
  (* Observability sink: gauges idempotently mirror the current
     classifier state so every Prometheus scrape (post-call) reports
     the same value, not just the boot-time INFO line. *)
  Prometheus.set_gauge
    Prometheus.metric_auth_bare_alias
    ~labels:[ "state", "alive" ]
    (float_of_int result.alive_aliases);
  Prometheus.set_gauge
    Prometheus.metric_auth_bare_alias
    ~labels:[ "state", "dead" ]
    (float_of_int result.dead_bares);
  Prometheus.set_gauge
    Prometheus.metric_auth_bare_alias
    ~labels:[ "state", "no_bare" ]
    (float_of_int result.no_bares);
  result
;;

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
  (match result with
   | Ok _ -> archive_bare_for_canonical config ~canonical_name:agent_name
   | Error _ -> ());
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
       Error (Auth (Auth_error.Unauthorized ("No credential found for " ^ agent_name)))
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

let check_permission config ~agent_name ~token ~permission : (unit, masc_error) result =
  let auth_cfg = load_auth_config config in
  if not auth_cfg.enabled
  then
    (* Auth disabled - allow everything *)
    Ok ()
  else if
    match read_initial_admin config with
    | Some admin -> String.equal agent_name admin
    | None -> false
  then (
    (* Bootstrap grace: the agent who enabled auth always has full access *)
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
      else Error (Auth (Auth_error.Unauthorized "Token required")))
;;

let permission_for_tool = Tool_permission_map.permission_for_tool

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

let is_unmapped_internal_tool_name tool_name =
  has_internal_tool_prefix tool_name
  || Tool_catalog.is_on_surface Tool_catalog.Keeper_internal tool_name
;;

let unknown_tool_class tool_name =
  if String.trim tool_name = "" then "empty" else "external"
;;

let record_strict_unknown_tool_denial ~agent_name ~tool_name =
  Prometheus.inc_counter
    Prometheus.metric_auth_strict_unknown_tool_denials
    ~labels:[ "agent_name", agent_name; "tool_class", unknown_tool_class tool_name ]
    ()
;;

(** Check permission for a tool call *)
let authorize_tool config ~agent_name ~token ~tool_name : (unit, masc_error) result =
  match permission_for_tool tool_name with
  | None ->
    if is_unmapped_internal_tool_name tool_name
    then
      (* Conservative default for unmapped internal tools. *)
      check_permission config ~agent_name ~token ~permission:CanBroadcast
    else (
      let () = record_strict_unknown_tool_denial ~agent_name ~tool_name in
      Error
        (Auth
           (Auth_error.Forbidden
              { agent = agent_name; action = "use unknown non-masc tool: " ^ tool_name })))
  | Some perm -> check_permission config ~agent_name ~token ~permission:perm
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
    match read_initial_admin config with
    | Some admin -> String.equal agent_name admin
    | None -> false
  then Ok Admin (* Bootstrap admin = full access *)
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
      then Error (Auth (Auth_error.Unauthorized "Token required"))
      else Ok Worker)
;;

let resolve_role config ~agent_name ~token : (agent_role, masc_error) result =
  let auth_cfg = load_auth_config config in
  resolve_role_with_auth_config config ~auth_cfg ~agent_name ~token
;;

let authorize_tool_for_role ~agent_name ~role ~tool_name : (unit, masc_error) result =
  match permission_for_tool tool_name with
  | Some perm ->
      if has_permission role perm
      then Ok ()
      else Error (Auth (Auth_error.Forbidden { agent = agent_name; action = tool_name }))
  | None ->
      if is_unmapped_internal_tool_name tool_name
      then
        (* Unmapped internal tool: require at least Worker *)
        if has_permission role CanBroadcast
        then Ok ()
        else
          Error (Auth (Auth_error.Forbidden { agent = agent_name; action = tool_name }))
      else (
        let () = record_strict_unknown_tool_denial ~agent_name ~tool_name in
        Error
          (Auth
             (Auth_error.Forbidden
                { agent = agent_name; action = "use unknown non-masc tool: " ^ tool_name })))
;;

(** Role-based tool authorization.
    Resolves the caller role and enforces the tool's required permission.
    Invalid/expired tokens are rejected (not silently downgraded).

    Tools not mapped by permission_for_tool are subject to additional
    checks — unmapped internal tools require at least Worker, and
    unmapped external tools are forbidden. *)
let authorize_tool_v2 config ~agent_name ~token ~tool_name : (unit, masc_error) result =
  match resolve_role config ~agent_name ~token with
  | Error e -> Error e
  | Ok role -> authorize_tool_for_role ~agent_name ~role ~tool_name
;;

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
  secret (* Return raw secret to show user once *)
;;

(** Verify room secret *)
let verify_room_secret config secret : bool =
  let hash = sha256_hash secret in
  let file = room_secret_file config in
  if Sys.file_exists file
  then (
    let stored_hash = String.trim (In_channel.with_open_text file In_channel.input_all) in
    hash = stored_hash)
  else false
;;

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

let bare_alias_audit_interval_default = 60.0

let bare_alias_audit_interval () =
  match Sys.getenv_opt "MASC_AUTH_BARE_ALIAS_AUDIT_INTERVAL_S" with
  | Some s ->
    (match float_of_string_opt s with
     | Some v when v > 0.0 -> v
     | _ -> bare_alias_audit_interval_default)
  | None -> bare_alias_audit_interval_default
;;

(* Periodic refresh of the bare-alias gauges. Boot-time audit sets
   the gauge once; this fiber re-runs the audit every
   [MASC_AUTH_BARE_ALIAS_AUDIT_INTERVAL_S] seconds (default 60) so
   the surface stays fresh against mid-run regressions -- e.g. an
   operator-initiated keeper add, a buggy provisioner that writes
   bare files, or a config reload that broadens the keeper roster.
   Without this, a regression introduced at runtime would be
   invisible until the next server restart.

   [canonical_names_fn] is invoked on every tick so a runtime
   keeper-roster change is reflected in the next sweep without
   restarting the fiber. *)
let start_bare_alias_audit_fiber ~sw ~clock ~base_path
    ~canonical_names_fn =
  let interval = bare_alias_audit_interval () in
  Eio.Fiber.fork ~sw (fun () ->
    Log.Auth.info
      "bare_alias_audit: periodic fiber started (interval=%.0fs)"
      interval;
    let rec loop () =
      Eio.Time.sleep clock interval;
      (try
         let _ : bare_alias_audit_result =
           bare_alias_audit ~base_path
             ~canonical_names:(canonical_names_fn ())
         in
         Prometheus.inc_counter
           Prometheus.metric_auth_bare_alias_audit_ticks_total
           ~delta:1.0
           ()
       with
       | Eio.Cancel.Cancelled _ as e -> raise e
       | exn ->
         Log.Auth.warn
           "bare_alias_audit: periodic tick failed: %s (gauges may be \
            stale until next tick)"
           (Printexc.to_string exn));
      loop ()
    in
    loop ())
;;
