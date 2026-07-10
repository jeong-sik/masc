(** Keeper meta store I/O and CAS write helpers.

    Included by [Keeper_types] so existing [Keeper_types.*] callers keep
    their public API while durable meta storage is separated from the
    compatibility facade. *)


open Keeper_types_profile
open Keeper_meta_contract
open Keeper_meta_json

let runtime_meta_write_sync_hook_atomic
    : (Workspace.config -> Keeper_meta_contract.keeper_meta -> unit) Atomic.t
  =
  Atomic.make (fun _ _ -> ())
;;

let runtime_meta_write_sync_hook config meta =
  Atomic.get runtime_meta_write_sync_hook_atomic config meta

let register_runtime_meta_write_sync f =
  Atomic.set runtime_meta_write_sync_hook_atomic f

let version_conflict_re = Re.Pcre.re "meta version conflict" |> Re.compile

let read_meta_file_path path : (Keeper_meta_contract.keeper_meta option, string) result =
  if not (Fs_compat.file_exists path)
  then Ok None
  else (
    match Safe_ops.read_json_file_safe path with
    | Error e -> Error e
    | Ok json ->
      warn_unknown_keeper_meta_keys ~path json;
      (match meta_of_json json with
       | Ok meta -> Ok (Some meta)
       | Error e ->
         Otel_metric_store.inc_counter
           Keeper_metrics.(to_string MetaReadFailures)
           ~labels:[("keeper", "aggregate"); ("site", "meta_parse")]
           ();
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

let persisted_keeper_names_result config =
  let dir = keeper_dir config in
  match Safe_ops.list_dir_safe dir with
  | Error e ->
    Otel_metric_store.inc_counter
      Keeper_metrics.(to_string MetaReadFailures)
      ~labels:[("keeper", "aggregate"); ("site", "persisted_listdir")]
      ();
    Error (Printf.sprintf "failed to list keeper directory %s: %s" dir e)
  | Ok files ->
    Ok
      (files
       |> List.filter is_keeper_meta_file
       |> List.map Filename.remove_extension
       |> List.filter validate_name
       |> List.sort String.compare)
;;

let persisted_keeper_names config =
  match persisted_keeper_names_result config with
  | Ok names -> names
  | Error msg ->
    Log.Keeper.warn "persisted_keeper_names: %s" msg;
    []
;;

let configured_keeper_names config =
  Keeper_types_profile.discover_keepers_toml
    (Config_dir_resolver.keepers_dir_for_base_path
       ~base_path:config.Workspace.base_path)
  |> List.map fst
  |> dedupe_keep_order
;;

let keeper_names_result config =
  persisted_keeper_names_result config
;;

let keeper_names config =
  (* Discovery uses persisted JSON (.masc/keepers/*.json) as primary source.
     JSON files are scoped to the server's base_path, so test isolation works.
     Overlay keepers (from .masc/config/keepers/*.toml) are materialized to
     JSON at boot by load_or_materialize_boot_meta, so they appear here too.
     Sidecar files (.dataset) are filtered by is_keeper_meta_file. *)
  match keeper_names_result config with
  | Ok names -> names
  | Error msg ->
    Log.Keeper.warn "keeper_names: %s" msg;
    []
;;

let declarative_autoboot_enabled_by_default config name =
  match
    (load_keeper_profile_defaults_for_base_path
       ~base_path:config.Workspace.base_path
       name)
      .autoboot_enabled
  with
  | Some false -> false
  | Some true | None -> true
;;

let effective_autoboot_enabled config name meta =
  match
    (load_keeper_profile_defaults_for_base_path
       ~base_path:config.Workspace.base_path
       name)
      .autoboot_enabled
  with
  | Some value -> value
  | None -> meta.autoboot_enabled
;;

let keepalive_keeper_names config =
  configured_keeper_names config
  |> List.filter_map (fun name ->
    match read_meta_file_path (keeper_meta_path config name) with
    | Ok (Some meta)
      when (not meta.paused) && effective_autoboot_enabled config name meta ->
        Some meta.name
    | Ok (Some _) -> None
    | Ok None ->
      if declarative_autoboot_enabled_by_default config name then Some name
      else None
    | Error msg ->
      (* Issue #8377: was [_ -> None] which collapsed read/parse
         failures silently into "name disappeared". Discovery would
         treat a corrupt meta file as if the keeper was deleted,
         hiding the operational issue. Now logs and excludes so the
         degraded state is operator-visible. *)
      Otel_metric_store.inc_counter
        Keeper_metrics.(to_string MetaReadFailures)
        ~labels:[("keeper", name); ("site", "keepalive_read")]
        ();
      Log.Keeper.warn
        "keepalive_keeper_names: meta read failed for %s, dropping from keepalive set: %s"
        name
        msg;
      None)
;;

let paused_reconcile_keeper_names config =
  configured_keeper_names config
  |> List.filter_map (fun name ->
    match read_meta_file_path (keeper_meta_path config name) with
    | Ok (Some meta) when meta.paused && effective_autoboot_enabled config name meta ->
      Some meta.name
    | Ok (Some _)
    | Ok None -> None
    | Error msg ->
      Otel_metric_store.inc_counter
        Keeper_metrics.(to_string MetaReadFailures)
        ~labels:[("keeper", name); ("site", "paused_reconcile_read")]
        ();
      Log.Keeper.warn
        "paused_reconcile_keeper_names: meta read failed for %s, dropping from paused reconcile set: %s"
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
    | Ok (Some meta)
      when (not meta.paused) && effective_autoboot_enabled config name meta ->
        Some meta.name
    | Ok (Some _) -> None
    | Ok None -> None
    | Error msg ->
      (* Issue #8377: same anti-pattern as keepalive_keeper_names:
         Error was silently collapsed into None. Operator can't
         distinguish "keeper intentionally not persistent" from
         "meta file is corrupt and we couldn't read it". *)
      Otel_metric_store.inc_counter
        Keeper_metrics.(to_string MetaReadFailures)
        ~labels:[("keeper", name); ("site", "persistent_read")]
        ();
      Log.Keeper.warn
        "persistent_agent_names: meta read failed for %s, treating as non-persistent: %s"
        name
        msg;
      None)
;;

let read_meta_resolved config name : ((string * Keeper_meta_contract.keeper_meta) option, string) result =
  let requested_name = String.trim name in
  if requested_name = ""
  then Ok None
  else
    read_meta_file_path (keeper_meta_path config requested_name)
    |> Result.map (Option.map (fun meta -> requested_name, meta))
;;

let read_meta config name : (Keeper_meta_contract.keeper_meta option, string) result =
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

let read_effective_meta_resolved config name
    : ((string * Keeper_meta_contract.keeper_meta) option, string) result =
  match read_meta_resolved config name with
  | Error _ as err -> err
  | Ok None -> Ok None
  | Ok (Some (resolved_name, meta)) -> (
      match Keeper_meta_contract.effective_meta_result meta with
      | Ok meta -> Ok (Some (resolved_name, meta))
      | Error msg -> Error msg)
;;

let read_effective_meta config name
    : (Keeper_meta_contract.keeper_meta option, string) result =
  match read_effective_meta_resolved config name with
  | Ok (Some (_resolved_name, meta)) -> Ok (Some meta)
  | Ok None -> Ok None
  | Error _ as err -> err
;;

(** Read keeper meta only if the file's mtime has changed since [last_mtime].
    Returns [Some (meta, new_mtime)] when the file changed, [None] when
    unchanged. Avoids parsing JSON on every heartbeat cycle when no
    operator has modified the meta file. *)
let read_meta_if_changed config name ~(last_mtime : float) : (Keeper_meta_contract.keeper_meta * float) option =
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
           Otel_metric_store.inc_counter
             Keeper_metrics.(to_string MetaReadFailures)
             ~labels:[("keeper", "aggregate"); ("site", "changed_parse")]
             ();
           Log.Keeper.warn
             "read_meta_if_changed: parse failed for %s (mtime=%.0f): %s"
             path
             mtime
             msg;
           None)
      | _ -> None)
  in
  read_candidate requested_name
;;

let is_missing_progress_file_error exn =
  match exn with
  | Unix.Unix_error (Unix.ENOENT, _, _) -> true
  | _ ->
    let message = Printexc.to_string exn in
    String_util.contains_substring message "ENOENT"
    || String_util.contains_substring message "No such file"
;;

let refresh_progress_updated_line config name =
  let progress_path = Keeper_types_support.keeper_progress_path config name in
  if Fs_compat.file_exists progress_path then try
    let content = Fs_compat.load_file progress_path in
    let now_str = Masc_domain.now_iso () in
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
  | Eio.Cancel.Cancelled _ as e -> raise e
  | exn when is_missing_progress_file_error exn -> ()
  | exn ->
    Otel_metric_store.inc_counter
      Keeper_metrics.(to_string ProgressUpdatedLineFailures)
      ~labels:[("keeper", name)]
      ();
    Log.Keeper.warn ~keeper_name:name
      "progress Updated line refresh failed for %s: %s"
      progress_path
      (Printexc.to_string exn)
;;

let persist_meta config path persisted =
  let json = meta_to_json persisted in
  match Keeper_fs.save_json_atomic path json with
  | Ok () ->
    Atomic.get runtime_meta_write_sync_hook_atomic config persisted;
    refresh_progress_updated_line config persisted.name;
    Ok ()
  | Error msg -> Error (Printf.sprintf "failed to write meta %s: %s" path msg)
;;

(* Version CAS only — there is no force/bypass path. Cumulative usage
   counters are a monotone invariant (RFC-0225 §3.2, RFC-0237); a caller that
   lost the race must resolve the conflict through [write_meta_with_merge],
   never overwrite the disk snapshot. *)
let write_meta config (m : Keeper_meta_contract.keeper_meta) : (unit, string) result =
  let path = keeper_meta_path config m.name in
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
    Error (Printf.sprintf "failed to read existing meta for CAS %s: %s" path msg)
;;

let is_version_conflict_error msg =
  try
    ignore (Re.exec version_conflict_re msg);
    true
  with
  | Not_found -> false
;;

(* ── Boot-time canonicalization ─────────────────────────── *)

(* Keys deliberately deleted from persisted keeper meta. Dropping is
   destructive, so membership is EXPLICIT — a key is listed only after
   BOTH codec sides stopped knowing it. Deriving this set instead
   (canonical/config complement) was refuted twice: [compaction_mode]
   (keeper_meta_json_parse.ml, fail-closed persisted override) and
   [keeper_name] (keeper_identity.ml, wins over [name]) are
   parser-consumed yet in neither derived list, and a derived drop
   would silently destroy them. Forgetting to extend THIS list is
   fail-safe: the file merely keeps triggering the unknown-keys
   warning until the key is added here. *)
let retired_keeper_meta_key_names =
  [ (* #23929 continuity purge left these behind in .masc/keepers/ *)
    "last_continuity_update_ts"
  ; "continuity_summary"
  ]
;;

let retired_keeper_meta_keys json =
  match json with
  | `Assoc fields ->
    fields
    |> List.filter_map (fun (key, _) ->
      if List.mem key retired_keeper_meta_key_names then Some key else None)
    |> dedupe_keep_order
  | `Bool _ | `Float _ | `Int _ | `Intlit _ | `List _ | `Null | `String _ -> []
;;

let canonicalize_persisted_meta_files config =
  persisted_keeper_names config
  |> List.iter (fun name ->
    let path = keeper_meta_path config name in
    match Safe_ops.read_json_file_safe path with
    | Error msg ->
      Log.Keeper.warn "keeper meta canonicalize: unreadable %s: %s" path msg
    | Ok json ->
      (match retired_keeper_meta_keys json with
       | [] -> ()
       | retired ->
         (match meta_of_json json with
          | Error msg ->
            (* A file the strict parser rejects is preserved untouched for
               operator repair; editing it could destroy whatever evidence
               explains the rejection. *)
            Log.Keeper.warn
              "keeper meta canonicalize: parse failed for %s, leaving file untouched: %s"
              path
              msg
          | Ok _ ->
            (* Drop only the retired keys from the raw JSON instead of
               re-serializing the parsed record: every other field —
               including parser-consumed TOML-owned values the serializer
               never emits — keeps its exact on-disk value, and
               [meta_version] is not bumped. *)
            let cleaned = drop_assoc_keys retired json in
            (match Keeper_fs.save_json_atomic path cleaned with
             | Ok () ->
               Log.Keeper.info
                 "canonicalized keeper meta %s: dropped retired keys: %s"
                 path
                 (String.concat ", " retired)
             | Error msg ->
               Log.Keeper.warn
                 "keeper meta canonicalize: rewrite failed for %s (file unchanged, unknown-key warning persists): %s"
                 path
                 msg))))
;;

(* #9769 root fix: CAS retry with explicit field ownership. The
   turn-failure/cycle path uses [Keeper_meta_merge.heartbeat_fields_from_disk]
   now only carries the disk meta_version forward. *)
let write_meta_with_merge
      ?(max_retries = 3)
      ~(merge : latest:Keeper_meta_contract.keeper_meta -> caller:Keeper_meta_contract.keeper_meta -> Keeper_meta_contract.keeper_meta)
      config
      (m : Keeper_meta_contract.keeper_meta)
  : (unit, string) result
  =
  let path = keeper_meta_path config m.name in
  let rec attempt n (caller : Keeper_meta_contract.keeper_meta) =
    match write_meta config caller with
    | Ok () -> Ok ()
    | Error msg when n >= max_retries -> Error msg
    | Error msg when not (is_version_conflict_error msg) -> Error msg
    | Error _ ->
      (match read_meta_file_path path with
       | Ok (Some latest) ->
         Otel_metric_store.inc_counter
           Otel_metric_store.metric_write_meta_cas_retry_total
           ~labels:[("keeper", caller.name)]
           ();
         Log.Keeper.info
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
