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

let refresh_from_observation ~base_path observation =
  Result.map
    (fun workspace ->
       Skill_catalog_snapshot_service.refresh
         ~workspace
         ~user_home:Config_dir_resolver.initial_env_home
         ~read_config:(fun () -> Config_text observation.Runtime.source_text))
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
