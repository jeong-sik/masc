open Masc

let contains ~needle haystack =
  let needle_len = String.length needle in
  let haystack_len = String.length haystack in
  let rec loop i =
    i + needle_len <= haystack_len
    && (String.equal (String.sub haystack i needle_len) needle || loop (i + 1))
  in
  String.equal needle "" || loop 0
;;

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

(* RFC-0278: panel_failure_text는 이미 attribution된 detail을 재-attribution 없이
   그대로 렌더한다 (sink가 panelist 정체성을 provider 슬롯에 다시 입히지 않도록). *)
let test_panel_failure_text_no_reattribution () =
  Alcotest.(check string)
    "provider_error returns detail as-is"
    "Provider 'claude': boom"
    (Fusion_oas.panel_failure_text
       (Fusion_types.Provider_error "Provider 'claude': boom"));
  Alcotest.(check string)
    "timeout"
    "timeout"
    (Fusion_oas.panel_failure_text Fusion_types.Timeout);
  Alcotest.(check string)
    "empty response"
    "empty response (stop_reason=max_tokens)"
    (Fusion_oas.panel_failure_text
       (Fusion_types.Empty_response "empty response (stop_reason=max_tokens)"))
;;

let test_empty_response_detail_summarizes_shape () =
  let response : Agent_sdk.Types.api_response =
    { id = "r"
    ; model = "m"
    ; stop_reason = Agent_sdk.Types.MaxTokens
    ; content =
        [ Agent_sdk.Types.Thinking { thinking_type = "reasoning"; content = "secret chain" } ]
    ; usage =
        Some
          { input_tokens = 21
          ; output_tokens = 32
          ; cache_creation_input_tokens = 0
          ; cache_read_input_tokens = 0
          ; cost_usd = None
          }
    ; telemetry = None
    }
  in
  let detail = Fusion_oas.For_testing.empty_response_detail response in
  Alcotest.(check bool) "stop reason included" true
    (contains ~needle:"stop_reason=max_tokens" detail);
  Alcotest.(check bool) "thinking block counted" true
    (contains ~needle:"thinking_blocks=1" detail);
  Alcotest.(check bool) "output tokens included" true
    (contains ~needle:"output_tokens=32" detail);
  Alcotest.(check bool) "reasoning body not leaked" false
    (contains ~needle:"secret chain" detail)
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
            "panel failure text does not re-attribute"
            `Quick
            test_panel_failure_text_no_reattribution
        ; Alcotest.test_case
            "empty response detail summarizes shape"
            `Quick
            test_empty_response_detail_summarizes_shape
        ; Alcotest.test_case
            "timeout budget does not arm OAS total execution ceiling"
            `Quick
            test_timeout_budget_does_not_set_total_execution_ceiling
        ] )
    ]
;;
