open Llm_provider

let budget_testable = Alcotest.testable Input_budget.pp_budget Input_budget.equal_budget
let t_testable = Alcotest.testable Input_budget.pp Input_budget.equal
let err_testable = Alcotest.testable Input_budget.pp_error Input_budget.equal_error
let fit_testable = Alcotest.testable Input_budget.pp_context_fit Input_budget.equal_context_fit

let receipt_testable =
  Alcotest.testable
    (fun fmt r ->
       Format.pp_print_string
         fmt
         (Yojson.Safe.to_string (Types.output_token_receipt_to_yojson r)))
    Types.equal_output_token_receipt
;;

let msg = [ Types.user_msg "hello" ]

let caps ~base ~max_context ~max_output =
  { base with
    Capabilities.max_context_tokens = max_context
  ; max_output_tokens = max_output
  }
;;

let test_omitted_optional_envelopes_reserve_zero () =
  let cases =
    [ ( "openai_chat"
      , Provider_config.OpenAI_compat
      , "/v1/chat/completions"
      , caps ~base:Capabilities.openai_compat_chat_capabilities ~max_context:(Some 400_000) ~max_output:(Some 128_000)
      , fun cfg ->
          Backend_openai.build_request_artifact ~config:cfg ~messages:msg ()
          |> Backend_openai.request_output_token_receipt )
    ; ( "openai_responses"
      , Provider_config.OpenAI_compat
      , "/v1/responses"
      , caps ~base:Capabilities.openai_compat_chat_capabilities ~max_context:(Some 400_000) ~max_output:(Some 128_000)
      , fun cfg ->
          Backend_openai_responses.build_request_artifact ~config:cfg ~messages:msg ()
          |> Backend_openai_responses.request_output_token_receipt )
    ; ( "ollama_chat"
      , Provider_config.Ollama
      , "/api/chat"
      , caps ~base:Capabilities.ollama_capabilities ~max_context:(Some 32_768) ~max_output:(Some 8_192)
      , fun cfg ->
          Backend_ollama.build_request_artifact ~config:cfg ~messages:msg ()
          |> Backend_ollama.request_output_token_receipt )
    ; ( "gemini"
      , Provider_config.Gemini
      , "/v1beta/models"
      , caps ~base:Capabilities.gemini_capabilities ~max_context:(Some 1_000_000) ~max_output:(Some 65_536)
      , fun cfg ->
          Backend_gemini.build_request_artifact ~config:cfg ~messages:msg ()
          |> Backend_gemini.request_output_token_receipt )
    ; ( "glm_chat"
      , Provider_config.Glm
      , "/v1/chat/completions"
      , caps ~base:Capabilities.glm_capabilities ~max_context:(Some 200_000) ~max_output:(Some 131_072)
      , fun cfg ->
          Backend_glm.build_request_artifact ~config:cfg ~messages:msg ()
          |> Backend_glm.request_output_token_receipt )
    ]
  in
  List.iter
    (fun (label, kind, request_path, override, backend_receipt) ->
       let cfg =
         Provider_config.make
           ~kind
           ~model_id:("test-" ^ label)
           ~base_url:"https://api.example.test"
           ~request_path
           ~model_capabilities_override:override
           ()
       in
       let expected_window = Option.get override.Capabilities.max_context_tokens in
       let expected_budget = Input_budget.resolve cfg in
       (match expected_budget with
        | Ok b ->
          Alcotest.(check int) (label ^ " reserves 0 when omitted") 0 b.reserved_output_tokens;
          Alcotest.(check int)
            (label ^ " max_input_tokens equals window")
            expected_window
            (b.max_input_tokens :> int)
        | Error err ->
          Alcotest.failf "%s expected Ok budget, got %s" label (Input_budget.error_to_string err));
       let resolved_receipt = Input_budget.resolve_output_token_receipt cfg |> Result.get_ok in
       Alcotest.check
         receipt_testable
         (label ^ " receipt matches serializer")
         (backend_receipt cfg)
         resolved_receipt)
    cases
;;

