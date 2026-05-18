type append_manifest =
  ?status:string ->
  ?decision:Yojson.Safe.t ->
  ?keeper_turn_id:int ->
  ?oas_turn_count:int ->
  ?checkpoint_path:string ->
  ?receipt_path:string ->
  site:string ->
  Keeper_runtime_manifest.event_kind ->
  unit

let checkpoint_error_json = function
  | None -> `Null
  | Some err -> `String (Agent_sdk.Error.to_string err)
;;

let append_checkpoint_start_events
      ~append_manifest
      ~keeper_turn_id
      ~checkpoint_path
      ~loaded_checkpoint_present
      ~pre_dispatch_compacted
      ~pre_dispatch_checkpoint_error
  =
  append_manifest
    ~site:"checkpoint_loaded"
    ~keeper_turn_id
    ~checkpoint_path
    ~decision:
      (`Assoc
        [ "loaded_checkpoint_present", `Bool loaded_checkpoint_present
        ; "pre_dispatch_compacted", `Bool pre_dispatch_compacted
        ; "pre_dispatch_checkpoint_error", checkpoint_error_json pre_dispatch_checkpoint_error
        ])
    Keeper_runtime_manifest.Checkpoint_loaded;
  append_manifest
    ~site:"context_compacted"
    ~keeper_turn_id
    ~status:(if pre_dispatch_compacted then "compacted" else "skipped")
    ~decision:
      (`Assoc
        [ "pre_dispatch_compacted", `Bool pre_dispatch_compacted
        ; "pre_dispatch_checkpoint_error", checkpoint_error_json pre_dispatch_checkpoint_error
        ; "checkpoint_path", `String checkpoint_path
        ])
    Keeper_runtime_manifest.Context_compacted
;;

let append_context_injected
      ~append_manifest
      ~keeper_turn_id
      ~base_system_prompt
      ~turn_system_prompt
      ~dynamic_context
      ~memory_context
      ~temporal_context
      ~user_message
      ~history_messages
      ~estimated_input_tokens
  =
  let digest_text = Keeper_agent_run_turn_helpers.digest_text in
  let history_messages_digest =
    Keeper_agent_run_turn_helpers.digest_message_texts_as_joined history_messages
  in
  append_manifest
    ~site:"context_injected"
    ~keeper_turn_id
    ~decision:
      (`Assoc
        [ "base_system_prompt_digest", `String (digest_text base_system_prompt)
        ; "turn_system_prompt_digest", `String (digest_text turn_system_prompt)
        ; "dynamic_context_digest", `String (digest_text dynamic_context)
        ; "memory_context_digest", `String (digest_text memory_context)
        ; "temporal_context_digest", `String (digest_text temporal_context)
        ; "user_message_digest", `String (digest_text user_message)
        ; "history_message_count", `Int (List.length history_messages)
        ; "history_messages_digest", `String history_messages_digest
        ; "estimated_input_tokens", `Int estimated_input_tokens
        ])
    Keeper_runtime_manifest.Context_injected
;;

let string_list_json names = `List (List.map (fun name -> `String name) names)

let append_tool_surface_selected
      ~append_manifest
      ~keeper_turn_id
      (tool_surface : Keeper_agent_tool_surface.tool_surface_metrics)
  =
  append_manifest
    ~site:"tool_surface_selected"
    ~keeper_turn_id
    ~decision:
      (`Assoc
        [ ( "turn_lane"
          , `String (Keeper_agent_tool_surface.turn_lane_to_string tool_surface.turn_lane)
          )
        ; ( "tool_surface_class"
          , `String
              (Keeper_agent_tool_surface.tool_surface_class_to_string
                 tool_surface.tool_surface_class) )
        ; ( "tool_requirement"
          , `String
              (Keeper_agent_tool_surface.tool_requirement_to_string
                 tool_surface.tool_requirement) )
        ; "visible_tool_count", `Int tool_surface.visible_tool_count
        ; "tool_gate_enabled", `Bool tool_surface.tool_gate_enabled
        ; "tool_surface_fallback_used", `Bool tool_surface.tool_surface_fallback_used
        ; "required_tool_names", string_list_json tool_surface.required_tool_names
        ; ( "required_tool_candidate_names"
          , string_list_json tool_surface.required_tool_candidate_names )
        ; ( "missing_required_tool_names"
          , string_list_json tool_surface.missing_required_tool_names )
        ; "config_root", `String tool_surface.config_root
        ])
    Keeper_runtime_manifest.Tool_surface_selected
;;
