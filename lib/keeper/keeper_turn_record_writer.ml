let append_record_result ~config ~keeper_name record =
  let store = Keeper_types_support.keeper_turn_record_store config keeper_name in
  Dated_jsonl.append_result store (Turn_record.to_json record)
;;

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
      ~execution_ids
      ~blocks
      ()
  =
  let record : Turn_record.t =
    { execution_ids
    ; keeper = keeper_name
    ; trace_id
    ; absolute_turn
    ; turn_ref = Some (Ids.Turn_ref.make ~trace_id ~absolute_turn)
    ; blocks
    ; runtime_profile
    ; model
    ; finish_reason
    ; context_window
    ; price_input_per_million
    ; price_output_per_million
    ; request_latency_ms
    ; ttfrc_ms
    ; sampling
    ; usage
    ; ts = Time_compat.now ()
    }
  in
  match append_record_result ~config ~keeper_name record with
  | Ok () -> ()
  | Error error ->
    Log.Keeper.warn
      "turn record append failed: keeper=%s trace=%s turn=%d err=%s"
      keeper_name
      trace_id
      absolute_turn
      error
;;
