(* Both signals name a directory resolved through symlinks. A directory that
   does not exist yet is named under its deepest existing ancestor, resolved,
   which is the path its first write resolves to. Any other failure to
   resolve is the workspace being unreadable and raises. *)
let rec physical dir =
  match Unix.realpath dir with
  | resolved -> resolved
  | exception Unix.Unix_error (Unix.ENOENT, _, _) ->
    let parent = Filename.dirname dir in
    if String.equal parent dir
    then dir
    else Filename.concat (physical parent) (Filename.basename dir)
;;

(* The two directories are spelled from [config.base_path] the way the
   writers spell them, then resolved. *)
let install ~sw ~mono_clock ~(config : Workspace.config) =
  let base_path = config.base_path in
  let module Notices = Server_workspace_invalidation.Make (struct
    type t = Workspace_dataset_event.dataset
    let compare = Stdlib.compare
  end) in
  let enqueue = Notices.start ~sw ~mono_clock
      ~publish:(Workspace_dataset_event.announce ~base_path) in
  let config_keepers_dir =
    physical (Config_dir_resolver.keepers_dir_for_base_path ~base_path)
  in
  let runtime_keepers_dir = physical (Workspace.keepers_runtime_dir config) in
  let world_directory = physical (Workspace_memory_ledger.directory ~base_path) in
  let world_changed () =
    Dashboard_cache.invalidate
      (Server_dashboard_http_core_cache.workspace_memory_inventory_cache_key ~base_path);
    enqueue Workspace_dataset_event.World_memory
  in
  let written ~keepers_dir ~keeper_id =
    if String.equal keepers_dir config_keepers_dir
       || String.equal keepers_dir runtime_keepers_dir
    then (
      Dashboard_cache.invalidate
        (Server_dashboard_http_keeper_memory_health.fleet_cache_key ~base_path);
      world_changed ();
      enqueue (Workspace_dataset_event.Memory_health { keeper = keeper_id }))
  in
  let unsubscribe_inputs =
    Keeper_memory_health_input.subscribe
      (fun { Keeper_memory_health_input.keepers_dir; keeper_id } ->
         written ~keepers_dir ~keeper_id)
  in
  let unsubscribe_commits =
    Keeper_memory_commit_notifications.subscribe
      (fun
        { Keeper_memory_commit_notifications.keepers_dir
        ; keeper_id
        ; store = Keeper_memory_commit_notifications.(Ordinary | Source_bound)
        ; revision = _
        }
      -> written ~keepers_dir ~keeper_id)
  in
  let unsubscribe_world =
    Workspace_memory_changed.subscribe (fun ~directory ->
      if String.equal directory world_directory then world_changed ())
  in
  Eio.Switch.on_release sw (fun () ->
    unsubscribe_inputs ();
    unsubscribe_commits ();
    unsubscribe_world ())
;;
