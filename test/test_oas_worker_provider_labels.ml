(** Provider label and timeout tests for [test_oas_worker]. *)

open Masc_mcp

let make_cli_tool_d_provider_cfg ?(model_id = "auto") () =
  Llm_provider.Provider_config.make
    ~kind:Llm_provider.Provider_config.Cli_tool_d
    ~model_id
    ~base_url:""
    ()
;;

let make_cli_tool_b_provider_cfg ?(model_id = "provider_f-3.1-pro-preview") () =
  Llm_provider.Provider_config.make
    ~kind:Llm_provider.Provider_config.Cli_tool_b
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
      ?(model_id = "model-d-4.1")
      ?(base_url = "http://127.0.0.1:18080/v1")
      ()
  =
  Llm_provider.Provider_config.make
    ~kind:Llm_provider.Provider_config.Provider_d_compat
    ~model_id
    ~base_url
    ()
;;

let provider_binding_base_url_exn id =
  match Agent_sdk.Provider_runtime_binding.find id with
  | Some binding -> binding.Agent_sdk.Provider_runtime_binding.base_url
  | None -> Alcotest.failf "expected OAS runtime binding %S" id
;;

let make_glm_provider_cfg ?base_url ?(model_id = "provider_k-5.1") () =
  let base_url =
    match base_url with
    | Some url -> url
    | None -> provider_binding_base_url_exn "provider_k"
  in
  Llm_provider.Provider_config.make
    ~kind:Llm_provider.Provider_config.Provider_k
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

let make_openrouter_provider_cfg ?(model_id = "provider_a/model-a-sonnet") () =
  let entry = provider_registry_entry_exn "openrouter" in
  Llm_provider.Provider_config.make
    ~kind:Llm_provider.Provider_config.Provider_d_compat
    ~model_id
    ~base_url:entry.defaults.base_url
    ~request_path:entry.defaults.request_path
    ()
;;

let make_kimi_provider_cfg ?(model_id = "model-c-coding") () =
  Llm_provider.Provider_config.make
    ~kind:Llm_provider.Provider_config.Provider_c
    ~model_id
    ~base_url:"https://api.provider_c.com/coding"
    ~request_path:"/v1/messages"
    ()
;;

let make_cli_tool_c_provider_cfg ?(model_id = "model-c-coding") () =
  Llm_provider.Provider_config.make
    ~kind:Llm_provider.Provider_config.Cli_tool_c
    ~model_id
    ~base_url:""
    ()
;;

let test_cascade_provider_labels_keep_glm_and_glm_coding_distinct () =
  let provider_k = Cascade_observation.provider_name_of_config (make_glm_provider_cfg ()) in
  let glm_coding =
    Cascade_observation.provider_name_of_config
      (make_glm_provider_cfg ~base_url:(provider_binding_base_url_exn "provider_k-coding") ())
  in
  Alcotest.(check string) "general GLM label" "provider_k" provider_k;
  Alcotest.(check string) "coding GLM label" "provider_k-coding" glm_coding
;;

