let write_post_turn ~config ~(meta : Keeper_types.keeper_meta) ~state_snapshot ~turn ~reply =
  try
    let notes_written, kinds_written =
      Keeper_memory_bank.append_memory_notes_from_reply
        config
        meta
        ~snapshot:state_snapshot
        ~turn
        ~reply
        ()
    in
    let tool_result_notes_written =
      if Keeper_tool_emission_hook.masc_tool_emission_enabled ()
      then (
        let tool_results =
          Keeper_tool_emission_hook.(snapshot (accumulator_for_keeper meta.name))
        in
        Keeper_memory_bank.append_memory_notes_from_tool_results
          config
          meta
          ~turn
          ~results:tool_results)
      else 0
    in
    let notes_written = notes_written + tool_result_notes_written in
    let kinds_written =
      if
        tool_result_notes_written > 0
        && not (List.mem "long_term" kinds_written)
      then kinds_written @ [ "long_term" ]
      else kinds_written
    in
    if notes_written > 0
    then
      Keeper_turn_telemetry.log_keeper_memory_write
        ~keeper_name:meta.name
        ~notes_written
        ~kinds_written
  with
  | exn ->
    Log.Keeper.error
      "keeper:%s memory_write failed: %s"
      meta.name
      (Printexc.to_string exn);
    Prometheus.inc_counter
      Keeper_metrics.metric_keeper_memory_write_failures
      ~labels:[ "keeper", meta.name ]
      ()
;;
