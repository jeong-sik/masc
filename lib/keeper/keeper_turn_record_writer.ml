let context_window_of_turn ~turn_budget = function
  | `Produced_result -> Some turn_budget
  | `Errored -> None
;;

let write
      ~config
      ~keeper_name
      ~agent_name
      ~turn_kind
      ~trace_id
      ~absolute_turn
      ~runtime_profile
      ~selected_model
      ~finish_reason
      ~context_window
      ~price_input_per_million
      ~price_output_per_million
      ~request_latency_ms
      ~ttfrc_ms
      ~request_wire_observation
      ~model_input_window
      ~raw_trace_run_ref
      ~sampling
      ~usage
      ~execution_ids
      ~blocks
      ~input_components
      ~tool_surface_ref
      ()
  =
  let record : Turn_record.t =
    { execution_ids
    ; keeper = keeper_name
    ; agent_name
    ; turn_kind
    ; trace_id
    ; absolute_turn
    ; turn_ref = Ids.Turn_ref.make ~trace_id ~absolute_turn
    ; blocks
    ; input_components
    ; tool_surface_ref
    ; runtime_profile
    ; selected_model
    ; finish_reason
    ; context_window
    ; price_input_per_million
    ; price_output_per_million
    ; request_latency_ms
    ; ttfrc_ms
    ; request_wire_observation
    ; model_input_window
    ; raw_trace_run_ref
    ; sampling
    ; usage
    ; ts = Time_compat.now ()
    }
  in
  try
    let store = Keeper_types_support.keeper_turn_record_store config keeper_name in
    Dated_jsonl.append store (Turn_record.to_json record);
    match turn_kind with
    | Turn_record.Autonomous ->
      Keeper_chat_broadcast.chat_appended
        ~keeper_name
        ~source:"agent"
        ()
    | Turn_record.Direct -> ()
  with
  | Eio.Cancel.Cancelled _ as e -> raise e
  | exn ->
    Log.Keeper.warn
      "turn record append failed: keeper=%s trace=%s turn=%d err=%s"
      keeper_name
      trace_id
      absolute_turn
      (Printexc.to_string exn)
;;
