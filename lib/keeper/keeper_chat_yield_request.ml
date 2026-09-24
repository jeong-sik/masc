let request ~base_path ~keeper_name =
  match Keeper_registry.get ~base_path keeper_name with
  | None -> Error (Printf.sprintf "keeper not registered: %s" keeper_name)
  | Some _ ->
    (match Keeper_owner_registry.operation_projection ~base_path ~keeper_name with
     | Error error -> Error (Keeper_owner_registry.lookup_error_to_string error)
     | Ok operations ->
       if operations.Keeper_owner.store_unavailable
       then (
         Log.Keeper.warn ~keeper_name
           "chat readiness unavailable; retaining current turn progress";
         Ok None)
       else if operations.has_claimable_queued
       then Ok (Some Keeper_agent_run.{ reason = Operation_queued })
       else Ok None)
