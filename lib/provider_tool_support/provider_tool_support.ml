type capabilities =
  { supports_inline_tools : bool
  ; supports_inline_tool_choice : bool
  ; supports_runtime_mcp_tools : bool
  ; supports_runtime_tool_events : bool
  }

type runtime_capabilities_override =
  { supports_inline_tools : bool option
  ; supports_inline_tool_choice : bool option
  ; supports_runtime_mcp_tools : bool option
  ; supports_runtime_tool_events : bool option
  }

let oas_capabilities_of_config provider_cfg =
  Agent_sdk.Provider_runtime_binding.capabilities_for_provider_config provider_cfg
;;

let apply_override
    (base : capabilities)
    (override : runtime_capabilities_override option)
  =
  match override with
  | None -> base
  | Some override ->
    { supports_inline_tools =
        Option.value
          override.supports_inline_tools
          ~default:base.supports_inline_tools
    ; supports_inline_tool_choice =
        Option.value
          override.supports_inline_tool_choice
          ~default:base.supports_inline_tool_choice
    ; supports_runtime_mcp_tools =
        Option.value
          override.supports_runtime_mcp_tools
          ~default:base.supports_runtime_mcp_tools
    ; supports_runtime_tool_events =
        Option.value
          override.supports_runtime_tool_events
          ~default:base.supports_runtime_tool_events
    }
;;

let capabilities_of_config ?override provider_cfg =
  let capabilities = oas_capabilities_of_config provider_cfg in
  apply_override
    { supports_inline_tools = capabilities.supports_tools
    ; supports_inline_tool_choice =
        capabilities.supports_tools && capabilities.supports_tool_choice
    ; supports_runtime_mcp_tools = capabilities.supports_runtime_mcp_tools
    ; supports_runtime_tool_events = capabilities.supports_runtime_tool_events
    }
    override
;;

let provider_supports_inline_tools ?override provider_cfg =
  (capabilities_of_config ?override provider_cfg).supports_inline_tools
;;

let provider_supports_runtime_mcp_lane ?override provider_cfg =
  let capabilities = capabilities_of_config ?override provider_cfg in
  capabilities.supports_runtime_mcp_tools
  && capabilities.supports_runtime_tool_events
;;

let provider_debug_label (config : Llm_provider.Provider_config.t) =
  Printf.sprintf
    "%s:%s"
    (Llm_provider.Provider_config.string_of_provider_kind config.kind)
    config.model_id
;;

let provider_kind_label (config : Llm_provider.Provider_config.t) =
  Llm_provider.Provider_config.string_of_provider_kind config.kind
;;
