open Llm_provider
open Types
module PC = Provider_config
module Anthropic = Backend_anthropic
module Gemini = Backend_gemini
module Glm = Backend_glm
module Ollama = Backend_ollama
module Openai = Backend_openai
module Responses = Backend_openai_responses

let () =
  match Model_catalog.load_default () with
  | Ok catalog -> Model_catalog.set_global catalog
  | Error message -> Alcotest.failf "failed to load the default model catalog: %s" message
;;

let declared_capabilities ceiling =
  { Capabilities.default_capabilities with max_output_tokens = Some ceiling }
;;

let check_receipt ~envelope ~requested ~effective ~policy ~ceiling ~ceiling_source receipt
  =
  Alcotest.(check bool)
    "receipt envelope"
    true
    (equal_output_token_envelope envelope (output_token_receipt_envelope receipt));
  Alcotest.(check (option int))
    "receipt requested"
    requested
    (output_token_receipt_requested receipt);
  Alcotest.(check (option int))
    "receipt effective"
    effective
    (output_token_receipt_effective receipt);
  Alcotest.(check bool)
    "receipt policy"
    true
    (equal_output_token_policy policy (output_token_receipt_policy receipt));
  Alcotest.(check (option int))
    "receipt ceiling"
    ceiling
    (output_token_receipt_ceiling receipt);
  Alcotest.(check bool)
    "receipt ceiling source"
    true
    (output_token_receipt_ceiling_source receipt = ceiling_source);
  let json = output_token_receipt_to_yojson receipt in
  let decoded =
    match output_token_receipt_of_yojson json with
    | Ok decoded -> decoded
    | Error message -> Alcotest.fail message
  in
  Alcotest.(check bool)
    "receipt JSON round trip"
    true
    (equal_output_token_receipt receipt decoded)
;;

let wire_int payload path =
  List.fold_left
    (fun json key -> Yojson.Safe.Util.member key json)
    (Yojson.Safe.from_string payload)
    path
  |> Yojson.Safe.Util.to_int
;;

let top_level_field_absent payload field =
  match Yojson.Safe.from_string payload with
  | `Assoc fields -> not (List.mem_assoc field fields)
  | `List _ | `String _ | `Int _ | `Intlit _ | `Float _ | `Bool _ | `Null -> false
;;

let check_scalar_codec label to_yojson fixtures =
  List.iter
    (fun (value, expected) ->
       Alcotest.(check string) label expected (Yojson.Safe.to_string (to_yojson value)))
    fixtures
;;

let test_stable_scalar_wire_vocabulary () =
  check_scalar_codec
    "envelope wire name"
    output_token_envelope_to_yojson
    [ Openai_chat_max_tokens, {|"openai_chat_max_tokens"|}
    ; Openai_responses_max_output_tokens, {|"openai_responses_max_output_tokens"|}
    ; Anthropic_messages_max_tokens, {|"anthropic_messages_max_tokens"|}
    ; ( Gemini_generation_config_max_output_tokens
      , {|"gemini_generation_config_max_output_tokens"|} )
    ; Ollama_options_num_predict, {|"ollama_options_num_predict"|}
    ];
  check_scalar_codec
    "policy wire name"
    output_token_policy_to_yojson
    [ Omitted, {|"omitted"|}
    ; Explicit, {|"explicit"|}
    ; Explicit_clamped, {|"explicit_clamped"|}
    ; Required_catalog_fallback, {|"required_catalog_fallback"|}
    ; Required_capability_override_fallback, {|"required_capability_override_fallback"|}
    ];
  check_scalar_codec
    "ceiling-source wire name"
    output_token_ceiling_source_to_yojson
    [ Catalog_model, {|"catalog_model"|}
    ; Declared_capability_override, {|"declared_capability_override"|}
    ; Provider_default, {|"provider_default"|}
    ];
  Alcotest.(check bool)
    "legacy ppx array encoding is rejected"
    true
    (Result.is_error (output_token_policy_of_yojson (`List [ `String "Explicit" ])))
;;

let test_exact_receipt_json_fixture () =
  let receipt =
    optional_output_token_receipt
      ~envelope:Gemini_generation_config_max_output_tokens
      ~requested:(Some 200)
      ~ceiling:
        (Some (output_token_ceiling ~value:100 ~source:Declared_capability_override))
  in
  Alcotest.(check string)
    "exact flat receipt JSON"
    {|{"requested":200,"effective":100,"policy":"explicit_clamped","ceiling":100,"ceiling_source":"declared_capability_override","envelope":"gemini_generation_config_max_output_tokens"}|}
    (Yojson.Safe.to_string (output_token_receipt_to_yojson receipt))
;;

