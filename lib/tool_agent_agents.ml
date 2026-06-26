let handle ?(tool_name = "masc_agents") ?(start_time = 0.0) config _args
  : Tool_result.result
  =
  let agents =
    try Workspace.get_active_agents config with
    | Eio.Cancel.Cancelled _ as e -> raise e
    | exn ->
      Log.Workspace.warn
        "masc_agents active-agent lookup failed: %s"
        (Stdlib.Printexc.to_string exn);
      []
  in
  Tool_result.make_ok
    ~tool_name
    ~start_time
    ~data:
      (`Assoc
        [ "count", `Int (List.length agents)
        ; "agents", `List (List.map Masc_domain.agent_to_yojson agents)
        ])
    ()
;;
