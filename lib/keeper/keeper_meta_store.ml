(** Keeper metadata snapshot I/O.

    Included by [Keeper_types] so existing [Keeper_types.*] callers keep
    their public read API while durable metadata storage remains separate. *)


open Keeper_types_profile
open Keeper_meta_contract
open Keeper_meta_json

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

(** The one durable snapshot write: normal serializer plus atomic durable
    commit.  Both the Owner write path ([replace_snapshot]) and the
    enumerated-field auto-repair in [read_meta_file_path] go through here, so
    a repaired file is byte-identical in shape to any other persisted
    snapshot. *)
let persist_snapshot ?ownership_root path meta =
  let payload = meta |> meta_to_json |> Yojson.Safe.pretty_to_string in
  Keeper_fs.save_bytes_durable_atomic ?ownership_root path payload
  |> settle_durable_replace path
;;

(** Issue #28844: one corrupt meta file used to produce an identical WARN on
    every periodic scan iteration (422 in three minutes).  WARNs are now
    emitted on state transitions only — a (site, path)'s first failure, a
    change in failure reason, or recovery — tracked as the last reported
    failure detail per (site, path).  The state is process-local on purpose:
    a restarted process reporting a still-bad file once is correct, and no
    wall-clock interval is involved.

    Growth bound: one entry per (site, path) that currently fails, plus stale
    entries for keepers removed from config while failing — those linger for
    the process lifetime.  Both populations are bounded by the configured
    keeper count, so the table stays O(failing keepers). *)
module Problem_report_state = struct
  type site =
    | Meta_read
    | Meta_read_changed
    | Meta_repair
    | Keepalive_scan
    | Persistent_scan

  module Key = struct
    type t = site * string

    let equal (site_a, path_a) (site_b, path_b) =
      site_a = site_b && String.equal path_a path_b
    ;;

    let hash = Hashtbl.hash
  end

  module Table = Hashtbl.Make (Key)

  type entry = {
    site : site;
    path : string;
    detail : string;
    first_observed : float;
  }

  let reported : (string * float) Table.t = Table.create 16
  let mutex = Stdlib.Mutex.create ()

  (** [true] when (site, path, detail) is a new problem state and the caller
      should log; [false] while the same failure keeps repeating. The row
      written here is the one and only record of the failure — the dashboard
      reads it through [snapshot_to_yojson] below, so there is no second
      table to keep in step. *)
  let should_report ~site ~path ~detail =
    Stdlib.Mutex.protect mutex (fun () ->
      let key = site, path in
      (* NDT-OK: wall clock stamps first_observed for dashboard telemetry;
         no branch reads it. *)
      let now = Unix.gettimeofday () in
      match Table.find_opt reported key with
      | Some (previous, first_observed) when String.equal previous detail ->
          false
      | Some (_, first_observed) ->
          Table.replace reported key (detail, first_observed);
          true
      | None ->
          Table.replace reported key (detail, now);
          true)
  ;;

  (** [true] when a previously reported problem cleared — the caller may log
      the recovery transition once. *)
  let note_recovered ~site ~path =
    Stdlib.Mutex.protect mutex (fun () ->
      let key = site, path in
      match Table.find_opt reported key with
      | None -> false
      | Some _ ->
        Table.remove reported key;
        true)
  ;;

  (** Drop any reported problem state for (site, path) without observing
      whether one existed.  For outcomes whose recovery transition is not
      logged — the file disappeared, or the scan site whose recovery the
      [Meta_read] site already reports — the clear itself is the whole
      operation. *)
  let clear ~site ~path =
    Stdlib.Mutex.protect mutex (fun () -> Table.remove reported (site, path))
  ;;

  let site_to_string = function
    | Meta_read -> "meta_read"
    | Meta_read_changed -> "meta_read_changed"
    | Meta_repair -> "meta_repair"
    | Keepalive_scan -> "keepalive_scan"
    | Persistent_scan -> "persistent_scan"
  ;;

  (** The dashboard projection reads the same rows [should_report] wrote:
      one table, one truth, no sync step where a clear on one side could
      leave the other side stale. *)
  let snapshot () =
    Stdlib.Mutex.protect mutex (fun () ->
      Table.fold
        (fun (site, path) (detail, first_observed) acc ->
           { site; path; detail; first_observed } :: acc)
        reported [])
  ;;

  let snapshot_to_yojson () =
    `List
      (List.map
         (fun (e : entry) ->
            `Assoc
              [ ("site", `String (site_to_string e.site))
              ; ("path", `String e.path)
              ; ("detail", `String e.detail)
              ; ("first_observed", `Float e.first_observed)
              ])
         (snapshot ()))
  ;;

  let reset () =
    Stdlib.Mutex.protect mutex (fun () -> Table.reset reported)
  ;;
