(** Keeper meta store I/O and CAS write helpers.

    Included by [Keeper_types] so existing [Keeper_types.*] callers keep
    their public API while durable meta storage is separated from the
    compatibility facade. *)

open Keeper_types_profile
open Keeper_meta_contract
open Keeper_meta_json

let runtime_meta_write_sync_hook : (Coord.config -> keeper_meta -> unit) ref =
  ref (fun _ _ -> ())
;;

let register_runtime_meta_write_sync f = runtime_meta_write_sync_hook := f

let read_meta_file_path path : (keeper_meta option, string) result =
  if not (Fs_compat.file_exists path)
  then Ok None
  else (
    match Safe_ops.read_json_file_safe path with
    | Error e -> Error e
    | Ok json ->
      let json, _scrubbed = scrub_persisted_keeper_meta_json ~path json in
      warn_unknown_keeper_meta_keys ~path json;
      (match meta_of_json json with
       | Ok meta -> Ok (Some meta)
       | Error e ->
         Log.Keeper.warn "keeper meta parse failed for %s: %s" path e;
         Error e))
;;

(** Sidecar stem suffixes (without the trailing .json).
    A file like [sangsu.dataset.json] has stem [sangsu.dataset]; stripping
    [.json] and checking [String.ends_with ~suffix] on this stem filters
    sidecars while allowing keeper names that contain dots (e.g.
    [dot.name.json]). When adding a new sidecar kind, add its dot-prefixed
    suffix here. *)
let keeper_sidecar_stem_suffixes = [ ".dataset" ]

let is_keeper_meta_file f =
  if not (Filename.check_suffix f ".json")
  then false
  else (
    let stem = Filename.chop_suffix f ".json" in
    stem <> ""
    && not
         (List.exists
            (fun suf ->
               String.length stem > String.length suf && String.ends_with ~suffix:suf stem)
            keeper_sidecar_stem_suffixes))
;;

let persisted_keeper_names config =
  let dir = keeper_dir config in
  match Safe_ops.list_dir_safe dir with
  | Error e ->
    Log.Keeper.warn "persisted_keeper_names: failed to list directory %s: %s" dir e;
    []
  | Ok files ->
    files
    |> List.filter is_keeper_meta_file
    |> List.map Filename.remove_extension
    |> List.filter validate_name
    |> List.sort String.compare
;;

let configured_keeper_names _config =
  Config_dir_resolver.log_warnings ~context:"KeeperTypes" ();
  Keeper_types_profile.discover_keepers_toml (Config_dir_resolver.keepers_dir ())
  |> List.map fst
  |> dedupe_keep_order
;;

