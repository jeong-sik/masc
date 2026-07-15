(** Wake-time payload observation, extracted from [Keeper_agent_run]. *)

let record
    ~(meta : Keeper_meta_contract.keeper_meta)
    ~turn_system_prompt
    ~tools
    ~history_messages
    ?user_blocks
    ~user_message
    ~start_turn_count
    ~max_context
    ~pre_dispatch_compacted
    ()
  =
  try
      let sizes =
        Keeper_wake_telemetry.compute_sizes
          ~system_prompt:turn_system_prompt
          ~tools
          ~history_messages
          ?user_blocks
          ~user_message
          ()
      in
      let () =
        Keeper_keepalive_signal.record_wake_payload
          ~keeper_name:meta.name
          ~trace_id:(Keeper_id.Trace_id.to_string meta.runtime.trace_id)
          ~turn_index:start_turn_count
          ~context_window:max_context
          ~system_prompt_bytes:sizes.system_prompt_bytes
          ~tool_schema_json_bytes:sizes.tool_schema_json_bytes
          ~message_content_bytes:sizes.message_content_bytes
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
      "[wake_payload] observation failed keeper=%s: %s"
      meta.name
      (Printexc.to_string exn)
;;
