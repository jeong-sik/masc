(** Phase-0 wake-time payload telemetry, extracted from [Keeper_agent_run]. *)

let record
    ~(meta : Keeper_meta_contract.keeper_meta)
    ~turn_system_prompt
    ~tools
    ~history_messages
    ~user_message
    ~start_turn_count
    ~max_context
    ~pre_dispatch_compacted
  =
  try
      let sizes =
        Keeper_wake_telemetry.compute_sizes
          ~system_prompt:turn_system_prompt
          ~tools
          ~history_messages
          ~user_message
      in
      let model_id =
        match Keeper_model_labels.configured_model_labels_of_meta meta with
        | m :: _ -> m
        | [] -> "auto"
      in
      let () =
        Keeper_keepalive_signal.record_wake_payload
          ~keeper_name:meta.name
          ~trace_id:(Keeper_id.Trace_id.to_string meta.runtime.trace_id)
          ~turn_index:start_turn_count
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
        (Printexc.to_string exn)
;;
