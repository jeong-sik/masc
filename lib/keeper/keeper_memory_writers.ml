module By_workspace = Map.Make (String)

let tables : Librarian_writers.t By_workspace.t Atomic.t = Atomic.make By_workspace.empty

let rec update change =
  let before = Atomic.get tables in
  if not (Atomic.compare_and_set tables before (change before)) then update change
;;

let workspace_key ~base_path = Keeper_registry_types.canonical_base_path_exn base_path

let start ~sw ~(config : Workspace.config) =
  let base_path = config.base_path in
  let key = workspace_key ~base_path in
  let memory_dir = Config_dir_resolver.keepers_dir_for_base_path ~base_path in
  let turns_dir = Workspace.keepers_runtime_dir config in
  let table =
    Librarian_writers.create
      ~sw
      ~now:Time_compat.now
      ~registered:(fun keeper -> Keeper_registry.is_registered ~base_path keeper)
      ~place:(fun keeper_id -> { memory_dir; turns_dir; keeper_id })
  in
  update (By_workspace.add key table);
  (* A later start may have replaced this table; only its own entry goes. *)
  Eio.Switch.on_release sw (fun () ->
    update (fun tables ->
      match By_workspace.find_opt key tables with
      | Some current when current == table -> By_workspace.remove key tables
      | Some _ | None -> tables))
;;

let find ~base_path = By_workspace.find_opt (workspace_key ~base_path) (Atomic.get tables)
