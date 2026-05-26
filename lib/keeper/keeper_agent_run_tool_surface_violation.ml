let to_sdk_error
      ~keeper_name
      ~cascade_name
      ~requested_tool_names_seen
      ~unexpected_tool_names
  =
  let requested_preview =
    requested_tool_names_seen
    |> List.filteri (fun i _ -> i < 8)
    |> String.concat ", "
  in
  let omitted =
    List.length requested_tool_names_seen
    - min 8 (List.length requested_tool_names_seen)
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
    Keeper_metrics.(to_string ContractViolations)
    ~labels:
      [ "keeper_name", keeper_name
      ; "kind", "tool_surface_violation"
      ; "signal", "unexpected_tool_names"
      ]
    ();
  Log.Keeper.error
    "keeper:%s cascade=%s %s"
    keeper_name
    cascade_name
    reason;
  Agent_sdk.Error.Internal reason
;;
