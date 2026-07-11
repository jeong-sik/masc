let tool_exec_kind = "keeper.tool_exec"

let emit_tool_exec
      ~config
      ~agent_name
      ~keeper_name
      ~tool_name
      ~success
      ~duration_ms
      ~outcome
      ~provider
      ~turn_id
      ()
  =
  try
    ignore
      (Activity_graph.emit
         config
         ~actor:(Activity_graph.entity ~kind:"agent" agent_name)
         ~subject:(Activity_graph.entity ~kind:"tool" tool_name)
         ~kind:tool_exec_kind
         ~payload:
           (`Assoc
               [ "tool_name", `String tool_name
               ; "success", `Bool success
               ; "duration_ms", `Int duration_ms
               ; "outcome", `String outcome
               ; "provider", `String provider
               ; "keeper_name", `String keeper_name
               ; "turn_id", `String turn_id
               ; "source", `String "keeper_in_turn"
               ])
         ~tags:[ "tool"; "keeper"; (if success then "success" else "failure") ]
         ()
        : Activity_graph.event)
  with
  | Eio.Cancel.Cancelled _ as e -> raise e
  | exn ->
    Log.Keeper.warn
      ~keeper_name
      "keeper.tool_exec activity emit failed for %s: %s"
      tool_name
      (Printexc.to_string exn)
;;
