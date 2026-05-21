(** Cascade-name TOML/registry writer for keeper meta, extracted from
    [server_routes_http_routes_dashboard.ml]. Single helper that
    propagates a new [cascade_name] for a keeper into both the on-disk
    keeper TOML and the in-memory [Keeper_registry] entry, returning
    whether the keeper was registered before the update. *)

let sync_keeper_cascade_meta ~(config : Coord.config) ~(name : string)
    ~(cascade_name : string) : (bool, string) result =
  let updated_at = Keeper_types.now_iso () in
  match Keeper_types.read_meta config name with
  | Error msg -> Error ("read_meta failed after TOML update: " ^ msg)
  | Ok (Some meta) ->
      let updated =
        { (Keeper_types.set_cascade_name cascade_name meta) with updated_at }
      in
      (match Keeper_types.write_meta ~force:true config updated with
       | Ok () ->
           let registered =
             Option.is_some
               (Keeper_registry.get ~base_path:config.base_path name)
           in
           Keeper_registry.update_meta ~base_path:config.base_path name updated;
           Ok registered
       | Error msg -> Error ("write_meta failed after TOML update: " ^ msg))
  | Ok None ->
      (match Keeper_registry.get ~base_path:config.base_path name with
       | None -> Ok false
       | Some entry ->
           let updated =
             { (Keeper_types.set_cascade_name cascade_name entry.meta) with updated_at }
           in
           (match Keeper_types.write_meta ~force:true config updated with
            | Ok () ->
                Keeper_registry.update_meta ~base_path:config.base_path name
                  updated;
                Ok true
            | Error msg ->
                Error ("write_meta failed after TOML update: " ^ msg)))
