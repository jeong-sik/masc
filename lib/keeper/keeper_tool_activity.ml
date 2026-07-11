let emit_tool_exec
      ~config
      ~(meta : Keeper_meta_contract.keeper_meta)
      ~tool_name
      ~success
      ~duration_ms
      ~typed_outcome
      ~provider
      ~keeper_turn_id
      ~oas_turn
      ~task_id
      ()
  =
  try
    ignore
      (Activity_graph.emit
         config
         ~actor:(Activity_graph.entity ~kind:"agent" meta.agent_name)
         ~subject:(Activity_graph.entity ~kind:"tool" tool_name)
         ~kind:
           (Activity_graph.tool_execution_event_kind_to_string
              Activity_graph.Keeper_in_turn_tool_executed)
         ~payload:
           (`Assoc
               [ "tool_name", `String tool_name
               ; "success", `Bool success
               ; "duration_ms", `Int duration_ms
               ; ( "typed_outcome"
                 , match typed_outcome with
                   | Some outcome -> Keeper_tool_outcome.to_json outcome
                   | None -> `Null )
               ; "provider", `String provider
               ; "keeper_name", `String meta.name
               ; "keeper_turn_id", Json_util.int_opt_to_json keeper_turn_id
               ; "oas_turn", `Int oas_turn
               ; "task_id", Json_util.string_opt_to_json task_id
               ; "source", `String "keeper_in_turn"
               ])
         ~tags:[ "tool"; "keeper"; (if success then "success" else "failure") ]
         ()
        : Activity_graph.event)
  with
  | Eio.Cancel.Cancelled _ as e -> raise e
  | exn ->
    Keeper_callback_failure.record
      ~base_dir:config.base_path
      ~meta
      ~callback:"keeper_tool_activity_emit"
      exn
;;
