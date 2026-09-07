open Agent_core

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

let test_multipart_body_shape () =
  let boundary = "probe-boundary" in
  let body =
    Llm_provider.Provider_files.multipart_upload_body ~boundary
      ~filename:"probe.png" ~purpose:"user_data" ~content:"PNGDATA"
  in
  let has needle =
    let open Stdlib in
    let rec find haystack_start =
      if String.length body - haystack_start < String.length needle then false
      else if String.sub body haystack_start (String.length needle) = needle
      then true
      else find (haystack_start + 1)
    in
    find 0
  in
  Alcotest.(check bool) "file part" true (has "name=\"file\"; filename=\"probe.png\"");
  Alcotest.(check bool) "purpose part" true (has "name=\"purpose\"");
  Alcotest.(check bool) "purpose value after blank line" true (has "\r\n\r\nuser_data\r\n");
  Alcotest.(check bool) "closing boundary" true (has "--probe-boundary--\r\n")
;;

let test_file_object_decode () =
  match
    Llm_provider.Provider_files.file_object_of_yojson
      (Yojson.Safe.from_string
         {| {"id":"file-api-1","bytes":137,"created_at":1788676840,"filename":"p.png","purpose":"user_data"} |})
  with
  | Ok obj ->
    Alcotest.(check string) "id" "file-api-1" obj.Llm_provider.Provider_files.id;
    Alcotest.(check int) "bytes" 137 obj.Llm_provider.Provider_files.bytes;
    Alcotest.(check string) "filename" "p.png" obj.Llm_provider.Provider_files.filename
  | Error detail -> Alcotest.failf "expected a decode, got %s" detail
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

(* A model that declares base prices and no cache multipliers stays priced,
   with the multipliers absent rather than invented.

   Read off the catalog rather than one model id. This named
   "qwen3.5-35b-a3b" until that row stopped declaring prices, and the failure
   could not say whether the rule had broken or the row had moved: the id now
   resolves to the provider-less "qwen3" entry, which declares no prices at
   all, so [pricing_for_model_opt] answers None and the case fails on a model
   that was never the subject. 22 rows carry the shape today. *)
let test_incomplete_cache_pricing_remains_declared () =
  let catalog =
    match Llm_provider.Model_catalog.global () with
    | Some catalog -> catalog
    | None -> Alcotest.fail "no model catalog is installed"
  in
  let declares_base_prices_only (entry : Llm_provider.Model_catalog.model_entry) =
    (* Provider-less rows only: [pricing_for_model_opt] without a provider id
       looks at exactly those, so a scoped row would not be reachable here. *)
    Option.is_none entry.provider_name
    && Option.is_some entry.input_per_million
    && Option.is_some entry.output_per_million
    && Option.is_none entry.cache_write_multiplier
    && Option.is_none entry.cache_read_multiplier
  in
  let entries =
    List.filter declares_base_prices_only
      (Llm_provider.Model_catalog.model_entries catalog)
  in
  (* Without this the case passes on an empty catalog and pins nothing. *)
  Alcotest.(check bool)
    "the catalog still declares a model of this shape"
    true
    (entries <> []);
  List.iter
    (fun (entry : Llm_provider.Model_catalog.model_entry) ->
      match Llm_provider.Pricing.pricing_for_model_opt entry.id_prefix with
      | None ->
        Alcotest.failf
          "%s declares base prices and they are not observable"
          entry.id_prefix
      | Some (pricing : Llm_provider.Pricing.pricing) ->
        Alcotest.(check bool)
          (entry.id_prefix ^ ": no cache multiplier is invented")
          true
          (Option.is_none pricing.cache_write_multiplier
           && Option.is_none pricing.cache_read_multiplier))
    entries
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
    ; ( "provider_files"
      , [ Alcotest.test_case
            "multipart body carries both form parts and the closing boundary"
            `Quick test_multipart_body_shape
        ; Alcotest.test_case
            "file object decodes id/bytes/filename/purpose"
            `Quick test_file_object_decode
        ] )
    ]
;;
