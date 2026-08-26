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
