(** Provider label and timeout tests for [test_oas_worker]. *)

open Masc_mcp

let make_claude_code_provider_cfg ?(model_id = "auto") () =
  Llm_provider.Provider_config.make
    ~kind:Llm_provider.Provider_config.Claude_code
    ~model_id
    ~base_url:""
    ()
;;

let make_gemini_cli_provider_cfg ?(model_id = "gemini-3.1-pro-preview") () =
  Llm_provider.Provider_config.make
    ~kind:Llm_provider.Provider_config.Gemini_cli
    ~model_id
    ~base_url:""
    ()
;;

let make_ollama_provider_cfg ?(model_id = "qwen3:27b") () =
  Llm_provider.Provider_config.make
    ~kind:Llm_provider.Provider_config.Ollama
    ~model_id
    ~base_url:"http://127.0.0.1:11434"
    ()
;;

let make_openai_compat_provider_cfg
      ?(model_id = "gpt-4.1")
      ?(base_url = "http://127.0.0.1:18080/v1")
      ()
  =
  Llm_provider.Provider_config.make
    ~kind:Llm_provider.Provider_config.OpenAI_compat
    ~model_id
    ~base_url
    ()
;;

let provider_binding_base_url_exn id =
  match Agent_sdk.Provider_runtime_binding.find id with
  | Some binding -> binding.Agent_sdk.Provider_runtime_binding.base_url
  | None -> Alcotest.failf "expected OAS runtime binding %S" id
;;

let make_glm_provider_cfg ?base_url ?(model_id = "glm-5.1") () =
  let base_url =
    match base_url with
    | Some url -> url
    | None -> provider_binding_base_url_exn "glm"
  in
  Llm_provider.Provider_config.make
    ~kind:Llm_provider.Provider_config.Glm
    ~model_id
    ~base_url
    ()
;;

let provider_registry_entry_exn name =
  let registry = Llm_provider.Provider_registry.default () in
  match Llm_provider.Provider_registry.find registry name with
  | Some entry -> entry
  | None -> Alcotest.failf "expected provider registry entry %S" name
;;

let make_openrouter_provider_cfg ?(model_id = "anthropic/claude-3.5") () =
  let entry = provider_registry_entry_exn "openrouter" in
  Llm_provider.Provider_config.make
    ~kind:Llm_provider.Provider_config.OpenAI_compat
    ~model_id
    ~base_url:entry.defaults.base_url
    ~request_path:entry.defaults.request_path
    ()
;;

let make_kimi_provider_cfg ?(model_id = "kimi-for-coding") () =
  Llm_provider.Provider_config.make
    ~kind:Llm_provider.Provider_config.Kimi
    ~model_id
    ~base_url:"https://api.kimi.com/coding"
    ~request_path:"/v1/messages"
    ()
;;

let make_kimi_cli_provider_cfg ?(model_id = "kimi-for-coding") () =
  Llm_provider.Provider_config.make
    ~kind:Llm_provider.Provider_config.Kimi_cli
    ~model_id
    ~base_url:""
    ()
;;

let test_cascade_provider_labels_keep_glm_and_glm_coding_distinct () =
  let glm = Cascade_legacy_runner.provider_name_of_config (make_glm_provider_cfg ()) in
  let glm_coding =
    Cascade_legacy_runner.provider_name_of_config
      (make_glm_provider_cfg ~base_url:(provider_binding_base_url_exn "glm-coding") ())
  in
  Alcotest.(check string) "general GLM label" "glm" glm;
  Alcotest.(check string) "coding GLM label" "glm-coding" glm_coding
;;

let test_provider_effective_max_turns_passes_claude_code_budget_to_oas () =
  Alcotest.(check int)
    "claude_code max_turns is passed through to OAS"
    39
    (Cascade_runner.provider_effective_max_turns
       Llm_provider.Provider_config.Claude_code
       39)
;;

let test_provider_effective_max_turns_keeps_ollama_budget () =
  Alcotest.(check int)
    "ollama has no provider max_turns cap"
    39
    (Cascade_runner.provider_effective_max_turns Llm_provider.Provider_config.Ollama 39)
;;

let check_timeout_opt label expected actual =
  Alcotest.(check (option (float 0.001))) label expected actual
;;

let local_runtime_timeout_floor_s =
  Cascade_attempt_liveness.bootstrap.attempt_wall_max
;;

let provider_timeout ?(is_last = false) ?configured provider_cfg =
  let candidate = Cascade_runtime_candidate.of_provider_config provider_cfg in
  Cascade_runtime_candidate.effective_attempt_timeout_s
    ~is_last
    ~configured_timeout_s:configured
    candidate
;;

