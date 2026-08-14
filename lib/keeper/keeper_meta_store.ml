(** Keeper metadata snapshot I/O.

    Included by [Keeper_types] so existing [Keeper_types.*] callers keep
    their public read API while durable metadata storage remains separate. *)


open Keeper_types_profile
open Keeper_meta_contract
open Keeper_meta_json

let read_meta_file_path path : (Keeper_meta_contract.keeper_meta option, string) result =
  if not (Fs_compat.file_exists path)
  then Ok None
  else (
    match Safe_ops.read_json_file_safe path with
    | Error e -> Error e
    | Ok json ->
      (* The unknown-key pre-scan that used to run here is gone: [meta_of_json]
         now decodes only the exact current shape, so an unknown top-level key
         is already a decode error rather than something a separate scan has to
         notice first. Keeping both would report the same drift twice under two
         different messages. *)
      (match meta_of_json json with
       | Ok meta -> Ok (Some meta)
       | Error e ->
         Otel_metric_store.inc_counter
           Keeper_metrics.(to_string MetaReadFailures)
           ~labels:[("keeper", "aggregate"); ("site", "meta_parse")]
           ();
         Log.Keeper.warn "keeper meta parse failed for %s: %s" path e;
         Error
           (Printf.sprintf
              "keeper meta invalid current schema at %s; runtime reset \
               required: %s"
              path
              e)))
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
       |> List.filter_map Keeper_runtime_root_entry.metadata_keeper_name
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

let persisted_keeper_name_for_agent_name config ~agent_name =
  let rec collect_matches matches = function
    | [] -> Ok (List.rev matches)
    | keeper_name :: rest ->
      (match read_meta_file_path (keeper_meta_path config keeper_name) with
       | Error detail -> Error detail
       | Ok None -> collect_matches matches rest
       | Ok (Some meta) ->
         if String.equal meta.agent_name agent_name
         then collect_matches (keeper_name :: matches) rest
         else collect_matches matches rest)
  in
  match persisted_keeper_names_result config with
  | Error _ as error -> error
  | Ok keeper_names ->
    (match collect_matches [] keeper_names with
     | Error _ as error -> error
     | Ok [] -> Ok None
     | Ok [keeper_name] -> Ok (Some keeper_name)
     | Ok keeper_names ->
       Error
         (Printf.sprintf
            "multiple persisted Keepers share agent_name=%s: %s"
            agent_name
            (String.concat "," keeper_names)))
;;

let persisted_keeper_for_mention_target config ~mention_target =
  let target = String.trim mention_target in
  let read_effective keeper_name =
    match read_meta_file_path (keeper_meta_path config keeper_name) with
    | Error _ as error -> error
    | Ok None -> Ok None
    | Ok (Some meta) ->
      Keeper_meta_contract.effective_meta_result
        ~base_path:config.Workspace.base_path
        meta
      |> Result.map Option.some
  in
  let rec collect matches = function
    | [] -> Ok (List.rev matches)
    | keeper_name :: rest ->
      (match read_effective keeper_name with
       | Error detail -> Error detail
       | Ok None -> collect matches rest
       | Ok (Some meta) ->
         if List.exists (String.equal target) meta.mention_targets
         then collect ((keeper_name, meta) :: matches) rest
         else collect matches rest)
  in
  if target = ""
  then Ok None
  else
    match persisted_keeper_names_result config with
    | Error _ as error -> error
    | Ok keeper_names ->
      (match collect [] keeper_names with
       | Error _ as error -> error
       | Ok [] -> Ok None
       | Ok [ match_ ] -> Ok (Some match_)
       | Ok matches ->
         Error
           (Printf.sprintf
              "multiple persisted Keepers claim mention_target=%s: %s"
              target
              (matches |> List.map fst |> String.concat ",")))
;;

let configured_keeper_names config =
  Keeper_types_profile.discover_keepers_toml
    (Config_dir_resolver.keepers_dir_for_base_path
       ~base_path:config.Workspace.base_path)
  |> List.map Keeper_types_profile.keeper_toml_discovery_name
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
     Every canonical root [.json] is metadata authority. *)
  match keeper_names_result config with
  | Ok names -> names
  | Error msg ->
    Log.Keeper.warn "keeper_names: %s" msg;
    []
;;

let declarative_autoboot_enabled_by_default config name =
  match
    load_keeper_profile_defaults_result_for_base_path
      ~base_path:config.Workspace.base_path
      name
  with
  | Error _ -> false
  | Ok defaults ->
    (match defaults.autoboot_enabled with
     | Some false -> false
     | Some true | None -> true)
;;

let effective_autoboot_enabled config name meta =
  match
    load_keeper_profile_defaults_result_for_base_path
      ~base_path:config.Workspace.base_path
      name
  with
  | Error _ -> false
  | Ok defaults ->
    (match defaults.autoboot_enabled with
     | Some value -> value
     | None -> meta.autoboot_enabled)
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
      match
        Keeper_meta_contract.effective_meta_result
          ~base_path:config.Workspace.base_path
          meta
      with
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

let settle_durable_replace path = function
  | Ok () -> Ok ()
  | Error error ->
    Error
      (Printf.sprintf
         "failed to durably write metadata %s: %s"
         path
         (Keeper_fs.durable_write_error_to_string error))
;;

let settle_durable_remove path = function
  | Ok () -> Ok ()
  | Error error ->
    Error
      (Printf.sprintf
         "failed to durably remove metadata %s: %s"
         path
         (Keeper_fs.durable_remove_error_to_string error))
;;

let replace_snapshot config (persisted : Keeper_meta_contract.keeper_meta) =
  let path = keeper_meta_path config persisted.name in
  match Keeper_meta_contract.terminal_latch_pause_violation persisted with
  | Some detail -> Error ("Keeper metadata invariant violation: " ^ detail)
  | None ->
    let payload = persisted |> meta_to_json |> Yojson.Safe.pretty_to_string in
    Keeper_fs.save_bytes_durable_atomic
      ~ownership_root:config.Workspace.base_path
      path
      payload
    |> settle_durable_replace path
;;

let remove_snapshot config ~name =
  let path = keeper_meta_path config name in
  Keeper_fs.remove_file_durable
    ~ownership_root:config.Workspace.base_path
    path
  |> settle_durable_remove path
;;

module For_testing = struct
  let settle_durable_replace = settle_durable_replace
  let settle_durable_remove = settle_durable_remove
end
