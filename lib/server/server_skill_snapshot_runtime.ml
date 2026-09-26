type error = Invalid_workspace of Config_dir_resolver.canonical_base_path_error

type lookup =
  | Not_registered
  | Uninitialized
  | Ready of Skill_catalog_snapshot.t

type commit_application =
  | Applied of
      { input_source_revision : Runtime.config_source_revision
      ; publication : Skill_catalog_snapshot_service.publication
      }
  | Superseded of
      { commit_order : Runtime.config_commit_order
      ; applied_order : Runtime.config_commit_order
      }

type application_slot =
  { lock : Cross_context_mutex.t
  ; mutable applied_order : Runtime.config_commit_order option
  }

let application_slots_lock = Cross_context_mutex.create ()
let application_slots : (string, application_slot) Hashtbl.t = Hashtbl.create 1

let workspace base_path =
  Skill_catalog_snapshot_service.workspace_of_base_path ~base_path
  |> Result.map_error (fun error -> Invalid_workspace error)
;;

let application_slot workspace =
  let key = Skill_catalog_snapshot_service.workspace_base_path workspace in
  Cross_context_mutex.with_lock application_slots_lock (fun () ->
    match Hashtbl.find_opt application_slots key with
    | Some slot -> slot
    | None ->
      let slot =
        { lock = Cross_context_mutex.create (); applied_order = None }
      in
      Hashtbl.add application_slots key slot;
      slot)
;;

let snapshot_revision_string snapshot =
  Skill_catalog_snapshot.snapshot_revision snapshot
  |> Skill_catalog_snapshot.snapshot_revision_to_string
;;

(* #39269: the reason and the file are the whole point of the line. The boot
   report and a rejection found after boot print the same one. *)
let rejected_line ~runtime_config_path ~snapshot_revision diagnostics =
  Printf.sprintf
    "Skill catalog is empty for every Keeper until this is fixed. %s \
     snapshot_revision=%s"
    (Skill_source_config.rejection_message ~config_path:runtime_config_path diagnostics)
    snapshot_revision
;;

(* Boot publishes the first snapshot and [boot_report] logs it. After boot the
   Skill refresh route, the Skill editor and Keeper Skill publication reread
   runtime.toml from disk through [refresh_from_observation]. The runtime
   config API refuses an invalid [skills] table, but a hand edit on disk is
   read by any of these, so the catalog can empty or refill with no save and
   no boot. Each such change of config state is logged once, and a
   publication that keeps the state logs nothing. *)
let log_reread_transition ~runtime_config_path ~previous snapshot =
  let snapshot_revision = snapshot_revision_string snapshot in
  match
    Skill_catalog_snapshot.config_state previous,
    Skill_catalog_snapshot.config_state snapshot
  with
  | Configured _, Configured _
  | Config_rejected _, Config_rejected _
  | Config_unreadable _, Config_unreadable _ -> ()
  | (Configured _ | Config_unreadable _), Config_rejected { diagnostics; _ } ->
    Log.Server.warn
      "%s"
      (rejected_line ~runtime_config_path ~snapshot_revision diagnostics)
  | (Configured _ | Config_rejected _), Config_unreadable { detail } ->
    Log.Server.error
      "Skill snapshot config unreadable after rereading runtime.toml: %s (file: %s) \
       snapshot_revision=%s"
      detail
      runtime_config_path
      snapshot_revision
  | (Config_rejected _ | Config_unreadable _), Configured _ ->
    Log.Server.info
      "Skill catalog configured again after rereading runtime.toml: skills=%d \
       (file: %s) snapshot_revision=%s"
      (List.length (Skill_catalog_snapshot.entries snapshot))
      runtime_config_path
      snapshot_revision
;;

let refresh_from_observation ~base_path observation =
  Result.map
    (fun workspace ->
       (* [read_config] runs under the workspace refresh lock, so the snapshot
          read there is the one this publication replaces. *)
       let previous = ref None in
       let publication =
         Skill_catalog_snapshot_service.refresh
           ~workspace
           ~user_home:Config_dir_resolver.initial_env_home
           ~read_config:(fun () ->
             previous := Skill_catalog_snapshot_service.current ~workspace;
             Config_text observation.Runtime.source_text)
       in
       (match !previous, publication with
        | Some previous, Published snapshot ->
          log_reread_transition
            ~runtime_config_path:observation.Runtime.path
            ~previous
            snapshot
        | None, (Published _ | Unchanged _ | Workspace_retired)
        | Some _, (Unchanged _ | Workspace_retired) -> ());
       publication)
    (workspace base_path)
