(* The server can enter this reader before a tool dispatch. Link its actual
   registered producer once; later fixture/source wrappers keep their slot. *)
let () = ignore Operator_tool.force_link

let observe_current ~state ~(scope : Mcp_server.workspace_scope) ~sw ~clock ~query
    ?actor ?view ~include_messages ~include_keepers ~include_summary_fields
    ~lightweight_summary () =
  let net, mono_clock = Server_dashboard_http_core_runtime.state_dashboard_runtime_caps state in
  let started_at = Unix.gettimeofday () in
  Server_dashboard_http_core_runtime.run_dashboard_compute
    ~mode:Server_dashboard_http_runtime_support.Offloaded_readonly ?net ?mono_clock
    ~sw ~clock ~config:scope.config ~kind:Pool_work.Cpu ~name:__FUNCTION__
    (fun ~config ~sw ->
      let ctx : _ Operator_control.context =
        {config; agent_name = Option.value ~default:"dashboard" actor;
         sw; clock; proc_mgr = state.Mcp_server.proc_mgr; net = None;
         delegated_dispatch = None; mcp_session_id = None} in
      let observation = Dashboard_projection_cache.operator_snapshot_observation
          ?actor ?view ~include_messages ~include_keepers ~include_summary_fields
          ~lightweight_summary ctx in
      {observation with json = observation.json
        |> Server_dashboard_http_core_cache.with_projection_diagnostics
          ~surface:"operator_snapshot" ~started_at
          ~extra:(Server_dashboard_http_core_operator.operator_snapshot_extra ())
        |> Server_dashboard_http_core_operator_query.with_operator_snapshot_metadata ~config ~query})
