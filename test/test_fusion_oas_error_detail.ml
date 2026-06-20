open Masc

let provider_cfg () =
  Llm_provider.Provider_config.make
    ~kind:Llm_provider.Provider_config.Anthropic
    ~model_id:"fusion-test"
    ~base_url:"http://localhost"
    ()
;;

let runtime_config () =
  Runtime_agent.default_config
    ~name:"fusion-test"
    ~provider_cfg:(provider_cfg ())
    ~system_prompt:""
    ~tools:[]
;;

let test_rewrites_unknown_provider () =
  let detail =
    Fusion_oas.provider_error_detail ~runtime_id:"ollama_cloud.kimi-k2-6"
      "Provider 'unknown' timeout phase=http_operation: HTTP operation exceeded wall-clock timeout"
  in
  Alcotest.(check string)
    "unknown provider replaced with runtime id"
    "Provider 'ollama_cloud.kimi-k2-6' timeout phase=http_operation: HTTP operation exceeded wall-clock timeout"
    detail
;;

let test_prefixes_unattributed_provider_error () =
  let detail =
    Fusion_oas.provider_error_detail ~runtime_id:"ollama_cloud.minimax-m3"
      "HTTP 503 from provider"
  in
  Alcotest.(check string)
    "runtime context prefixed"
    "ollama_cloud.minimax-m3: HTTP 503 from provider"
    detail
;;

let test_keeps_already_attributed_error () =
  let detail =
    Fusion_oas.provider_error_detail ~runtime_id:"ollama_cloud.minimax-m3"
      "Provider 'ollama_cloud.minimax-m3' timeout phase=http_operation"
  in
  Alcotest.(check string)
    "already attributed"
    "Provider 'ollama_cloud.minimax-m3' timeout phase=http_operation"
    detail
;;

let test_panel_failure_detail_rewrites_unknown_provider () =
  let detail =
    Fusion_oas.panel_failure_detail ~runtime_id:"ollama_cloud.kimi-k2-6"
      (Fusion_types.Provider_error
         "Provider 'unknown' timeout phase=http_operation: HTTP operation exceeded wall-clock timeout")
  in
  Alcotest.(check string)
    "panel failure detail"
    "Provider 'ollama_cloud.kimi-k2-6' timeout phase=http_operation: HTTP operation exceeded wall-clock timeout"
    detail;
  Alcotest.(check string)
    "panel failure code"
    "provider_error"
    (Fusion_oas.panel_failure_code
       (Fusion_types.Provider_error "Provider 'unknown' timeout"))
;;

let test_timeout_budget_does_not_set_total_execution_ceiling () =
  let config =
    Fusion_oas.For_testing.apply_timeout_budget
      ~timeout_s:300.0
      (runtime_config ())
  in
  Alcotest.(check (option (float 0.001)))
    "stream idle timeout"
    (Some 300.0)
    config.stream_idle_timeout_s;
  Alcotest.(check (option (float 0.001)))
    "body timeout"
    (Some 300.0)
    config.body_timeout_s;
  Alcotest.(check (option (float 0.001)))
    "no total execution ceiling"
    None
    config.max_execution_time_s
;;

let () =
  Alcotest.run
    "Fusion_oas_error_detail"
    [ ( "provider attribution"
      , [ Alcotest.test_case
            "rewrites unknown provider"
            `Quick
            test_rewrites_unknown_provider
        ; Alcotest.test_case
            "prefixes unattributed provider error"
            `Quick
            test_prefixes_unattributed_provider_error
        ; Alcotest.test_case
            "keeps already attributed error"
            `Quick
            test_keeps_already_attributed_error
        ; Alcotest.test_case
            "panel failure detail rewrites unknown provider"
            `Quick
            test_panel_failure_detail_rewrites_unknown_provider
        ; Alcotest.test_case
            "timeout budget does not arm OAS total execution ceiling"
            `Quick
            test_timeout_budget_does_not_set_total_execution_ceiling
        ] )
    ]
;;