;;

let apply_commit ~base_path (receipt : Runtime.config_commit_receipt) =
  Result.map
    (fun workspace ->
       let slot = application_slot workspace in
       Cross_context_mutex.with_lock slot.lock (fun () ->
         match slot.applied_order with
         | Some applied_order
           when Runtime.compare_config_commit_order receipt.order applied_order <= 0 ->
           Superseded { commit_order = receipt.order; applied_order }
         | None | Some _ ->
           let publication =
             Skill_catalog_snapshot_service.refresh
               ~workspace
               ~user_home:Config_dir_resolver.initial_env_home
               ~read_config:(fun () -> Config_text receipt.observation.source_text)
           in
           (match publication with
            | Workspace_retired -> ()
            | Published _ | Unchanged _ ->
              slot.applied_order <- Some receipt.order);
           Applied
             { input_source_revision = receipt.observation.source_revision
             ; publication
             }))
    (workspace base_path)
;;

let lookup ~base_path =
  Skill_catalog_snapshot_service.find_workspace_of_base_path ~base_path
  |> Result.map_error (fun error -> Invalid_workspace error)
  |> Result.map (function
    | None -> Not_registered
    | Some workspace ->
      (match Skill_catalog_snapshot_service.current ~workspace with
       | None -> Uninitialized
       | Some snapshot -> Ready snapshot))
;;

let error_to_string = function
  | Invalid_workspace error ->
    Config_dir_resolver.canonical_base_path_error_to_string error
;;

let publish_lane_skills ~config exports =
  let ( let* ) = Result.bind in
  let* workspace = workspace config.Workspace.base_path |> Result.map_error error_to_string in
  let sources, invalid = List.fold_left
    (fun (sources, errors) (export : Lane_addon_runtime.skill_export) ->
      match export.package.skills_directory with
      | None -> sources, errors
      | Some relative ->
          let id = Lane_addon_runtime.skill_source_id export.owner in
          let source =
            let* id = Skill_source_config.source_id_of_string id in
            let path = Skill_resource_path.append_to ~root:export.package.directory relative in
            Skill_source_config.read_only_absolute_source ~id ~path
            |> Result.map_error Skill_source_config.path_rejection_to_string in
          match source with
          | Ok source ->
              {Skill_catalog_snapshot_service.source; ownership_root=export.package.directory} :: sources, errors
          | Error message -> sources, (id ^ ": " ^ message) :: errors)
    ([], []) exports in
  if exports = [] && not (Skill_catalog_snapshot_service.has_additional_sources ~workspace)
  then Ok ()
  else
  let* publication = Skill_catalog_snapshot_service.update_additional_sources
      ~workspace ~sources:(List.rev sources) in
  let errors = List.rev invalid @
    (Skill_catalog_snapshot_service.additional_source_diagnostics ~workspace
     |> List.map (fun (issue : Skill_catalog_snapshot_service.additional_source_diagnostic) ->
       Skill_source_config.source_id_to_string issue.source_id ^ ": " ^ issue.message)) in
  match publication, errors with
  | Workspace_retired, _ -> Error "package Skill workspace publication was retired"
  | (Published _ | Unchanged _), [] -> Ok ()
  | (Published _ | Unchanged _), _ -> Error (String.concat "; " errors)
;;

type boot_level =
  | Boot_info
  | Boot_warn
  | Boot_error

let boot_report ~runtime_config_path snapshot =
  let snapshot_revision = snapshot_revision_string snapshot in
  match Skill_catalog_snapshot.config_state snapshot with
  | Configured _ ->
    ( Boot_info
    , Printf.sprintf
        "Skill snapshot ready at boot: snapshot_revision=%s catalog_revision=%s skills=%d rejections=%d"
        snapshot_revision
        (Skill_catalog_snapshot.catalog_revision snapshot
         |> Skill_catalog_snapshot.catalog_revision_to_string)
        (List.length (Skill_catalog_snapshot.entries snapshot))
        (List.length (Skill_catalog_snapshot.rejections snapshot)) )
  | Config_rejected { diagnostics; _ } ->
    (* #39269: this used to print only a diagnostic count, so a rejected
       [skills] table emptied every Keeper's catalog with no reason in the
       log. *)
    Boot_warn, rejected_line ~runtime_config_path ~snapshot_revision diagnostics
  | Config_unreadable { detail } ->
    ( Boot_error
    , Printf.sprintf
        "Skill snapshot config unreadable at boot: %s (file: %s) snapshot_revision=%s"
        detail
        runtime_config_path
        snapshot_revision )
;;
