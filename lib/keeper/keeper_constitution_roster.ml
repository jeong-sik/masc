module Names = Set.Make (String)

let read ~(config : Workspace.config) =
  Keeper_meta_store.persisted_keeper_names_read_only_result config
  |> Result.map_error (fun detail ->
       World_constitution_store.Unreadable
         { path = Workspace.keepers_runtime_dir config; detail })
  |> Result.map (fun names ->
       let names = Names.of_list names in
       fun subject -> Names.mem subject names)
