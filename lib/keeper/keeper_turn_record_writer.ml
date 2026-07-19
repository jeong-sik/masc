let write
      ~config
      ~keeper_name
      ~trace_id
      ~absolute_turn
      ~runtime_profile
      ~model
      ~finish_reason
      ~context_window
      ~price_input_per_million
      ~price_output_per_million
      ~request_latency_ms
      ~ttfrc_ms
      ~sampling
      ~usage
      ~blocks
      ()
  =
  match
    Turn_record.make
      ~keeper:keeper_name
      ~trace_id
      ~absolute_turn
      ~blocks
      ~runtime_profile
      ~model
      ~finish_reason
      ~context_window
      ~price_input_per_million
      ~price_output_per_million
      ~request_latency_ms
      ~ttfrc_ms
      ~sampling
      ~usage
      ~ts:(Time_compat.now ())
  with
  | Error reason ->
    Log.Keeper.warn
      "turn record validation failed: keeper=%s trace=%s turn=%d reason=%s"
      keeper_name
      trace_id
      absolute_turn
      reason
  | Ok record ->
    (try
       let store = Keeper_types_support.keeper_turn_record_store config keeper_name in
       Dated_jsonl.append store (Turn_record.to_json record)
     with
     | Eio.Cancel.Cancelled _ as e -> raise e
     | exn ->
       Log.Keeper.warn
         "turn record append failed: keeper=%s trace=%s turn=%d err=%s"
         keeper_name
         trace_id
         absolute_turn
         (Printexc.to_string exn))
;;
