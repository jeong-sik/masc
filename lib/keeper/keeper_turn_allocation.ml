let allocate ~(config : Workspace.config) ~keeper_name =
  match
    Keeper_owner_registry.allocate_turn ~base_path:config.base_path ~keeper_name
  with
  | Ok turn_id -> Ok turn_id
  | Error error ->
    Error
      (Agent_core.Error.Io
         (Agent_core.Error.FileOpFailed
            { op = "allocate keeper turn number"
            ; path = Keeper_types_profile.keeper_meta_path config keeper_name
            ; detail = Keeper_owner_registry.command_error_to_string error
            }))
;;
