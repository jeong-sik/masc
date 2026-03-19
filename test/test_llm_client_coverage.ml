open Alcotest

module Llm = Masc_mcp.Cascade
module Cascade = Masc_mcp.Cascade

let test_string_of_provider () =
  check string "llama" "llama" (Llm.string_of_provider Llm.Llama);
  check string "gemini" "gemini" (Llm.string_of_provider Llm.Gemini)

let test_message_constructors () =
  let tool_msg = Llm.tool_msg ~name:"grep" ~call_id:"call-1" "done" in
  check bool "system role" true
    (match (Llm.system_msg "x").role with Llm.System -> true | _ -> false);
  let has_call1 = List.exists (function
    | Agent_sdk.Types.ToolResult { tool_use_id = "call-1"; _ } -> true | _ -> false) tool_msg.content in
  check bool "tool call id in content" true has_call1

let test_estimate_tokens_positive () =
  let tokens = Llm.estimate_tokens [ Llm.user_msg "hello world" ] in
  check bool "positive" true (tokens > 0)

let test_model_spec_of_string_llama () =
  match Cascade.model_spec_of_string "llama:qwen3.5-32b" with
  | Ok spec ->
      check string "provider" "llama" (Llm.string_of_provider spec.provider);
      check string "model id" "qwen3.5-32b" spec.model_id
  | Error err -> fail ("expected llama model spec, got error: " ^ err)

let test_model_spec_of_string_invalid () =
  match Cascade.model_spec_of_string "broken" with
  | Ok _ -> fail "expected parse error"
  | Error err ->
      check bool "mentions provider:model" true
        (String.length err > 0)

let test_sanitize_text_utf8 () =
  let invalid = "\xffhello" in
  let sanitized = Llm.sanitize_text_utf8 invalid in
  check bool "keeps suffix" true (String.ends_with ~suffix:"hello" sanitized);
  check bool "not empty" true (String.length sanitized > 0)

let test_available_model_specs_of_strings_llama () =
  match Cascade.available_model_specs_of_strings [ "llama:qwen3.5-32b" ] with
  | [ spec ] ->
      check string "provider" "llama" (Llm.string_of_provider spec.provider);
      check string "model id" "qwen3.5-32b" spec.model_id
  | _ -> fail "expected one available llama model"

let () =
  Alcotest.run "llm_client coverage"
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
