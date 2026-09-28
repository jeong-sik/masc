type turn = Autonomous | Direct of Keeper_chat_operation.Operation_id.t

let request ~turn ~base_path ~keeper_name =
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
       else
         let ready = match turn with
           | Autonomous -> Ok operations.has_claimable_queued
           | Direct operation_id ->
             Keeper_owner_registry.has_newer_original_queued
               ~base_path ~keeper_name ~operation_id
             |> Result.map_error Keeper_owner_registry.command_error_to_string
         in
         match ready with
         | Error _ as error -> error
         | Ok true -> Ok (Some Keeper_agent_run.{ reason = Operation_queued })
         | Ok false -> Ok None)
