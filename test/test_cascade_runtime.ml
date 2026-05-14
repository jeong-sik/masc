open Alcotest

let test_oas_http_error_classification_is_typed () =
  let module H = Masc_mcp.Cascade_health_filter in
  let context_overflow =
    Llm_provider.Http_client.HttpError
      { code = 400; body = "maximum context length exceeded" }
  in
  let provider_parse =
    Llm_provider.Http_client.HttpError
      { code = 400; body = "can't find closing '}'" }
  in
  let capability_mismatch =
    Llm_provider.Http_client.AcceptRejected
      { reason = "openai_compat:model does not support inline tools" }
  in
  check bool "context overflow class cascades" true
    (match H.classify_failure context_overflow with
    | H.Context_overflow -> H.should_cascade_to_next context_overflow
    | _ -> false);
  check bool "provider parse class cascades" true
    (match H.classify_failure provider_parse with
    | H.Provider_parse_error -> H.should_cascade_to_next provider_parse
    | _ -> false);
  check bool "capability mismatch class cascades" true
    (match H.classify_failure capability_mismatch with
    | H.Accept_rejected_capability_mismatch ->
        H.should_cascade_to_next capability_mismatch
    | _ -> false)

let test_oas_failure_classification_keeps_terminal_branches_non_cascading () =
  let module H = Masc_mcp.Cascade_health_filter in
  let terminal_http =
    Llm_provider.Http_client.HttpError
      { code = 418; body = "terminal provider refusal" }
  in
  let accept_terminal =
    Llm_provider.Http_client.AcceptRejected
      { reason = "provider authentication failed" }
  in
  let local_resource =
    Llm_provider.Http_client.NetworkError
      {
        message = "too many open files";
        kind = Llm_provider.Http_client.Local_resource_exhaustion;
      }
  in
  (match H.classify_failure terminal_http with
  | H.Terminal_http 418 ->
      check bool "terminal HTTP class does not cascade" false
        (H.should_cascade_to_next terminal_http)
  | _ -> fail "expected terminal HTTP classification");
  (match H.classify_failure accept_terminal with
  | H.Accept_rejected_terminal ->
      check bool "terminal accept rejection does not cascade" false
        (H.should_cascade_to_next accept_terminal)
  | _ -> fail "expected terminal accept rejection classification");
  match H.classify_failure local_resource with
  | H.Local_resource_exhaustion ->
      check bool "local resource exhaustion does not cascade" false
        (H.should_cascade_to_next local_resource)
  | _ -> fail "expected local resource exhaustion classification"

let test_openai_compat_declarative_labels_do_not_require_registry_entry () =
  check
    bool
    "typed declarative OpenAI-compatible labels are provider-config owned"
    true
    (Result.is_ok
       (Masc_mcp.Cascade_runtime.ensure_api_keys_for_labels
          [ "openai_compat:qwen3.5" ]))

let () =
  run "Cascade_runtime"
    [
      ( "failure_classification",
        [
          test_case "OAS HTTP errors classify before cascade boolean" `Quick
            test_oas_http_error_classification_is_typed;
          test_case "OAS terminal classes stay non-cascading" `Quick
            test_oas_failure_classification_keeps_terminal_branches_non_cascading;
          test_case "typed openai_compat labels skip registry api-key gate" `Quick
            test_openai_compat_declarative_labels_do_not_require_registry_entry;
        ] );
    ]
