open Alcotest

let provider_kinds providers =
  List.map
    (fun (cfg : Llm_provider.Provider_config.t) ->
      Llm_provider.Provider_config.string_of_provider_kind cfg.kind)
    providers

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

let () =
  run "Cascade_runtime"
    [
      ( "provider_filter",
        [
          test_case "applies direct model string filter" `Quick
            test_provider_filter_is_applied_to_direct_model_strings;
          test_case "falls back when filter matches nothing" `Quick
            test_provider_filter_falls_back_to_unfiltered_when_no_match;
        ] );
    ]
