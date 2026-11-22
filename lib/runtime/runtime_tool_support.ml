let declares_tools (runtime : Runtime_instance.t) =
  match runtime.execution with
  | Runtime_execution.Agent_core sealed ->
    (Agent_core.Provider_runtime_binding.capabilities_for_provider_config
       (Runtime_account_access.api_declaration sealed))
      .Llm_provider.Capabilities.supports_tools
  | Runtime_execution.Claude_code _
  | Runtime_execution.Codex_app_server _
  | Runtime_execution.Antigravity_cli _
  | Runtime_execution.Acp _ -> runtime.model.tools_support
;;