let test_explicit_and_clamped_reservations () =
  let caps_53504 =
    caps
      ~base:Capabilities.openai_compat_chat_capabilities
      ~max_context:(Some 400_000)
      ~max_output:(Some 128_000)
  in
  let cfg_53504 =
    Provider_config.make
      ~kind:Provider_config.OpenAI_compat
      ~model_id:"gpt-5.4"
      ~base_url:"https://api.example.test"
      ~request_path:"/v1/responses"
      ~max_tokens:128_000
      ~model_capabilities_override:caps_53504
      ()
  in
  (match Input_budget.resolve cfg_53504, Input_budget.of_provider_config cfg_53504 with
   | Ok b, Ok limit ->
     Alcotest.(check int) "#53504 window" 400_000 b.max_context_tokens;
     Alcotest.(check int) "#53504 reserved" 128_000 b.reserved_output_tokens;
     Alcotest.(check int) "#53504 input limit" 272_000 (Input_budget.to_int limit);
     Alcotest.(check bool) "272_000 admitted" true (Input_budget.admits limit ~input_tokens:272_000);
     Alcotest.(check bool)
       "272_780 rejected"
       false
       (Input_budget.admits limit ~input_tokens:272_780)
   | _ -> Alcotest.fail "expected #53504 budget to resolve");
  let clamped_caps =
    caps
      ~base:Capabilities.openai_compat_chat_capabilities
      ~max_context:(Some 128_000)
      ~max_output:(Some 16_384)
  in
  let clamped_cfg =
    Provider_config.make
      ~kind:Provider_config.OpenAI_compat
      ~model_id:"gpt-clamped"
      ~base_url:"https://api.example.test"
      ~max_tokens:32_000
      ~model_capabilities_override:clamped_caps
      ()
  in
  let clamped = Input_budget.resolve clamped_cfg |> Result.get_ok in
  Alcotest.(check int) "clamped reserves ceiling" 16_384 clamped.reserved_output_tokens;
  Alcotest.(check int) "clamped input limit" 111_616 (clamped.max_input_tokens :> int);
  let receipt = Input_budget.resolve_output_token_receipt clamped_cfg |> Result.get_ok in
  let serialized_receipt =
    Backend_openai.build_request_artifact ~config:clamped_cfg ~messages:msg ()
    |> Backend_openai.request_output_token_receipt
  in
  Alcotest.check receipt_testable "clamped receipt matches serializer" serialized_receipt receipt
;;

let test_anthropic_and_kimi_required_reservations () =
  let anthropic_caps =
    caps
      ~base:Capabilities.anthropic_capabilities
      ~max_context:(Some 1_000_000)
      ~max_output:(Some 128_000)
  in
  let cfg_fallback =
    Provider_config.make
      ~kind:Provider_config.Anthropic
      ~model_id:"claude-sonnet-test"
      ~base_url:"https://api.anthropic.com"
      ~model_capabilities_override:anthropic_caps
      ()
  in
  let b = Input_budget.resolve cfg_fallback |> Result.get_ok in
  Alcotest.(check int) "Anthropic fallback reserved" 128_000 b.reserved_output_tokens;
  Alcotest.(check int) "Anthropic fallback input limit" 872_000 (b.max_input_tokens :> int);
  let artifact =
    Backend_anthropic.build_request_artifact ~config:cfg_fallback ~messages:msg ()
    |> Result.get_ok
  in
  Alcotest.check
    receipt_testable
    "Anthropic receipt matches serializer"
    (Backend_anthropic.request_output_token_receipt artifact)
    (Input_budget.resolve_output_token_receipt cfg_fallback |> Result.get_ok);
  let kimi_caps =
    caps ~base:Capabilities.kimi_capabilities ~max_context:(Some 256_000) ~max_output:(Some 32_768)
  in
  let cfg_kimi =
    Provider_config.make
      ~kind:Provider_config.Kimi
      ~model_id:"kimi-test"
      ~base_url:"https://api.kimi.com/coding"
      ~model_capabilities_override:kimi_caps
      ()
  in
  Alcotest.(check (result int err_testable))
    "Kimi fallback input limit"
    (Ok 223_232)
    (Input_budget.of_provider_config cfg_kimi |> Result.map Input_budget.to_int);
  let missing_out_caps =
    caps ~base:Capabilities.anthropic_capabilities ~max_context:(Some 200_000) ~max_output:None
  in
  let cfg_missing_out =
    Provider_config.make
      ~kind:Provider_config.Anthropic
      ~model_id:"anthropic-no-ceiling"
      ~base_url:"https://api.anthropic.com"
      ~model_capabilities_override:missing_out_caps
      ()
  in
  Alcotest.(check (result t_testable err_testable))
    "Anthropic missing ceiling fails closed"
    (Error (Input_budget.Missing_required_output_reservation { model_id = "anthropic-no-ceiling" }))
    (Input_budget.of_provider_config cfg_missing_out)
;;

