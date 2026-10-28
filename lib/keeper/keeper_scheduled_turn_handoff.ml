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

let successors ~intake ~base_path ~keeper_name =
  pending ~base_path ~keeper_name
  |> Result.map (List.filter (Keeper_heartbeat_source_batch.arrived_since_intake intake))

type request_error =
  | Queue_unavailable of string
  | Owner_unavailable of Keeper_owner_registry.command_error

let request ~intake ~base_path ~keeper_name =
  let open Result.Syntax in
  match Keeper_turn_preview_owner.current () with
  | None -> Ok []
  | Some observed ->
    (* The registered queue is an Atomic projection. Keep the ordinary
       no-schedule post-tool path free of durable queue reads; this hint
       cannot authorize admission or ACK. Heartbeats still read [pending]
       directly, including after restart. *)
    let* hint = Keeper_registry_event_queue.snapshot_result ~base_path keeper_name
      |> Result.map_error (fun detail -> Queue_unavailable detail) in
    if not (List.exists is_scheduled (Keeper_event_queue.to_list hint)) then Ok []
    else
    let* sources = successors ~intake ~base_path ~keeper_name
      |> Result.map_error (fun detail -> Queue_unavailable detail) in
    if List.is_empty sources then Ok []
    else
    let* accepted = Keeper_owner_registry.request_scheduled_turn
      ~base_path ~keeper_name ~observed sources
      |> Result.map_error (fun error -> Owner_unavailable error) in
    Ok (if accepted then sources else [])