let test_openai_chat_omission () =
  let config =
    PC.make
      ~kind:OpenAI_compat
      ~model_id:"receipt-openai-omission"
      ~base_url:""
      ~model_capabilities_override:(declared_capabilities 100)
      ()
  in
  let artifact = Openai.build_request_artifact ~config ~messages:[ user_msg "hi" ] () in
  let payload = Openai.request_payload artifact in
  Alcotest.(check string)
    "legacy payload projection"
    payload
    (Openai.build_request ~config ~messages:[ user_msg "hi" ] ());
  Alcotest.(check bool)
    "optional field omitted"
    true
    (top_level_field_absent payload "max_tokens");
  check_receipt
    ~envelope:Openai_chat_max_tokens
    ~requested:None
    ~effective:None
    ~policy:Omitted
    ~ceiling:(Some 100)
    ~ceiling_source:(Some Declared_capability_override)
    (Openai.request_output_token_receipt artifact)
;;

let test_openai_responses_exact () =
  let config =
    PC.make
      ~kind:OpenAI_compat
      ~model_id:"receipt-responses-exact"
      ~base_url:""
      ~max_tokens:80
      ~model_capabilities_override:(declared_capabilities 100)
      ()
  in
  let artifact =
    Responses.build_request_artifact ~config ~messages:[ user_msg "hi" ] ()
  in
  let payload = Responses.request_payload artifact in
  Alcotest.(check string)
    "legacy payload projection"
    payload
    (Responses.build_request ~config ~messages:[ user_msg "hi" ] ());
  Alcotest.(check int)
    "Responses max_output_tokens"
    80
    (wire_int payload [ "max_output_tokens" ]);
  check_receipt
    ~envelope:Openai_responses_max_output_tokens
    ~requested:(Some 80)
    ~effective:(Some 80)
    ~policy:Explicit
    ~ceiling:(Some 100)
    ~ceiling_source:(Some Declared_capability_override)
    (Responses.request_output_token_receipt artifact)
;;

let test_gemini_clamp () =
  let config =
    PC.make
      ~kind:Gemini
      ~model_id:"receipt-gemini-clamp"
      ~base_url:""
      ~max_tokens:200
      ~model_capabilities_override:(declared_capabilities 100)
      ()
  in
  let artifact = Gemini.build_request_artifact ~config ~messages:[ user_msg "hi" ] () in
  let payload = Gemini.request_payload artifact in
  Alcotest.(check string)
    "legacy payload projection"
    payload
    (Gemini.build_request ~config ~messages:[ user_msg "hi" ] ());
  Alcotest.(check int)
    "Gemini generationConfig.maxOutputTokens"
    100
    (wire_int payload [ "generationConfig"; "maxOutputTokens" ]);
  check_receipt
    ~envelope:Gemini_generation_config_max_output_tokens
    ~requested:(Some 200)
    ~effective:(Some 100)
    ~policy:Explicit_clamped
    ~ceiling:(Some 100)
    ~ceiling_source:(Some Declared_capability_override)
    (Gemini.request_output_token_receipt artifact)
;;

let test_ollama_exact () =
  let config =
    PC.make
      ~kind:Ollama
      ~model_id:"receipt-ollama-exact"
      ~base_url:""
      ~max_tokens:60
      ~model_capabilities_override:(declared_capabilities 100)
      ~keep_alive:"-1"
      ()
  in
  let artifact = Ollama.build_request_artifact ~config ~messages:[ user_msg "hi" ] () in
  let payload = Ollama.request_payload artifact in
  Alcotest.(check string)
    "legacy payload projection"
    payload
    (Ollama.build_request ~config ~messages:[ user_msg "hi" ] ());
  Alcotest.(check int)
    "Ollama options.num_predict"
    60
    (wire_int payload [ "options"; "num_predict" ]);
  check_receipt
    ~envelope:Ollama_options_num_predict
    ~requested:(Some 60)
    ~effective:(Some 60)
    ~policy:Explicit
    ~ceiling:(Some 100)
    ~ceiling_source:(Some Declared_capability_override)
    (Ollama.request_output_token_receipt artifact)
;;

let check_openai_chat_compatible_artifact ~label ~requested ~payload ~receipt =
  Alcotest.(check int) label requested (wire_int payload [ "max_tokens" ]);
  check_receipt
    ~envelope:Openai_chat_max_tokens
    ~requested:(Some requested)
    ~effective:(Some requested)
    ~policy:Explicit
    ~ceiling:(Some 100)
    ~ceiling_source:(Some Declared_capability_override)
    receipt
;;

