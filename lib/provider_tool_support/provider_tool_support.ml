let agent_core_capabilities_of_config provider_cfg =
  Agent_core.Provider_runtime_binding.capabilities_for_provider_config provider_cfg
;;

let provider_supports_inline_tools provider_cfg =
  let capabilities = agent_core_capabilities_of_config provider_cfg in
  capabilities.supports_tools
;;
