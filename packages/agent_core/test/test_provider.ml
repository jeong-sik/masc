open Agent_sdk

let install_embedded_model_catalog () =
  Model_catalog_test_support.install_embedded_model_catalog ~suite:"provider"
;;

let declared_pricing model_id =
  match Llm_provider.Pricing.pricing_for_model_opt model_id with
  | Some pricing -> pricing
  | None -> Alcotest.failf "expected catalog pricing for %S" model_id
;;

let require_estimated_cost = function
  | Llm_provider.Pricing.Estimated cost -> cost
  | Llm_provider.Pricing.Incomplete _ -> Alcotest.fail "expected an exact cost estimate"
;;

let test_pricing_sonnet () =
  let p = declared_pricing "claude-sonnet-4-6-20250514" in
  Alcotest.(check (float 0.001)) "input/M" 3.0 p.input_per_million;
  Alcotest.(check (float 0.001)) "output/M" 15.0 p.output_per_million;
  Alcotest.(check (option (float 0.001)))
    "cache_write"
    (Some 1.25)
    p.cache_write_multiplier;
  Alcotest.(check (option (float 0.001))) "cache_read" (Some 0.1) p.cache_read_multiplier
;;

let test_pricing_gpt55 () =
  let p = declared_pricing "gpt-5.5" in
  Alcotest.(check (float 0.001)) "input/M" 5.0 p.input_per_million;
  Alcotest.(check (float 0.001)) "output/M" 30.0 p.output_per_million;
  Alcotest.(check (option (float 0.001)))
    "cache_write"
    (Some 1.0)
    p.cache_write_multiplier;
  Alcotest.(check (option (float 0.001))) "cache_read" (Some 0.1) p.cache_read_multiplier
;;

let test_incomplete_cache_pricing_remains_declared () =
  Alcotest.(check bool)
    "base price remains observable without inventing cache multipliers"
    true
    (match Llm_provider.Pricing.pricing_for_model_opt "dashscope-3.5-35b-a3b" with
     | Some
         { input_per_million = 0.0
         ; output_per_million = 0.0
         ; cache_write_multiplier = None
         ; cache_read_multiplier = None
         } -> true
     | Some _ | None -> false)
;;

let test_pricing_unknown () =
  Alcotest.(check bool)
    "unpriced"
    true
    (Option.is_none (Llm_provider.Pricing.pricing_for_model_opt "future-model-xyz"))
;;

let test_estimate_cost () =
  let p = declared_pricing "claude-sonnet-4-6" in
  let cost =
    Llm_provider.Pricing.estimate_cost
      ~pricing:p
      ~input_tokens:1_000_000
      ~output_tokens:500_000
      ~cache_creation_input_tokens:100_000
      ~cache_read_input_tokens:200_000
      ()
    |> require_estimated_cost
  in
  Alcotest.(check bool) "cost > 0" true (cost > 0.0)
;;

let test_provider_config_rebinds_model_specific_context () =
  let parent_capabilities =
    { Llm_provider.Capabilities.anthropic_capabilities with
      max_context_tokens = Some 12_345
    }
  in
  let parent =
    Llm_provider.Provider_config.make
      ~kind:Anthropic
      ~model_id:"claude-opus-4-1"
      ~base_url:"https://api.anthropic.com"
      ~max_context:12_345
      ~model_capabilities_override:parent_capabilities
      ()
  in
  let target_config = Types.default_config ~model:"claude-sonnet-4-5" in
  let target =
    Agent_turn.provider_config_with_agent_config ~config:target_config parent
  in
  let expected =
    let clean_target =
      { parent with
        model_id = "claude-sonnet-4-5"
      ; max_context = None
      ; model_capabilities_override = None
      ; supports_structured_output_override = None
      }
    in
    Option.bind
      (Llm_provider.Provider_config.capabilities_for_config_model clean_target)
      (fun capabilities -> capabilities.max_context_tokens)
  in
  Alcotest.(check string) "target model" "claude-sonnet-4-5" target.model_id;
  Alcotest.(check (option int)) "target context SSOT" expected target.max_context;
  Alcotest.(check bool)
    "parent model capability override is not inherited"
    true
    (Option.is_none target.model_capabilities_override)
;;

let () =
  install_embedded_model_catalog ();
  Alcotest.run
    "Provider"
    [ ( "pricing"
      , [ Alcotest.test_case "sonnet pricing" `Quick test_pricing_sonnet
        ; Alcotest.test_case "gpt-5.5 pricing" `Quick test_pricing_gpt55
        ; Alcotest.test_case
            "incomplete cache pricing remains declared"
            `Quick
            test_incomplete_cache_pricing_remains_declared
        ; Alcotest.test_case "unknown model" `Quick test_pricing_unknown
        ; Alcotest.test_case "estimate cost" `Quick test_estimate_cost
        ] )
    ; ( "provider_config"
      , [ Alcotest.test_case
            "model rebind clears parent context"
            `Quick
            test_provider_config_rebinds_model_specific_context
        ] )
    ]
;;