let test_glm_and_dashscope_chat_envelopes () =
  let glm_config =
    PC.make
      ~kind:Glm
      ~model_id:"receipt-glm-chat"
      ~base_url:""
      ~max_tokens:70
      ~model_capabilities_override:(declared_capabilities 100)
      ()
  in
  let glm_artifact = Glm.build_request_artifact ~config:glm_config ~messages:[] () in
  let glm_payload = Glm.request_payload glm_artifact in
  Alcotest.(check string)
    "GLM legacy payload projection"
    glm_payload
    (Glm.build_request ~config:glm_config ~messages:[] ());
  check_openai_chat_compatible_artifact
    ~label:"GLM max_tokens"
    ~requested:70
    ~payload:glm_payload
    ~receipt:(Glm.request_output_token_receipt glm_artifact);
  let dashscope_config =
    PC.make
      ~kind:DashScope
      ~model_id:"receipt-dashscope-chat"
      ~base_url:""
      ~max_tokens:60
      ~model_capabilities_override:(declared_capabilities 100)
      ()
  in
  let dashscope_artifact =
    Openai.build_request_artifact ~config:dashscope_config ~messages:[] ()
  in
  let dashscope_payload = Openai.request_payload dashscope_artifact in
  Alcotest.(check string)
    "DashScope legacy payload projection"
    dashscope_payload
    (Openai.build_request ~config:dashscope_config ~messages:[] ());
  check_openai_chat_compatible_artifact
    ~label:"DashScope max_tokens"
    ~requested:60
    ~payload:dashscope_payload
    ~receipt:(Openai.request_output_token_receipt dashscope_artifact)
;;

let test_glm_provider_default_clamp () =
  let model_id = "receipt-uncatalogued-glm-provider-default" in
  let provider_default_ceiling =
    match Capabilities.glm_capabilities.max_output_tokens with
    | Some value -> value
    | None -> Alcotest.fail "GLM provider default must declare max_output_tokens"
  in
  let requested = provider_default_ceiling + 1 in
  let config = PC.make ~kind:Glm ~model_id ~base_url:"" ~max_tokens:requested () in
  Alcotest.(check bool)
    "regression precondition: no model-catalog capabilities"
    true
    (Option.is_none (PC.capabilities_for_config_model config));
  let drops = ref [] in
  let previous_metrics = Metrics.get_global () in
  let artifact =
    Fun.protect
      ~finally:(fun () -> Metrics.set_global previous_metrics)
      (fun () ->
         Metrics.set_global
           { Metrics.noop with
             on_capability_drop =
               (fun ~model_id ~field -> drops := (model_id, field) :: !drops)
           };
         Glm.build_request_artifact ~config ~messages:[] ())
  in
  let payload = Glm.request_payload artifact in
  Alcotest.(check int)
    "GLM provider-default ceiling clamps the wire value"
    provider_default_ceiling
    (wire_int payload [ "max_tokens" ]);
  check_receipt
    ~envelope:Openai_chat_max_tokens
    ~requested:(Some requested)
    ~effective:(Some provider_default_ceiling)
    ~policy:Explicit_clamped
    ~ceiling:(Some provider_default_ceiling)
    ~ceiling_source:(Some Provider_default)
    (Glm.request_output_token_receipt artifact);
  match !drops with
  | [ (dropped_model_id, field) ] ->
    Alcotest.(check string) "clamp warning model" model_id dropped_model_id;
    Alcotest.(check string) "clamp warning field" "max_tokens:clamp" field
  | drops ->
    Alcotest.failf
      "expected one provider-default clamp warning, received %d"
      (List.length drops)
;;

let require_anthropic_artifact = function
  | Ok artifact -> artifact
  | Error Required_output_token_ceiling_missing ->
    Alcotest.fail "expected a required Messages output-token decision"
;;

let test_anthropic_catalog_fallback () =
  let model_id = "claude-sonnet-4-6" in
  let ceiling =
    match Capabilities.for_model_id model_id with
    | Some capabilities ->
      (match capabilities.max_output_tokens with
       | Some value -> value
       | None -> Alcotest.fail "catalog model must declare max_output_tokens")
    | None -> Alcotest.fail "catalog model must exist"
  in
  let config = PC.make ~kind:Anthropic ~model_id ~base_url:"" () in
  let artifact =
    Anthropic.build_request_artifact ~config ~messages:[ user_msg "hi" ] ()
    |> require_anthropic_artifact
  in
  let payload = Anthropic.request_payload artifact in
  Alcotest.(check string)
    "legacy payload projection"
    payload
    (Anthropic.build_request ~config ~messages:[ user_msg "hi" ] ());
  Alcotest.(check int)
    "Anthropic required max_tokens"
    ceiling
    (wire_int payload [ "max_tokens" ]);
  check_receipt
    ~envelope:Anthropic_messages_max_tokens
    ~requested:None
    ~effective:(Some ceiling)
    ~policy:Required_catalog_fallback
    ~ceiling:(Some ceiling)
    ~ceiling_source:(Some Catalog_model)
    (Anthropic.request_output_token_receipt artifact)
;;

