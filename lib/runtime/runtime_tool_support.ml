let declares_tools (runtime : Runtime_instance.t) =
  match runtime.execution with
  | Runtime_execution.Agent_core sealed ->
    Provider_tool_support.provider_supports_inline_tools
      (Runtime_account_access.api_declaration sealed)
  | Runtime_execution.Claude_code _
  | Runtime_execution.Codex_app_server _
  | Runtime_execution.Antigravity_cli _
  | Runtime_execution.Muse_serve _
  | Runtime_execution.Vibe_cli _ -> runtime.model.tools_support
;;