end

(** The current-schema decode decision, shared by the runtime read and the
    deployment gate so the two cannot drift: the exact decode first, then the
    enumerated-field repair of issue #28844 followed by a redecode.  No I/O —
    persisting a repair is the runtime caller's step.  [Error] carries the
    detail the runtime reports when it fails open, so the gate names a
    rejection in the runtime's own words. *)
type decoded_meta =
  | Exact of keeper_meta
  | Repaired of
      { meta : keeper_meta
      ; decode_error : string
      ; repair_detail : string
      }

let decode_current_meta_with_repair json : (decoded_meta, string) result =
  match meta_of_json json with
  | Ok meta -> Ok (Exact meta)
  | Error e ->
    (match repair_non_canonical_enum_fields json with
     | None -> Error e
     | Some (repaired_json, repairs) ->
       let repair_detail =
         repairs
         |> List.map (fun (repair : enum_field_repair) ->
           Printf.sprintf
             "%s %S -> %S"
             repair.field
             repair.previous_value
             repair.repaired_value)
         |> String.concat ", "
       in
       (match meta_of_json repaired_json with
        | Ok meta -> Ok (Repaired { meta; decode_error = e; repair_detail })
        | Error redecode_detail ->
          (* Resetting the enumerated fields did not make the file
             decodable; the original failure stands, with the new decode
             error attached when it differs. *)
          Error
            (if String.equal redecode_detail e
             then e
             else
               Printf.sprintf
                 "%s; auto-repair of %s did not decode: %s"
                 e
                 repair_detail
                 redecode_detail)))
;;

let read_meta_file_path ?ownership_root path : (Keeper_meta_contract.keeper_meta option, string) result =
  (* Fail open. A meta this binary cannot read is an absent meta, not a dead
     keeper: the TOML declaration carries the whole setup, so the boot path
     re-materialises one. Refusing instead took the fleet down three times on
     2026-08-23 (#29490, #29601, and the generation/last_blocker removal),
     every time on a field this binary had itself stopped writing. What is
     lost is the accumulated counters in the unreadable file, and the WARN
     below is the record of that loss. *)
  let fail_open detail =
    Otel_metric_store.inc_counter
      Keeper_metrics.(to_string MetaReadFailures)
      ~labels:[("keeper", "aggregate"); ("site", "meta_parse")]
      ();
    if Problem_report_state.should_report ~site:Meta_read ~path ~detail
    then
      Log.Keeper.warn
        "keeper meta unreadable at %s, treating as absent (accumulated \
         counters in it are lost; the declaration re-materialises the \
         keeper): %s"
        path
        detail;
    (* main took the recovery decision (#29610: unreadable is absent, not fatal);
       this branch keeps its own contribution, which is that the loss shows
       up in the unreadable-store registry instead of only in a log line. *)
    Ok None
  in
  if not (Fs_compat.file_exists path)
  then (
    Problem_report_state.clear ~site:Meta_read ~path;
    Ok None)
  else (
    match Safe_ops.read_json_file_safe path with
    | Error e -> Error e
    | Ok json ->
      (match decode_current_meta_with_repair json with
       | Ok (Exact meta) ->
         if Problem_report_state.note_recovered ~site:Meta_read ~path
         then Log.Keeper.info "keeper meta parse recovered for %s" path;
         Problem_report_state.clear ~site:Meta_repair ~path;
              Ok (Some meta)
       | Ok (Repaired { meta = repaired_meta; decode_error; repair_detail }) ->
         (* Issue #28844: a non-canonical enumerated field used to brick every
            reader until something external rewrote the file.  When the
            corruption is confined to fields with a canonical default, repair
            in place through the normal serializer and proceed.  A live
            writer that keeps re-corrupting the file with the same content
            re-triggers the (idempotent) repair write each cycle, but the
            WARN is deduped on the repair detail via [Meta_repair], so the
            log storm does not return; the residual cost is one atomic
            rewrite of a small file per scan against an active corrupter. *)
         (match persist_snapshot ?ownership_root path repaired_meta with
          | Ok () ->
            if Problem_report_state.should_report
                 ~site:Meta_repair
                 ~path
                 ~detail:repair_detail
            then
              Log.Keeper.warn
                "keeper meta auto-repaired %s: %s"
                path
                repair_detail;
            Ok (Some repaired_meta)
          | Error write_detail ->
            fail_open
              (Printf.sprintf
                 "%s; auto-repair of %s failed to persist: %s"
                 decode_error
                 repair_detail
                 write_detail))
       | Error detail -> fail_open detail))
;;

type current_meta_rejection =
  | Unreadable of string
  | Not_current of string

let read_meta_file_path_read_only ~ownership_root path =
  match Fs_compat.load_owned_regular_file ~ownership_root path with
  | Error error ->
    Error (Unreadable (Fs_compat.owned_regular_file_read_error_to_string error))
  | Ok None -> Ok None
  | Ok (Some contents) ->
    (match Yojson.Safe.from_string contents with
     | exception Yojson.Json_error detail -> Error (Unreadable detail)
     | json ->
       (match decode_current_meta_with_repair json with
        | Ok (Exact meta) -> Ok (Some meta)
        | Ok (Repaired { decode_error; _ }) -> Error (Not_current decode_error)
        | Error detail -> Error (Not_current detail)))
;;

let validate_current_meta_file_result path : (unit, current_meta_rejection) result =
  (* Deploy-gate twin of [read_meta_file_path]: the same decode decision
     through [decode_current_meta_with_repair], minus the fail-open and the
     repair write. [Not_current] fires exactly when the runtime would read
     the file as absent and re-materialise the Keeper from its declaration
     (#29610), losing the accumulated counters and the persisted task
     binding; [Unreadable] when [read_meta_file_path] itself returns [Error]
     and the boot path refuses the keeper. The deployment preflight runs this
     between the previous runtime's stop and the next one's start — the
     writer lease has to be free — so a rejection holds the plane down until
     the operator repairs the file and redeploys. That downtime is the price
     of keeping the counters the boot-time fail-open would lose. *)
  if not (Fs_compat.file_exists path)
  then Ok ()
  else
    match Safe_ops.read_json_file_safe path with
    | Error detail -> Error (Unreadable detail)
    | Ok json ->
      (match decode_current_meta_with_repair json with
       | Ok (Exact _ | Repaired _) -> Ok ()
       | Error detail -> Error (Not_current detail))
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

let retained_root_entries_read_only_result config =
  let dir = Workspace.keepers_runtime_dir config in
  match Unix.lstat dir with
  | exception Unix.Unix_error (Unix.ENOENT, _, _) -> Ok (dir, [])
  | exception Unix.Unix_error (cause, _, _) ->
    Error
      (Printf.sprintf
         "failed to inspect keeper directory %s: %s"
         dir
         (Unix.error_message cause))
  | ({ Unix.st_kind = Unix.S_DIR; _ } as initial_stat) ->
    (match Unix.opendir dir with
     | exception Unix.Unix_error (cause, _, _) ->
       Error
         (Printf.sprintf
            "failed to open keeper directory %s: %s"
            dir
            (Unix.error_message cause))
     | handle ->
       let rec read reversed =
         match Unix.readdir handle with
         | entry -> read (entry :: reversed)
         | exception End_of_file -> Ok (List.rev reversed)
         | exception Unix.Unix_error (cause, _, _) ->
           Error (Unix.error_message cause)
       in
       let entries = read [] in
       let closed =
         match Unix.closedir handle with
         | () -> Ok ()
         | exception Unix.Unix_error (cause, _, _) ->
           Error (Unix.error_message cause)
       in
       (match entries, closed, Unix.lstat dir with
        | Ok files, Ok (), final_stat
          when final_stat.Unix.st_kind = Unix.S_DIR
               && final_stat.st_dev = initial_stat.st_dev
               && final_stat.st_ino = initial_stat.st_ino ->
          Ok (dir, files)
        | Error detail, _, _ | _, Error detail, _ ->
          Error
            (Printf.sprintf "failed to list keeper directory %s: %s" dir detail)
        | _, _, _ -> Error ("keeper store changed while listing: " ^ dir)
        | exception Unix.Unix_error (cause, _, _) ->
          Error
            (Printf.sprintf
               "keeper store changed while listing %s: %s"
               dir
               (Unix.error_message cause))))
  | _ -> Error (Printf.sprintf "keeper store is not a directory: %s" dir)
;;

let retained_keeper_names_read_only_result config =
  let open Result.Syntax in
  let* dir, entries = retained_root_entries_read_only_result config in
  let* names =
    List.fold_left
      (fun result entry ->
         let* names = result in
         if String.equal entry "." || String.equal entry ".."
         then Ok names
         else
         match Keeper_runtime_root_entry.metadata_keeper_name entry with
         | Some name when validate_name name -> Ok (name :: names)
         | Some _ -> Ok names
         | None ->
           let path = Filename.concat dir entry in
           (match Unix.lstat path with
            | { Unix.st_kind = Unix.S_DIR; _ } ->
              Keeper_id.Keeper_name.of_string entry
              |> Result.map_error (fun detail ->
                   Printf.sprintf
                     "invalid retained Keeper directory %S: %s"
                     entry
                     detail)
              |> Result.map (fun name ->
                   Keeper_id.Keeper_name.to_string name :: names)
            | { Unix.st_kind = Unix.S_LNK; _ } ->
              (match Keeper_id.Keeper_name.of_string entry with
               | Ok _ -> Error ("retained Keeper entry is a symlink: " ^ entry)
               | Error _ -> Ok names)
            | _ -> Ok names
            | exception Unix.Unix_error (cause, _, _) ->
              Error
                (Printf.sprintf
                   "failed to inspect retained Keeper entry %s: %s"
                   entry
                   (Unix.error_message cause))))
      (Ok [])
      entries
  in
  Ok (List.sort_uniq String.compare names)
;;

let persisted_keeper_names config =
  match persisted_keeper_names_result config with
  | Ok names -> names
  | Error msg ->
    Log.Keeper.warn "persisted_keeper_names: %s" msg;
    []
;;


let persisted_keeper_for_mention_target config ~mention_target =
  let target = Keeper_identity.Keeper_id.of_string mention_target in
  let read_effective keeper_name =
    match
      read_meta_file_path
        ~ownership_root:config.Workspace.base_path
        (keeper_meta_path config keeper_name)
    with
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
         if
           List.exists
             (fun alias ->
                match Keeper_identity.Keeper_id.of_string alias, target with
                | Some alias_id, Some target_id ->
                  Keeper_identity.Keeper_id.equal alias_id target_id
                | None, _ | _, None -> false)
             meta.mention_targets
         then collect ((keeper_name, meta) :: matches) rest
         else collect matches rest)
  in
  if Option.is_none target
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
              (String.trim mention_target)
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
    let path = keeper_meta_path config name in
    match
      read_meta_file_path ~ownership_root:config.Workspace.base_path path
    with
    | Ok (Some meta)
      when (not meta.paused) && effective_autoboot_enabled config name meta ->
        Problem_report_state.clear ~site:Keepalive_scan ~path;
        Some meta.name
    | Ok (Some _) ->
      Problem_report_state.clear ~site:Keepalive_scan ~path;
      None
    | Ok None ->
      Problem_report_state.clear ~site:Keepalive_scan ~path;
      if declarative_autoboot_enabled_by_default config name then Some name
      else None
    | Error msg ->
      (* Issue #8377: was [_ -> None] which collapsed read/parse
         failures silently into "name disappeared". Discovery would
         treat a corrupt meta file as if the keeper was deleted,
         hiding the operational issue. Now logs and excludes so the
         degraded state is operator-visible.  Issue #28844: the WARN
         fires on failure-state transitions only, not per scan. *)
      Otel_metric_store.inc_counter
        Keeper_metrics.(to_string MetaReadFailures)
        ~labels:[("keeper", name); ("site", "keepalive_read")]
        ();
      if Problem_report_state.should_report ~site:Keepalive_scan ~path ~detail:msg
      then
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
    let path = keeper_meta_path config name in
    match
      read_meta_file_path ~ownership_root:config.Workspace.base_path path
    with
    | Ok (Some meta)
      when (not meta.paused) && effective_autoboot_enabled config name meta ->
        Problem_report_state.clear ~site:Persistent_scan ~path;
        Some meta.name
    | Ok (Some _) ->
      Problem_report_state.clear ~site:Persistent_scan ~path;
      None
    | Ok None ->
      Problem_report_state.clear ~site:Persistent_scan ~path;
      None
    | Error msg ->
      (* Issue #8377: same anti-pattern as keepalive_keeper_names:
         Error was silently collapsed into None. Operator can't
         distinguish "keeper intentionally not persistent" from
         "meta file is corrupt and we couldn't read it".  Issue #28844:
         the WARN fires on failure-state transitions only. *)
      Otel_metric_store.inc_counter
        Keeper_metrics.(to_string MetaReadFailures)
        ~labels:[("keeper", name); ("site", "persistent_read")]
        ();
      if Problem_report_state.should_report ~site:Persistent_scan ~path ~detail:msg
      then
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
    read_meta_file_path
      ~ownership_root:config.Workspace.base_path
      (keeper_meta_path config requested_name)
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

let replace_snapshot config (persisted : Keeper_meta_contract.keeper_meta) =
  let path = keeper_meta_path config persisted.name in
  persist_snapshot ~ownership_root:config.Workspace.base_path path persisted
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
