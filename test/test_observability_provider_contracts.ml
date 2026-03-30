(** test_observability_provider_contracts — Static contract tests for
    provider label parsing and resolution. No live API calls.

    parse_model_string returns None when the provider's API key env var
    is unset (is_available check). This is correct behavior in CI.
    We verify: (1) provider_name_of_label extracts the prefix correctly,
    (2) parse_model_string succeeds for providers with env-less availability
    (gemini, glm), and (3) unavailable providers return None gracefully. *)

open Masc_mcp

let parse = Llm_provider.Cascade_config.parse_model_string
let provider_name = Oas_model_resolve.provider_name_of_label

(* {1 provider_name_of_label — pure string splitting, no env dependency} *)

let test_provider_name_extraction () =
  Alcotest.(check (option string)) "anthropic" (Some "anthropic")
    (provider_name "anthropic:claude-sonnet-4-20250514");
  Alcotest.(check (option string)) "openai" (Some "openai")
    (provider_name "openai:gpt-4o");
  Alcotest.(check (option string)) "gemini" (Some "gemini")
    (provider_name "gemini:gemini-2.5-pro");
  Alcotest.(check (option string)) "glm" (Some "glm")
    (provider_name "glm:GLM-5.1");
  Alcotest.(check (option string)) "llama" (Some "llama")
    (provider_name "llama:qwen3.5-35b-a3b");
  Alcotest.(check (option string)) "claude_code" (Some "claude_code")
    (provider_name "claude_code:claude-sonnet-4-20250514")

let test_provider_name_no_colon () =
  Alcotest.(check (option string)) "no provider" None
    (provider_name "just-a-model")

let test_provider_name_empty () =
  Alcotest.(check (option string)) "empty" None (provider_name "")

(* {1 parse_model_string — env-available providers resolve fully} *)

let test_gemini_label_resolves () =
  let label = "gemini:gemini-2.5-pro" in
  match parse label with
  | Some cfg ->
      Alcotest.(check bool) "is Gemini" true
        (cfg.Llm_provider.Provider_config.kind = Llm_provider.Provider_config.Gemini);
      Alcotest.(check string) "model_id" "gemini-2.5-pro" cfg.model_id
  | None -> Alcotest.fail "gemini label should resolve (key-less provider)"

let test_glm_label_resolves () =
  let label = "glm:GLM-5.1" in
  match parse label with
  | Some cfg ->
      Alcotest.(check bool) "is Glm" true
        (cfg.Llm_provider.Provider_config.kind = Llm_provider.Provider_config.Glm);
      Alcotest.(check string) "model_id" "GLM-5.1" cfg.model_id
  | None -> Alcotest.fail "glm label should resolve (key-less provider)"

(* {1 parse_model_string — providers without API keys return None} *)

let test_unavailable_providers_return_none () =
  (* In CI/test env, ANTHROPIC_API_KEY and OPENAI_API_KEY are unset.
     parse_model_string correctly returns None for these. *)
  let check_none label =
    match parse label with
    | None -> ()
    | Some _ ->
        Alcotest.failf "%s should return None without API key" label
  in
  check_none "anthropic:claude-sonnet-4-20250514";
  check_none "openai:gpt-4o"

let test_malformed_labels () =
  Alcotest.(check (option reject)) "no colon" None (parse "just-a-model-name");
  Alcotest.(check (option reject)) "empty" None (parse "");
  Alcotest.(check (option reject)) "colon only" None (parse ":");
  Alcotest.(check (option reject)) "empty model" None (parse "anthropic:")

let () =
  Alcotest.run "observability_provider_contracts"
    [
      ( "provider_name_of_label",
        [
          Alcotest.test_case "extraction" `Quick test_provider_name_extraction;
          Alcotest.test_case "no colon" `Quick test_provider_name_no_colon;
          Alcotest.test_case "empty string" `Quick test_provider_name_empty;
        ] );
      ( "parse_model_string_available",
        [
          Alcotest.test_case "gemini resolves" `Quick test_gemini_label_resolves;
          Alcotest.test_case "glm resolves" `Quick test_glm_label_resolves;
        ] );
      ( "parse_model_string_unavailable",
        [
          Alcotest.test_case "no API key -> None" `Quick test_unavailable_providers_return_none;
          Alcotest.test_case "malformed labels" `Quick test_malformed_labels;
        ] );
    ]
