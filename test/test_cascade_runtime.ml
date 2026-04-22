open Alcotest

let provider_kinds providers =
  List.map
    (fun (cfg : Llm_provider.Provider_config.t) ->
      Llm_provider.Provider_config.string_of_provider_kind cfg.kind)
    providers

let provider_kind_models providers =
  List.map
    (fun (cfg : Llm_provider.Provider_config.t) ->
      Printf.sprintf "%s:%s"
        (Llm_provider.Provider_config.string_of_provider_kind cfg.kind)
        cfg.model_id)
    providers

let provider_supports_required_tool_use (cfg : Llm_provider.Provider_config.t) =
  let caps = Masc_mcp.Oas_worker_exec.provider_caps_of_config cfg in
  caps.supports_tools && caps.supports_tool_choice

let provider_supports_callable_tool_use (cfg : Llm_provider.Provider_config.t) =
  let caps = Masc_mcp.Oas_worker_exec.provider_caps_of_config cfg in
  caps.supports_tools
  || (caps.supports_runtime_mcp_tools && caps.supports_runtime_tool_events)

let direct_model_strings =
  [ "ollama:local-model"
  ; "custom:remote-model@http://127.0.0.1:18080/v1"
  ]

let test_provider_filter_is_applied_to_direct_model_strings () =
  let providers =
    Masc_mcp.Cascade_runtime.resolve_providers_from_model_strings
      ~provider_filter:[ "openai_compat" ]
      direct_model_strings
  in
  check (list string) "filtered to requested provider kind"
    [ "openai_compat" ] (provider_kinds providers)

let test_provider_filter_falls_back_to_unfiltered_when_no_match () =
  let providers =
    Masc_mcp.Cascade_runtime.resolve_providers_from_model_strings
      ~provider_filter:[ "gemini" ]
      direct_model_strings
  in
  check (list string) "no-match filter falls back to unfiltered providers"
    [ "ollama"; "openai_compat" ] (provider_kinds providers)

let tool_required_model_strings =
  [ "custom:remote-model@http://127.0.0.1:18080/v1"
  ; "codex_cli:auto"
  ; "gemini_cli:auto"
  ; "ollama:local-model"
  ]

let callable_tool_required_model_strings =
  [ "custom:remote-model@http://127.0.0.1:18080/v1"
  ; "claude_code:auto"
  ; "codex_cli:auto"
  ; "kimi_cli:auto"
  ; "gemini_cli:auto"
  ; "ollama:local-model"
  ]

let runtime_mcp_policy_with_headers =
  {
    Llm_provider.Llm_transport.empty_runtime_mcp_policy with
    servers =
      [
        Llm_provider.Llm_transport.Http_server
          {
            name = "masc";
            url = "http://127.0.0.1:8935/mcp";
            headers = [ ("x-masc-agent-name", "keeper-sangsu-agent") ];
          };
      ];
    allowed_server_names = [ "masc" ];
    allowed_tool_names = [ "masc_status" ];
    strict = true;
    disable_builtin_tools = true;
  }

let test_required_tool_choice_filter_keeps_only_supported_providers () =
  let providers =
    Masc_mcp.Cascade_runtime.resolve_providers_from_model_strings
      ~require_tool_choice_support:true
      tool_required_model_strings
  in
  check bool "every surviving provider satisfies required tool-use capabilities" true
    (List.for_all provider_supports_required_tool_use providers);
  check bool "drops codex_cli without inline tool choice" false
    (List.mem "codex_cli" (provider_kinds providers));
  check bool "drops gemini_cli without inline tool choice" false
    (List.mem "gemini_cli" (provider_kinds providers))

let test_required_tool_choice_filter_can_exhaust_candidates () =
  let providers =
    Masc_mcp.Cascade_runtime.resolve_providers_from_model_strings
      ~require_tool_choice_support:true
      [ "ollama:local-model" ]
  in
  check (list string) "unsupported-only candidate set becomes empty" []
    (provider_kind_models providers)

let test_required_tool_support_filter_keeps_inline_or_runtime_capable_providers () =
  let providers =
    Masc_mcp.Cascade_runtime.resolve_providers_from_model_strings
      ~require_tool_support:true
      callable_tool_required_model_strings
  in
  check bool "tool-support path keeps at least one callable provider" true
    (providers <> []);
  check bool "every surviving provider supports inline or runtime MCP tools" true
    (List.for_all provider_supports_callable_tool_use providers);
  check bool "drops gemini_cli without runtime MCP lane" false
    (List.mem "gemini_cli" (provider_kinds providers))

let test_required_tool_gate_filter_keeps_runtime_mcp_capable_cli_providers () =
  let providers =
    Masc_mcp.Cascade_runtime.resolve_providers_from_model_strings
      ~require_tool_choice_support:true
      ~require_tool_support:true
      callable_tool_required_model_strings
  in
  check bool "tool gate keeps at least one callable provider" true
    (providers <> []);
  check bool "keeps kimi_cli via runtime MCP lane" true
    (List.mem "kimi_cli" (provider_kinds providers));
  check bool "drops gemini_cli without runtime MCP lane" false
    (List.mem "gemini_cli" (provider_kinds providers))

let test_required_tool_support_filter_drops_runtime_mcp_providers_without_header_support () =
  let providers =
    Masc_mcp.Cascade_runtime.resolve_providers_from_model_strings
      ~require_tool_support:true
      ~runtime_mcp_policy:runtime_mcp_policy_with_headers
      callable_tool_required_model_strings
  in
  check bool "drops codex_cli when runtime MCP headers are required" false
    (List.mem "codex_cli" (provider_kinds providers));
  check bool "keeps kimi_cli with runtime MCP header support" true
    (List.mem "kimi_cli" (provider_kinds providers));
  check bool "keeps claude_code with runtime MCP header support" true
    (List.mem "claude_code" (provider_kinds providers))

let () =
  run "Cascade_runtime"
    [
      ( "provider_filter",
        [
          test_case "applies direct model string filter" `Quick
            test_provider_filter_is_applied_to_direct_model_strings;
          test_case "falls back when filter matches nothing" `Quick
            test_provider_filter_falls_back_to_unfiltered_when_no_match;
          test_case "required tool choice keeps only supported providers" `Quick
            test_required_tool_choice_filter_keeps_only_supported_providers;
          test_case "required tool choice can exhaust candidates" `Quick
            test_required_tool_choice_filter_can_exhaust_candidates;
          test_case "required tool support keeps inline or runtime-capable providers"
            `Quick
            test_required_tool_support_filter_keeps_inline_or_runtime_capable_providers;
          test_case "tool gate keeps runtime MCP-capable CLI providers" `Quick
            test_required_tool_gate_filter_keeps_runtime_mcp_capable_cli_providers;
          test_case "runtime MCP header requirement drops unsupported providers"
            `Quick
            test_required_tool_support_filter_drops_runtime_mcp_providers_without_header_support;
        ] );
    ]
