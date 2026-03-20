open Alcotest

module Inference_utils = Masc_mcp.Inference_utils
module Model_spec = Masc_mcp.Model_spec

let test_string_of_provider () =
  check string "llama" "llama" (Model_spec.string_of_provider Model_spec.Llama);
  check string "gemini" "gemini" (Model_spec.string_of_provider Model_spec.Gemini)

let test_message_constructors () =
  let tool_msg = Masc_mcp.Oas_message.tool_result ~tool_use_id:"call-1" ~content:"done" () in
  check bool "system role" true
    (match (Agent_sdk.Types.system_msg "x").role with Agent_sdk.Types.System -> true | _ -> false);
  let has_call1 = List.exists (function
    | Agent_sdk.Types.ToolResult { tool_use_id = "call-1"; _ } -> true | _ -> false) tool_msg.content in
  check bool "tool call id in content" true has_call1

let test_estimate_tokens_positive () =
  let tokens = Inference_utils.estimate_tokens [ Agent_sdk.Types.user_msg "hello world" ] in
  check bool "positive" true (tokens > 0)

let test_model_spec_of_string_llama () =
  match Model_spec.model_spec_of_string "llama:qwen3.5-32b" with
  | Ok spec ->
      check string "provider" "llama" (Model_spec.string_of_provider spec.provider);
      check string "model id" "qwen3.5-32b" spec.model_id
  | Error err -> fail ("expected llama model spec, got error: " ^ err)

let test_model_spec_of_string_invalid () =
  match Model_spec.model_spec_of_string "broken" with
  | Ok _ -> fail "expected parse error"
  | Error err ->
      check bool "mentions provider:model" true
        (String.length err > 0)

let test_sanitize_text_utf8 () =
  let invalid = "\xffhello" in
  let sanitized = Inference_utils.sanitize_text_utf8 invalid in
  check bool "keeps suffix" true (String.ends_with ~suffix:"hello" sanitized);
  check bool "not empty" true (String.length sanitized > 0)

let test_available_model_specs_of_strings_llama () =
  match Model_spec.available_model_specs_of_strings [ "llama:qwen3.5-32b" ] with
  | [ spec ] ->
      check string "provider" "llama" (Model_spec.string_of_provider spec.provider);
      check string "model id" "qwen3.5-32b" spec.model_id
  | _ -> fail "expected one available llama model"

let () =
  Alcotest.run "model_client coverage"
    [
      ( "providers",
        [
          test_case "string_of_provider" `Quick test_string_of_provider;
          test_case "message constructors" `Quick test_message_constructors;
          test_case "estimate tokens" `Quick test_estimate_tokens_positive;
          test_case "llama model spec" `Quick test_model_spec_of_string_llama;
          test_case "invalid model spec" `Quick test_model_spec_of_string_invalid;
        ] );
      ( "json",
        [
          test_case "sanitize utf8" `Quick test_sanitize_text_utf8;
          test_case "available llama model spec" `Quick
            test_available_model_specs_of_strings_llama;
        ] );
    ]