let keeper_names config =
  (* Discovery uses persisted JSON (.masc/keepers/*.json) as primary source.
     JSON files are scoped to the server's base_path, so test isolation works.
     Overlay keepers (from .masc/config/keepers/*.toml) are materialized to
     JSON at boot by load_or_materialize_boot_meta, so they appear here too.
     Sidecar files (.dataset) are filtered by is_keeper_meta_file. *)
  persisted_keeper_names config
;;

let declarative_autoboot_enabled_by_default name =
  match (load_keeper_profile_defaults name).autoboot_enabled with
  | Some false -> false
  | Some true | None -> true
;;

let keepalive_keeper_names config =
  configured_keeper_names config
  |> List.filter_map (fun name ->
    match read_meta_file_path (keeper_meta_path config name) with
    | Ok (Some meta) when (not meta.paused) && meta.autoboot_enabled -> Some meta.name
    | Ok (Some _) -> None
    | Ok None -> if declarative_autoboot_enabled_by_default name then Some name else None
    | Error msg ->
      (* Issue #8377: was [_ -> None] which collapsed read/parse
         failures silently into "name disappeared". Discovery would
         treat a corrupt meta file as if the keeper was deleted,
         hiding the operational issue. Now logs and excludes so the
         degraded state is operator-visible. *)
      Log.Keeper.warn
        "keepalive_keeper_names: meta read failed for %s, dropping from keepalive set: %s"
        name
        msg;
      None)
;;

(** Names of keepers that should be running across sessions.
    A keeper is "persistent" when its on-disk meta has autoboot enabled
    and is not currently paused - i.e. the operator expects the runtime
    to keep it alive after restart.

    Mirrors [keepalive_keeper_names] for readers that care about
    durability rather than the keepalive fiber. *)
let persistent_agent_names config =
  configured_keeper_names config
  |> List.filter_map (fun name ->
    match read_meta_file_path (keeper_meta_path config name) with
    | Ok (Some meta) when (not meta.paused) && meta.autoboot_enabled -> Some meta.name
    | Ok (Some _) -> None
    | Ok None -> None
    | Error msg ->
      (* Issue #8377: same anti-pattern as keepalive_keeper_names:
         Error was silently collapsed into None. Operator can't
         distinguish "keeper intentionally not persistent" from
         "meta file is corrupt and we couldn't read it". *)
      Log.Keeper.warn
        "persistent_agent_names: meta read failed for %s, treating as non-persistent: %s"
        name
        msg;
      None)
;;

let keeper_name_from_agent_name = Keeper_identity.keeper_name_from_agent_name

let canonical_keeper_name_from_agent_name =
  Keeper_identity.canonical_keeper_name_from_agent_name
;;

let canonical_keeper_name = Keeper_identity.canonical_keeper_name

let separator_alias_variants name =
  let map_sep ~from_ch ~to_ch value =
    String.map (fun c -> if c = from_ch then to_ch else c) value
  in
  Json_util.dedupe_keep_order
    [ name; map_sep ~from_ch:'_' ~to_ch:'-' name; map_sep ~from_ch:'-' ~to_ch:'_' name ]
;;

let read_meta_resolved config name : ((string * keeper_meta) option, string) result =
  let requested_name = String.trim name in
  let read_candidate candidate =
    read_meta_file_path (keeper_meta_path config candidate)
    |> Result.map (Option.map (fun meta -> candidate, meta))
  in
  let rec read_first = function
    | [] -> Ok None
    | candidate :: rest ->
      (match read_candidate candidate with
       | Ok None -> read_first rest
       | Ok (Some _) as ok -> ok
       | Error _ as err -> err)
  in
  if requested_name = ""
  then Ok None
  else (
    let alias_candidates =
      match keeper_name_from_agent_name requested_name with
      | Some alias_name when not (String.equal alias_name requested_name) ->
        separator_alias_variants alias_name
      | _ -> []
    in
    read_first (separator_alias_variants requested_name @ alias_candidates))
;;

let read_meta config name : (keeper_meta option, string) result =
  let requested_name = String.trim name in
  let path = keeper_meta_path config requested_name in
  if keeper_debug
  then
    Log.Keeper.debug
      "read_meta name=%s path=%s exists=%b"
      requested_name
      path
      (Fs_compat.file_exists path);
  match read_meta_resolved config requested_name with
  | Ok (Some (_resolved_name, meta)) -> Ok (Some meta)
  | Ok None -> Ok None
  | Error _ as err -> err
;;

(** Read keeper meta only if the file's mtime has changed since [last_mtime].
    Returns [Some (meta, new_mtime)] when the file changed, [None] when
    unchanged. Avoids parsing JSON on every heartbeat cycle when no
    operator has modified the meta file. *)
let read_meta_if_changed config name ~(last_mtime : float) : (keeper_meta * float) option =
  let requested_name = String.trim name in
  let read_candidate candidate =
    let path = keeper_meta_path config candidate in
    if not (Fs_compat.file_exists path)
    then None
    else (
      match Fs_compat.file_mtime path with
      | Some mtime when mtime > last_mtime ->
        (match read_meta_file_path path with
         | Ok (Some meta) -> Some (meta, mtime)
         | Ok None -> None
         | Error msg ->
           (* Issue #8377: was [_ -> None] which silently treated a
              read/parse failure as "no change". Now logs so an
              operator can correlate stale UI with bad meta JSON. *)
           Log.Keeper.warn
             "read_meta_if_changed: parse failed for %s (mtime=%.0f): %s"
             path
             mtime
             msg;
           None)
      | _ -> None)
  in
  match read_candidate requested_name with
  | Some _ as changed -> changed
  | None ->
    (match keeper_name_from_agent_name requested_name with
     | Some alias_name when not (String.equal alias_name requested_name) ->
       read_candidate alias_name
     | _ -> None)
;;

let current_utc_timestamp () =
  let t = Unix.gmtime (Unix.gettimeofday ()) in
  Printf.sprintf
    "%04d-%02d-%02dT%02d:%02d:%02dZ"
    (t.tm_year + 1900)
    (t.tm_mon + 1)
    t.tm_mday
    t.tm_hour
    t.tm_min
    t.tm_sec
;;

let refresh_progress_updated_line config name =
  let progress_path = Keeper_types_support.keeper_progress_path config name in
  try
    let content = Fs_compat.load_file progress_path in
    let now_str = current_utc_timestamp () in
    let updated =
      String.split_on_char '\n' content
      |> List.map (fun line ->
        if String.starts_with ~prefix:"Updated:" (String.trim line)
        then "Updated: " ^ now_str
        else line)
      |> String.concat "\n"
    in
    Fs_compat.save_file progress_path updated
  with
  | _ -> ()
;;

let persist_meta config path persisted =
  let json = meta_to_json persisted in
  match Keeper_fs.save_json_atomic path json with
  | Ok () ->
    !runtime_meta_write_sync_hook config persisted;
    refresh_progress_updated_line config persisted.name;
    Ok ()
  | Error msg -> Error (Printf.sprintf "failed to write meta %s: %s" path msg)
;;

let write_meta ?(force = false) config (m : keeper_meta) : (unit, string) result =
  (* Assign UUID on first write for legacy keepers lacking keeper_id. *)
  let m =
    match m.keeper_id with
    | Some _ -> m
    | None -> { m with keeper_id = Some (Keeper_id.Uid.generate ()) }
  in
  let path = keeper_meta_path config m.name in
  if force
  then (
    let persisted = { m with meta_version = m.meta_version + 1 } in
    persist_meta config path persisted)
  else (
    (* Version CAS: reject writes whose version doesn't match what's on disk. *)
    match read_meta_file_path path with
    | Ok (Some existing) ->
      if existing.meta_version <> m.meta_version
      then
        Error
          (Printf.sprintf
             "meta version conflict for %s: expected %d, disk has %d"
             m.name
             m.meta_version
             existing.meta_version)
      else (
        let persisted = { m with meta_version = m.meta_version + 1 } in
        persist_meta config path persisted)
    | Ok None ->
      (* No existing file: initial write. *)
      let persisted = { m with meta_version = 1 } in
      persist_meta config path persisted
    | Error msg ->
      Error (Printf.sprintf "failed to read existing meta for CAS %s: %s" path msg))
;;

let is_version_conflict_error msg =
  let re = Re.Pcre.re "meta version conflict" |> Re.compile in
  try
    ignore (Re.exec re msg);
    true
  with
  | Not_found -> false
;;

(* #9764/#9733/#9769: cycle-completion writes lose data when a heartbeat or
   supervisor fiber bumps meta_version between the cycle's read and its
   write. Bounded retry that re-reads the latest disk version, lifts the
   caller's payload onto it, and writes again.

   Trade-off: the caller's payload wins at the field level. Concurrent
   updates from heartbeat (last_seen, cursor) are overwritten. This is
   acceptable for cycle completion because (a) heartbeat fields are
   ephemeral and resync on the next heartbeat tick, while (b) cycle
   payload (usage tokens, trace_history, generation) is non-recoverable.
   Heartbeat itself must NOT use this helper (it would cause the inverse
   problem). *)
let write_meta_with_retry ?(max_retries = 3) config (m : keeper_meta)
  : (unit, string) result
  =
  let path = keeper_meta_path config m.name in
  let rec attempt n m =
    match write_meta config m with
    | Ok () -> Ok ()
    | Error msg when n >= max_retries -> Error msg
    | Error msg when not (is_version_conflict_error msg) -> Error msg
    | Error _ ->
      (* Version conflict: read latest disk state, lift caller's payload
         onto its version, and try again. *)
      (match read_meta_file_path path with
       | Ok (Some latest) ->
         Log.Keeper.warn
           "write_meta CAS retry %d/%d for %s (caller had %d, disk %d)"
           (n + 1)
           max_retries
           m.name
           m.meta_version
           latest.meta_version;
         attempt (n + 1) { m with meta_version = latest.meta_version }
       | Ok None ->
         (* Disk file vanished between attempts; fall back to fresh write. *)
         attempt (n + 1) { m with meta_version = 0 }
       | Error read_msg ->
         Error (Printf.sprintf "write_meta retry: failed to re-read for CAS: %s" read_msg))
  in
  attempt 0 m
;;

(* #9769 root fix: like [write_meta_with_retry], but lets the caller
   declare field ownership via [merge]. The turn-failure/cycle path
   uses [Keeper_meta_merge.heartbeat_fields_from_disk] so its retry
   does not clobber heartbeat-owned fields ([joined_room_ids],
   [last_seen_seq_by_room]). *)
let write_meta_with_merge
      ?(max_retries = 3)
      ~(merge : latest:keeper_meta -> caller:keeper_meta -> keeper_meta)
      config
      (m : keeper_meta)
  : (unit, string) result
  =
  let path = keeper_meta_path config m.name in
  let rec attempt n (caller : keeper_meta) =
    match write_meta config caller with
    | Ok () -> Ok ()
    | Error msg when n >= max_retries -> Error msg
    | Error msg when not (is_version_conflict_error msg) -> Error msg
    | Error _ ->
      (match read_meta_file_path path with
       | Ok (Some latest) ->
         Log.Keeper.warn
           "write_meta CAS retry %d/%d for %s (caller had %d, disk %d; field-level merge)"
           (n + 1)
           max_retries
           caller.name
           caller.meta_version
           latest.meta_version;
         attempt (n + 1) (merge ~latest ~caller)
       | Ok None ->
         (* Disk file vanished between attempts; fall back to fresh write. *)
         attempt (n + 1) { caller with meta_version = 0 }
       | Error read_msg ->
         Error (Printf.sprintf "write_meta retry: failed to re-read for CAS: %s" read_msg))
  in
  attempt 0 m
;;
