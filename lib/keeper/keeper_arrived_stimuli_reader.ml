let read ~(config : Workspace.config) ~keeper_name () =
  match Keeper_meta_store.read_effective_meta config keeper_name with
  | Error detail -> Error detail
  | Ok None -> Error "Keeper readership metadata unavailable"
  | Ok (Some meta) ->
    Keeper_registry_event_queue.pending_selections_result
      ~base_path:config.base_path
      keeper_name
    |> Result.map
         (List.filter (fun (selection : Keeper_event_queue_state.pending_selection) ->
            Keeper_board_audience.can_project_queued_stimulus ~meta selection.source))
;;
