open Result_syntax

module Oas = Agent_sdk

let resolve_net ?net () =
  match net with
  | Some net -> Ok net
  | None -> (
      match Eio_context.get_net_opt () with
      | Some net -> Ok net
      | None -> Error "Eio net not initialized")

let effective_execution_scope (spec : Worker_execution_spec.t) =
  Worker_container.resolve_execution_scope ~base_path:spec.base_path
    ~team_session_id:spec.team_session_id ?execution_scope:spec.execution_scope
    ()

let workspace_path_of_spec (spec : Worker_execution_spec.t) =
  match spec.working_dir with
  | Some dir when String.trim dir <> "" -> dir
  | _ -> spec.base_path

let contract_of_spec ~execution_scope (spec : Worker_execution_spec.t) =
  Option.map
    (fun delivery_contract ->
      Contract_composer.compose ~delivery_contract ~execution_scope
        ~tool_names:
          (List.sort_uniq String.compare
             (spec.allowed_tools @ spec.allowed_shell_tools)))
    spec.delivery_contract

let provider_and_model_id_of_label model_label =
  let provider = Worker_container.oas_provider_of_label model_label in
  let model_id =
    match Llm_provider.Cascade_config.parse_model_string model_label with
    | Some cfg -> cfg.Llm_provider.Provider_config.model_id
    | None -> model_label
  in
  (provider, model_id)