let check_messages_override_fallback ~kind ~model_id =
  let config =
    PC.make
      ~kind
      ~model_id
      ~base_url:""
      ~model_capabilities_override:(declared_capabilities 321)
      ()
  in
  let artifact =
    Anthropic.build_request_artifact ~config ~messages:[ user_msg "hi" ] ()
    |> require_anthropic_artifact
  in
  let payload = Anthropic.request_payload artifact in
  Alcotest.(check string)
    "legacy payload projection"
    payload
    (Anthropic.build_request ~config ~messages:[ user_msg "hi" ] ());
  Alcotest.(check int)
    "Messages required max_tokens"
    321
    (wire_int payload [ "max_tokens" ]);
  check_receipt
    ~envelope:Anthropic_messages_max_tokens
    ~requested:None
    ~effective:(Some 321)
    ~policy:Required_capability_override_fallback
    ~ceiling:(Some 321)
    ~ceiling_source:(Some Declared_capability_override)
    (Anthropic.request_output_token_receipt artifact)
;;

let test_anthropic_and_kimi_override_fallbacks () =
  check_messages_override_fallback ~kind:Anthropic ~model_id:"receipt-anthropic-override";
  check_messages_override_fallback ~kind:Kimi ~model_id:"receipt-kimi-messages-override"
;;

let test_anthropic_missing_required_ceiling_is_typed () =
  let config =
    PC.make ~kind:Anthropic ~model_id:"receipt-required-missing" ~base_url:"" ()
  in
  Alcotest.(check bool)
    "receipt resolver returns typed missing-ceiling error"
    true
    (Anthropic.required_output_token_receipt config
     = Error Required_output_token_ceiling_missing);
  Alcotest.(check bool)
    "artifact builder returns typed missing-ceiling error"
    true
    (match Anthropic.build_request_artifact ~config ~messages:[ user_msg "hi" ] () with
     | Error Required_output_token_ceiling_missing -> true
     | Ok _ -> false);
  Alcotest.(check bool)
    "legacy payload projection fails loudly"
    true
    (match Anthropic.build_request ~config ~messages:[ user_msg "hi" ] () with
     | exception Invalid_argument _ -> true
     | _ -> false)
;;

let test_anthropic_zero_is_explicit () =
  let provider_default_ceiling =
    match Capabilities.anthropic_capabilities.max_output_tokens with
    | Some value -> value
    | None -> Alcotest.fail "Anthropic provider default must declare an output ceiling"
  in
  let config =
    PC.make
      ~kind:Anthropic
      ~model_id:"receipt-explicit-zero"
      ~base_url:""
      ~max_tokens:0
      ()
  in
  let artifact =
    Anthropic.build_request_artifact ~config ~messages:[ user_msg "prewarm" ] ()
    |> require_anthropic_artifact
  in
  let payload = Anthropic.request_payload artifact in
  Alcotest.(check int) "explicit zero on wire" 0 (wire_int payload [ "max_tokens" ]);
  check_receipt
    ~envelope:Anthropic_messages_max_tokens
    ~requested:(Some 0)
    ~effective:(Some 0)
    ~policy:Explicit
    ~ceiling:(Some provider_default_ceiling)
    ~ceiling_source:(Some Provider_default)
    (Anthropic.request_output_token_receipt artifact)
;;

let () =
  Alcotest.run
    "output_token_receipt"
    [ ( "wire_codec"
      , [ Alcotest.test_case
            "stable scalar vocabulary"
            `Quick
            test_stable_scalar_wire_vocabulary
        ; Alcotest.test_case "exact receipt JSON" `Quick test_exact_receipt_json_fixture
        ] )
    ; ( "optional_envelopes"
      , [ Alcotest.test_case "OpenAI Chat omission" `Quick test_openai_chat_omission
        ; Alcotest.test_case "OpenAI Responses exact" `Quick test_openai_responses_exact
        ; Alcotest.test_case "Gemini clamp" `Quick test_gemini_clamp
        ; Alcotest.test_case "Ollama exact" `Quick test_ollama_exact
        ; Alcotest.test_case
            "GLM and DashScope Chat envelopes"
            `Quick
            test_glm_and_dashscope_chat_envelopes
        ; Alcotest.test_case
            "GLM provider-default clamp"
            `Quick
            test_glm_provider_default_clamp
        ] )
    ; ( "required_messages_envelope"
      , [ Alcotest.test_case
            "Anthropic catalog fallback"
            `Quick
            test_anthropic_catalog_fallback
        ; Alcotest.test_case
            "Anthropic and Kimi override fallbacks"
            `Quick
            test_anthropic_and_kimi_override_fallbacks
        ; Alcotest.test_case
            "missing required ceiling is typed"
            `Quick
            test_anthropic_missing_required_ceiling_is_typed
        ; Alcotest.test_case
            "explicit zero remains explicit"
            `Quick
            test_anthropic_zero_is_explicit
        ] )
    ]
;;
