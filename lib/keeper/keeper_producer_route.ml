type t =
  | Keeper of string
  | No_keeper

(* [Keeper_meta_store.read_meta] folds a missing file and a file this binary
   cannot decode into the same [Ok None]. Only the first means there is no
   Keeper; the second is a Keeper whose meta the boot path re-materialises,
   so the presence is read with the two cases kept apart. *)
let resolve ~(config : Workspace_utils_backend_setup.config) producer =
  match
    Keeper_registry_lookup.find_by_name_in_base_path
      ~base_path:config.Workspace.base_path
      producer
  with
  | Some entry -> Ok (Keeper entry.name)
  | None ->
    let name = String.trim producer in
    if String.equal name ""
    then Ok No_keeper
    else (
      match
        Keeper_meta_store.read_meta_file_path_presence
          ~ownership_root:config.Workspace.base_path
          (Keeper_types_profile.keeper_meta_path config name)
      with
      | Ok (Keeper_meta_store.Meta_present _) -> Ok (Keeper name)
      | Ok Keeper_meta_store.Meta_absent -> Ok No_keeper
      | Ok (Keeper_meta_store.Meta_not_current detail) ->
        Error
          (Printf.sprintf
             "keeper meta for %s is present but this binary does not decode it: %s"
             name
             detail)
      | Error detail -> Error detail)
;;
