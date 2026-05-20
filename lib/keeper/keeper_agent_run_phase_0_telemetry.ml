let emit_if_enabled
      ~(meta : Keeper_types.keeper_meta)
      ~system_prompt
      ~tools
      ~history_messages
      ~user_message
      ~turn_index
      ~max_context
      ~pre_dispatch_compacted
  =
  if Env_config_keeper.KeeperTelemetry.payload_telemetry_enabled ()
  then (
    try
      let sizes =
        Keeper_wake_telemetry.compute_sizes
          ~system_prompt
          ~tools
          ~history_messages
          ~user_message
      in
      let model_id =
        match Keeper_model_labels.configured_model_labels_of_meta meta with
        | m :: _ -> m
        | [] -> "auto"
      in
      let _event : Dashboard_harness_health.wake_payload_event =
        Dashboard_harness_health.record_wake_payload
          ~keeper_name:meta.name
          ~trace_id:(Keeper_id.Trace_id.to_string meta.runtime.trace_id)
          ~turn_index
          ~model_id
          ~context_window:max_context
          ~approx_body_bytes:sizes.approx_body_bytes
          ~system_prompt_bytes:sizes.system_prompt_bytes
          ~tool_defs_bytes:sizes.tool_defs_bytes
          ~messages_bytes:sizes.messages_bytes
          ~message_count:sizes.message_count
          ~role_counts:sizes.role_counts
          ~tool_count:sizes.tool_count
          ~has_compact_happened:pre_dispatch_compacted
      in
      ()
    with
    | Eio.Cancel.Cancelled _ as e -> raise e
    | exn ->
      Log.Harness.warn
        "[wake_payload] telemetry failed keeper=%s: %s"
        meta.name
        (Printexc.to_string exn))
;;
