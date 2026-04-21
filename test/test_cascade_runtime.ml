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
  let registry = Llm_provider.Provider_registry.default () in
  let provider_name = Masc_mcp.Provider_adapter.string_of_provider_kind cfg.kind in
  let caps =
    match Llm_provider.Provider_registry.find registry provider_name with
    | Some entry -> entry.capabilities
    | None -> Llm_provider.Capabilities.default_capabilities
  in
  let caps =
    match cfg.supports_tool_choice_override with
    | Some supports_tool_choice -> { caps with supports_tool_choice }
    | None -> caps
  in
  caps.supports_tools && caps.supports_tool_choice

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
  [ "codex_cli:auto"
  ; "gemini_cli:auto"
  ; "ollama:local-model"
  ; "llama:qwen3.5-3b-a3b-ud-q8-xl"
  ]

let test_required_tool_choice_filter_keeps_only_supported_providers () =
  let providers =
    Masc_mcp.Cascade_runtime.resolve_providers_from_model_strings
      ~require_tool_choice_support:true
      tool_required_model_strings
  in
  check bool "tool-required path keeps at least one callable provider" true
    (providers <> []);
  check bool "every surviving provider satisfies required tool-use capabilities" true
    (List.for_all provider_supports_required_tool_use providers)

let test_required_tool_choice_filter_can_exhaust_candidates () =
  let providers =
    Masc_mcp.Cascade_runtime.resolve_providers_from_model_strings
      ~require_tool_choice_support:true
      [ "ollama:local-model" ]
  in
  check (list string) "unsupported-only candidate set becomes empty" []
    (provider_kind_models providers)

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
        ] );
    ]
