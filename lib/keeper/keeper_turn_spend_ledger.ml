let conversation_of_basis = function
  | Keeper_usage_resolution.Conversation_counter { conversation_id; position; _ } ->
    Some (conversation_id, position)
  | Keeper_usage_resolution.Per_request
  | Keeper_usage_resolution.Turn_total
  | Keeper_usage_resolution.Unavailable -> None
;;

let write ~masc_root ~agent_name ~task_id ~trace_id ~keeper_turn_id resolved =
  List.iter
    (fun (resolved : Keeper_turn_spend.resolved) ->
       let reading = resolved.reading in
       let delta, usage_missing =
         match resolved.resolution.delta with
         | Some delta -> delta, false
         | None ->
           Keeper_usage_resolution.sample_of_api_usage Agent_core.Types.zero_api_usage, true
       in
       Keeper_hooks_agent_core.emit_cost_event
         ~masc_root
         ~agent_name
         ~task_id
         ~trace_id
         ~keeper_turn_id
         ~agent_core_turn_ordinal:reading.ordinal
         ~model:reading.model
         ~input_tokens:delta.input_tokens
         ~output_tokens:delta.output_tokens
         ~cost_usd:(Keeper_usage_resolution.reported_cost_usd delta)
         ~usage_projection:
           (Cost_ledger.Resolved_attempt_delta
              { lane_attempt_index = resolved.lane_attempt_index
              ; reading_index = reading.reading_index
              })
         ~response_id:reading.response_id
         ~runtime_attempt:
           (resolved.routing_run_id, resolved.runtime_id, resolved.lane_attempt_index)
         ?conversation:(conversation_of_basis reading.basis)
         ~resolution_status:resolved.resolution.status
         ~cache_creation_input_tokens:delta.cache_creation_input_tokens
         ~cache_read_input_tokens:delta.cache_read_input_tokens
         ~usage_missing
         ())
    resolved
;;