let test_error_boundaries () =
  let unknown_ctx =
    Provider_config.make
      ~kind:Provider_config.OpenAI_compat
      ~model_id:"unknown-window-model"
      ~base_url:"https://api.example.test"
      ~max_tokens:1024
      ()
  in
  Alcotest.(check (result t_testable err_testable))
    "Missing_context_window"
    (Error (Input_budget.Missing_context_window { model_id = "unknown-window-model" }))
    (Input_budget.of_provider_config unknown_ctx);
  let zero_ctx =
    Provider_config.make
      ~kind:Provider_config.OpenAI_compat
      ~model_id:"zero-window"
      ~base_url:"https://api.example.test"
      ~max_context:0
      ~max_tokens:100
      ()
  in
  Alcotest.(check (result t_testable err_testable))
    "Non_positive_context_window"
    (Error
       (Input_budget.Non_positive_context_window
          { model_id = "zero-window"; max_context_tokens = 0 }))
    (Input_budget.of_provider_config zero_ctx);
  let eq_caps =
    caps
      ~base:Capabilities.openai_compat_chat_capabilities
      ~max_context:(Some 1_000)
      ~max_output:(Some 2_000)
  in
  let eq_cfg =
    Provider_config.make
      ~kind:Provider_config.OpenAI_compat
      ~model_id:"eq-bound"
      ~base_url:"https://api.example.test"
      ~max_tokens:1_000
      ~model_capabilities_override:eq_caps
      ()
  in
  Alcotest.(check (result budget_testable err_testable))
    "reserved = window fails closed"
    (Error
       (Input_budget.Output_reservation_exceeds_window
          { model_id = "eq-bound"
          ; max_context_tokens = 1_000
          ; reserved_output_tokens = 1_000
          }))
    (Input_budget.resolve eq_cfg);
  let gt_cfg =
    Provider_config.make
      ~kind:Provider_config.OpenAI_compat
      ~model_id:"gt-bound"
      ~base_url:"https://api.example.test"
      ~max_tokens:1_500
      ~model_capabilities_override:eq_caps
      ()
  in
  Alcotest.(check (result budget_testable err_testable))
    "reserved > window fails closed"
    (Error
       (Input_budget.Output_reservation_exceeds_window
          { model_id = "gt-bound"
          ; max_context_tokens = 1_000
          ; reserved_output_tokens = 1_500
          }))
    (Input_budget.resolve gt_cfg)
;;

let test_admit_receipt_matches_budget () =
  let receipt_omitted =
    Types.optional_output_token_receipt
      ~envelope:Types.Openai_chat_max_tokens
      ~requested:None
      ~ceiling:None
  in
  Alcotest.(check bool)
    "admit_receipt accepts omitted reservation at exact window"
    true
    (Result.is_ok
       (Input_budget.admit_receipt
          ~model_id:"m"
          ~max_context_tokens:1_000
          ~input_tokens:1_000
          receipt_omitted));
  let receipt_explicit =
    Types.optional_output_token_receipt
      ~envelope:Types.Anthropic_messages_max_tokens
      ~requested:(Some 64)
      ~ceiling:None
  in
  let fit_err_testable =
    Alcotest.testable
      Input_budget.pp_receipt_fit_error
      Input_budget.equal_receipt_fit_error
  in
  Alcotest.check
    (Alcotest.result fit_testable fit_err_testable)
    "admit_receipt reports Context_exceeded when reserved > window"
    (Error
       (Input_budget.Receipt_context_exceeded
          { input_tokens = 10
          ; reserved_output_tokens = 64
          ; max_context_tokens = 32
          }))
    (Input_budget.admit_receipt
       ~model_id:"m"
       ~max_context_tokens:32
       ~input_tokens:10
       receipt_explicit);
  Alcotest.check
    (Alcotest.result fit_testable fit_err_testable)
    "admit_receipt preserves input_tokens when reserved = window"
    (Error
       (Input_budget.Receipt_context_exceeded
          { input_tokens = 10
          ; reserved_output_tokens = 64
          ; max_context_tokens = 64
          }))
    (Input_budget.admit_receipt
       ~model_id:"m"
       ~max_context_tokens:64
       ~input_tokens:10
       receipt_explicit)
;;

let () =
  Alcotest.run
    "Input_budget"
    [ ( "codecs"
      , [ Alcotest.test_case
            "optional codecs reserve 0 when max_tokens is omitted"
            `Quick
            test_omitted_optional_envelopes_reserve_zero
        ; Alcotest.test_case
            "explicit and clamped reservations (#53504 arithmetic)"
            `Quick
            test_explicit_and_clamped_reservations
        ; Alcotest.test_case
            "Anthropic and Kimi required reservations"
            `Quick
            test_anthropic_and_kimi_required_reservations
        ] )
    ; ( "boundaries"
      , [ Alcotest.test_case
            "window & reservation error boundaries"
            `Quick
            test_error_boundaries
        ; Alcotest.test_case
            "admit_receipt shares exact reservation rules"
            `Quick
            test_admit_receipt_matches_budget
        ] )
    ]
;;