let test_provider_effective_max_turns_passes_cli_tool_d_budget_to_oas () =
  Alcotest.(check int)
    "cli_tool_d max_turns is passed through to OAS"
    39
    (Cascade_runner.provider_effective_max_turns
       Llm_provider.Provider_config.Cli_tool_d
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

let provider_timeout_resolution ?(is_last = false) ?configured provider_cfg =
  let candidate = Cascade_runtime_candidate.of_provider_config provider_cfg in
  Cascade_runtime_candidate.effective_attempt_timeout_resolution
    ~is_last
    ~configured_timeout_s:configured
    candidate
;;

let check_timeout_resolution label expected_timeout expected_source actual =
  check_timeout_opt
    (label ^ " timeout")
    expected_timeout
    actual.Cascade_runtime_candidate.timeout_s;
  Alcotest.(check string)
    (label ^ " source")
    expected_source
    actual.Cascade_runtime_candidate.source
;;

let test_provider_attempt_timeout_passes_cli_tool_d_configured_timeout () =
  check_timeout_opt
    "cli_tool_d configured attempt timeout passes through"
    (Some 300.0)
    (provider_timeout ~configured:300.0 (make_cli_tool_d_provider_cfg ()))
;;

let test_provider_attempt_timeout_passes_cli_tool_c_configured_timeout () =
  check_timeout_opt
    "cli_tool_c configured attempt timeout passes through"
    (Some 300.0)
    (provider_timeout ~configured:300.0 (make_cli_tool_c_provider_cfg ()))
;;

let test_provider_attempt_timeout_passes_cli_tool_b_configured_timeout () =
  check_timeout_opt
    "cli_tool_b configured attempt timeout passes through"
    (Some 300.0)
    (provider_timeout ~configured:300.0 (make_cli_tool_b_provider_cfg ()))
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

let test_provider_attempt_timeout_resolution_sources () =
  check_timeout_resolution
    "cli_tool_d configured timeout"
    (Some 300.0)
    "configured_per_provider_timeout"
    (provider_timeout_resolution ~configured:300.0 (make_cli_tool_d_provider_cfg ()));
  check_timeout_resolution
    "ollama lifted configured timeout"
    (Some local_runtime_timeout_floor_s)
    "configured_lifted_to_local_runtime_floor"
    (provider_timeout_resolution ~configured:60.0 (make_ollama_provider_cfg ()));
  check_timeout_resolution
    "ollama default timeout"
    (Some local_runtime_timeout_floor_s)
    "local_runtime_floor"
    (provider_timeout_resolution (make_ollama_provider_cfg ()));
  check_timeout_resolution
    "provider_d compat unset timeout"
    None
    "unset_oas_default"
    (provider_timeout_resolution
       (make_openai_compat_provider_cfg ~base_url:"https://api.example.test/v1" ()))
;;

let test_cascade_provider_labels_preserve_registered_openai_compat_family () =
  let provider_name =
    Cascade_observation.provider_name_of_config (make_openrouter_provider_cfg ())
  in
  let model_label =
    Cascade_observation.model_label_of_config (make_openrouter_provider_cfg ())
  in
  Alcotest.(check string) "openrouter provider name" "openrouter" provider_name;
  Alcotest.(check string)
    "openrouter model label"
    "openrouter:provider_a/model-a-sonnet"
    model_label
;;

let test_cascade_provider_labels_detect_kimi_from_kind_metadata () =
  let provider_name =
    Cascade_observation.provider_name_of_config (make_kimi_provider_cfg ())
  in
  let model_label =
    Cascade_observation.model_label_of_config (make_kimi_provider_cfg ())
  in
  Alcotest.(check string) "provider_c provider name" "provider_c" provider_name;
  Alcotest.(check string) "provider_c model label" "provider_c:model-c-coding" model_label
;;

let cases =
  [ Alcotest.test_case
      "cascade provider labels keep provider_k and provider_k-coding distinct"
      `Quick
      test_cascade_provider_labels_keep_glm_and_glm_coding_distinct
  ; Alcotest.test_case
      "provider max_turns passes cli_tool_d budget to OAS"
      `Quick
      test_provider_effective_max_turns_passes_cli_tool_d_budget_to_oas
  ; Alcotest.test_case
      "provider max_turns leaves ollama uncapped"
      `Quick
      test_provider_effective_max_turns_keeps_ollama_budget
  ; Alcotest.test_case
      "provider timeout passes cli_tool_d configured timeout"
      `Quick
      test_provider_attempt_timeout_passes_cli_tool_d_configured_timeout
  ; Alcotest.test_case
      "provider timeout passes cli_tool_c configured timeout"
      `Quick
      test_provider_attempt_timeout_passes_cli_tool_c_configured_timeout
  ; Alcotest.test_case
      "provider timeout passes cli_tool_b configured timeout"
      `Quick
      test_provider_attempt_timeout_passes_cli_tool_b_configured_timeout
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
      "provider timeout resolution records bounded source labels"
      `Quick
      test_provider_attempt_timeout_resolution_sources
  ; Alcotest.test_case
      "cascade provider labels preserve registered openai_compat family"
      `Quick
      test_cascade_provider_labels_preserve_registered_openai_compat_family
  ; Alcotest.test_case
      "cascade provider labels detect provider_c from kind metadata"
      `Quick
      test_cascade_provider_labels_detect_kimi_from_kind_metadata
  ]
;;