let execute_spec ~sw ?net ~room_config (spec : Worker_execution_spec.t) :
    (Worker_container_types.run_result, string) result =
  let execution_scope = effective_execution_scope spec in
  let workspace_path = workspace_path_of_spec spec in
  let mcp_session_id =
    Worker_container.resolved_mcp_session_id ~base_path:spec.base_path
      ~team_session_id:spec.team_session_id ~worker_name:spec.worker_name
  in
  let meta =
    Worker_container.make_worker_meta ~base_path:spec.base_path
      ~workspace_path ~team_session_id:spec.team_session_id
      ~worker_name:spec.worker_name ~mcp_session_id ~role:spec.role
      ~selection_note:spec.selection_note ~execution_scope
      ~worker_class:spec.worker_class
      ~effective_model:
        (match provider_and_model_id_of_label spec.model_label with
        | _provider, model_id -> model_id)
      ~thinking_enabled:spec.thinking_enabled
      ~max_turns_override:(Some spec.max_turns)
      ~timeout_seconds:(Some spec.timeout_sec)
  in
  match
    Worker_container.worker_auth_token ~base_path:spec.base_path
      ~worker_name:spec.worker_name
  with
  | Error e -> Error e
  | Ok auth_token ->
      let evidence_session_id =
        Worker_container.evidence_session_id_of_worker_run spec.worker_run_id
      in
      let _provider, model_id = provider_and_model_id_of_label spec.model_label in
      let provider = Worker_container.oas_provider_of_label spec.model_label in
      let system_prompt =
        Worker_container.default_system_prompt ~worker_name:spec.worker_name
          ~model_id ?session_id:spec.team_session_id ?role:spec.role
          ?selection_note:spec.selection_note ()
      in
      let prompt =
        let tool_contract =
          "Tool contract reminder: if you call masc_team_session_step with \
           turn_kind=\"note\", you must include a non-empty message field. Calls \
           missing message fail."
        in
        match execution_scope with
        | Team_session_types.Autonomous ->
            let resolvable =
              Agent_tool_surfaces.local_worker_resolvable_tool_names ()
            in
            let tool_names =
              Agent_tool_surfaces.build_tool_catalog ~role:"autonomous" ()
              |> List.filter (fun name -> List.mem name resolvable)
            in
            let team_ctx =
              match spec.team_session_id with
              | Some sid ->
                  Team_context.build ~base_path:spec.base_path
                    ~team_session_id:sid
              | None -> Team_context.empty
            in
            Prompt_composer.compose
              [
                Identity
                  {
                    name = spec.worker_name;
                    role =
                      (match spec.role with
                      | Some role -> role
                      | None -> "autonomous");
                    model = model_id;
                  };
                TeamContext team_ctx;
                AvailableTools tool_names;
                Guidelines
                  [
                    tool_contract;
                    "You have full read and write access. Choose the approach \
                     that best accomplishes your task. Use tools to verify \
                     your work. Prefer reading code before modifying it, and \
                     run tests or builds to confirm changes are correct.";
                  ];
                Task spec.prompt;
              ]
        | _ ->
            let workflow_contract =
              match execution_scope with
              | Team_session_types.Limited_code_change ->
                  "Coding worker protocol: you must use tools before answering. \
                   If the task requires a code change, the expected loop is \
                   file_read -> shell_exec -> file_write -> shell_exec, and you \
                   should not finish until the verification shell_exec succeeds. \
                   If the task is inspection-only, do not modify files."
              | Team_session_types.Observe_only ->
                  "Readonly worker protocol: use file_read and shell_exec for \
                   inspection, but do not modify files."
              | Team_session_types.Autonomous -> ""
            in
            let team_ctx_section =
              match spec.team_session_id with
              | Some sid ->
                  let ctx =
                    Team_context.build ~base_path:spec.base_path
                      ~team_session_id:sid
                  in
                  let section = Team_context.to_prompt_section ctx in
                  if section = "" then "" else "\n\n" ^ section
              | None -> ""
            in
            String.concat "\n\n" [ tool_contract; workflow_contract; spec.prompt ]
            ^ team_ctx_section
      in
      let* () =
        Worker_container.save_worker_meta ~base_path:spec.base_path
          ~team_session_id:spec.team_session_id ~worker_name:spec.worker_name
          meta
      in
      let* mcp_tools =
        Worker_container.build_oas_mcp_tools ~sw ~auth_token
          ~session_id:mcp_session_id ~worker_name:spec.worker_name
          ~prompt ~allowed_tools:spec.allowed_tools
      in
      let mcp_tools =
        List.map
          (Oas.Tool.with_defaults [ ("agent_name", `String spec.worker_name) ])
          mcp_tools
      in
      let* shell_tools =
        Worker_container.build_local_shell_tools ~room_config
          ~worker_name:spec.worker_name ~execution_scope
          ~workdir:workspace_path
      in
      let tools = mcp_tools @ shell_tools in
      let* raw_trace =
        match evidence_session_id with
        | Some trace_session_id ->
            Oas.Raw_trace.create_for_session
              ~session_root:
                (Worker_container.oas_trace_session_root
                   ~base_path:spec.base_path)
              ~session_id:trace_session_id ~agent_name:spec.worker_name ()
            |> Result.map_error Oas.Error.to_string
        | None -> (
            match spec.team_session_id with
            | Some trace_session_id ->
                Oas.Raw_trace.create_for_session
                  ~session_root:
                    (Worker_container.oas_trace_session_root
                       ~base_path:spec.base_path)
                  ~session_id:trace_session_id
                  ~agent_name:spec.worker_name ()
                |> Result.map_error Oas.Error.to_string
            | None ->
                Oas.Raw_trace.create ~session_id:mcp_session_id
                  ~path:
                    (Worker_container.worker_raw_trace_path
                       ~base_path:spec.base_path
                       ~team_session_id:spec.team_session_id
                       ~worker_name:spec.worker_name)
                  ()
                |> Result.map_error Oas.Error.to_string)
      in
      let gate_config =
        Worker_oas.gate_config_of_execution_scope meta.execution_scope
      in
      let* net = resolve_net ?net () in
      Worker_oas.run_worker_via_oas ~sw ~net ~base_path:spec.base_path ~meta
        ~provider ~system_prompt ~prompt ~tools ~raw_trace ~gate_config
        ?contract:(contract_of_spec ~execution_scope:(Some execution_scope) spec)
        ?worker_run_id:spec.worker_run_id ()