let test_provider_attempt_timeout_passes_claude_code_configured_timeout () =
  check_timeout_opt
    "claude_code configured attempt timeout passes through"
    (Some 300.0)
    (provider_timeout ~configured:300.0 (make_claude_code_provider_cfg ()))
;;

let test_provider_attempt_timeout_passes_kimi_cli_configured_timeout () =
  check_timeout_opt
    "kimi_cli configured attempt timeout passes through"
    (Some 300.0)
    (provider_timeout ~configured:300.0 (make_kimi_cli_provider_cfg ()))
;;

let test_provider_attempt_timeout_passes_gemini_cli_configured_timeout () =
  check_timeout_opt
    "gemini_cli configured attempt timeout passes through"
    (Some 300.0)
    (provider_timeout ~configured:300.0 (make_gemini_cli_provider_cfg ()))
;;

let test_provider_attempt_timeout_floors_ollama_configured_timeout () =
  check_timeout_opt
    "ollama configured attempt timeout is floored for local runtime"
    (Some local_runtime_timeout_floor_s)
    (provider_timeout ~configured:60.0 (make_ollama_provider_cfg ()))
;;

let test_provider_attempt_timeout_floors_ollama_default_timeout () =
  check_timeout_opt
    "ollama absent attempt timeout gets local runtime floor"
    (Some local_runtime_timeout_floor_s)
    (provider_timeout (make_ollama_provider_cfg ()))
;;

let test_provider_attempt_timeout_passes_final_configured_timeout () =
  check_timeout_opt
    "final non-local provider configured attempt timeout passes through"
    (Some 300.0)
    (provider_timeout
       ~is_last:true
       ~configured:300.0
       (make_openai_compat_provider_cfg ~base_url:"https://api.example.test/v1" ()))
;;

let test_cascade_provider_labels_preserve_registered_openai_compat_family () =
  let provider_name =
    Cascade_legacy_runner.provider_name_of_config (make_openrouter_provider_cfg ())
  in
  let model_label =
    Cascade_legacy_runner.model_label_of_config (make_openrouter_provider_cfg ())
  in
  Alcotest.(check string) "openrouter provider name" "openrouter" provider_name;
  Alcotest.(check string)
    "openrouter model label"
    "openrouter:anthropic/claude-3.5"
    model_label
;;

let test_cascade_provider_labels_detect_kimi_from_kind_metadata () =
  let provider_name =
    Cascade_legacy_runner.provider_name_of_config (make_kimi_provider_cfg ())
  in
  let model_label =
    Cascade_legacy_runner.model_label_of_config (make_kimi_provider_cfg ())
  in
  Alcotest.(check string) "kimi provider name" "kimi" provider_name;
  Alcotest.(check string) "kimi model label" "kimi:kimi-for-coding" model_label
;;

let cases =
  [ Alcotest.test_case
      "cascade provider labels keep glm and glm-coding distinct"
      `Quick
      test_cascade_provider_labels_keep_glm_and_glm_coding_distinct
  ; Alcotest.test_case
      "provider max_turns passes claude_code budget to OAS"
      `Quick
      test_provider_effective_max_turns_passes_claude_code_budget_to_oas
  ; Alcotest.test_case
      "provider max_turns leaves ollama uncapped"
      `Quick
      test_provider_effective_max_turns_keeps_ollama_budget
  ; Alcotest.test_case
      "provider timeout passes claude_code configured timeout"
      `Quick
      test_provider_attempt_timeout_passes_claude_code_configured_timeout
  ; Alcotest.test_case
      "provider timeout passes kimi_cli configured timeout"
      `Quick
      test_provider_attempt_timeout_passes_kimi_cli_configured_timeout
  ; Alcotest.test_case
      "provider timeout passes gemini_cli configured timeout"
      `Quick
      test_provider_attempt_timeout_passes_gemini_cli_configured_timeout
  ; Alcotest.test_case
      "provider timeout floors ollama configured timeout"
      `Quick
      test_provider_attempt_timeout_floors_ollama_configured_timeout
  ; Alcotest.test_case
      "provider timeout floors ollama default timeout"
      `Quick
      test_provider_attempt_timeout_floors_ollama_default_timeout
  ; Alcotest.test_case
      "provider timeout passes final configured timeout"
      `Quick
      test_provider_attempt_timeout_passes_final_configured_timeout
  ; Alcotest.test_case
      "cascade provider labels preserve registered openai_compat family"
      `Quick
      test_cascade_provider_labels_preserve_registered_openai_compat_family
  ; Alcotest.test_case
      "cascade provider labels detect kimi from kind metadata"
      `Quick
      test_cascade_provider_labels_detect_kimi_from_kind_metadata
  ]
;;
