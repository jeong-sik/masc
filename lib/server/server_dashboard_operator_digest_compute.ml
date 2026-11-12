let observe_current ~state ~(scope : Mcp_server.workspace_scope) ~sw ~clock ~query
    ?actor ?target_type ?target_id ?include_workers () =
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
      Operator_control.observe ?actor ?target_type ?target_id ?include_workers ctx
      |> Result.map (fun (observation : Dashboard_projection_cache.digest_observation) ->
        {observation with json = observation.json
          |> Server_dashboard_http_core_cache.with_projection_diagnostics
            ~surface:"operator_digest" ~started_at
            ~extra:["readonly_pool", Workspace_utils.domain_local_pg_backend_diagnostics_json ()]
          |> Server_dashboard_http_core_operator_query.with_operator_digest_metadata ~config ~query}))
