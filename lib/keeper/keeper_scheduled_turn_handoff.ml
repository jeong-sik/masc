let is_scheduled (source : Keeper_event_queue.stimulus) =
  match source.payload with
  | Keeper_event_queue.Schedule_due _ -> true
  | Board_signal _ | Board_attention _ | Bootstrap | Fusion_completed _
  | Connector_attention _ | Hitl_resolved _ | Ask_answered _
  | Completion_authority_rejected _ | Task_cancelled _ | Workspace_message _
  | Delegate_completed _ | Composition_completed _ | Tool_result_ready _
  | Owned_job_completed _ | Addon_operation_changed _ | Task_outcome _ -> false

let pending ~base_path ~keeper_name =
  Executor_pool_ref.submit_or_inline ~name:__FUNCTION__ (fun () ->
    Keeper_registry_event_queue.pending_selections_result ~base_path keeper_name
    |> Result.map (List.filter (fun (selection : Keeper_event_queue_state.pending_selection) ->
         is_scheduled selection.source)))
