let to_sdk_error
      ~keeper_name
      ~runtime_id
      ~visible_tool_names
      ~unexpected_tool_names
  =
  let requested_preview =
    visible_tool_names
    |> List.filteri (fun i _ -> i < 8)
    |> String.concat ", "
  in
  let omitted =
    List.length visible_tool_names
    - min 8 (List.length visible_tool_names)
  in
  let requested_suffix =
    if omitted > 0 then Printf.sprintf " (+%d more)" omitted else ""
  in
  let reason =
    Printf.sprintf
      "keeper turn reported tool names outside selected turn surface: \
       unexpected=[%s] requested=[%s%s]"
      (String.concat ", " unexpected_tool_names)
      requested_preview
      requested_suffix
  in
  Prometheus.inc_counter
    Keeper_metrics.(to_string ToolSurfaceViolations)
    ~labels:
      [ "keeper_name", keeper_name
      ; "kind", "tool_surface_violation"
      ; "signal", "unexpected_tool_names"
      ]
    ();
  Log.Keeper.error
    "keeper:%s runtime=%s %s"
    keeper_name
    runtime_id
    reason;
  Agent_sdk.Error.Internal reason
;;
