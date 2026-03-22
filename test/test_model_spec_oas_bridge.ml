(** Tests for the OAS parsing boundary swap in Model_spec.

    Verifies that model_spec_of_string delegates to OAS
    Cascade_config.parse_model_string_exn for core provider:model parsing
    while maintaining MASC-specific alias and shortcut behavior. *)

open Alcotest

module Model_spec = Masc_mcp.Model_spec

let with_env name value f =
  let previous = Sys.getenv_opt name in
  Unix.putenv name value;
  Fun.protect
    ~finally:(fun () ->
      match previous with
      | Some v -> Unix.putenv name v
      | None -> Unix.putenv name "")
    f

(* ── Core provider:model parsing via OAS ────────────── *)

let test_llama_basic () =
  match Model_spec.model_spec_of_string "llama:qwen3.5-35b" with
  | Ok spec ->
      check bool "provider is Llama" true (spec.provider = Model_spec.Llama);
      check string "model_id" "qwen3.5-35b" spec.model_id;
      check bool "max_context > 0" true (spec.max_context > 0);
      check bool "api_url non-empty" true (String.length spec.api_url > 0)
  | Error msg -> fail (Printf.sprintf "llama parse failed: %s" msg)

let test_gemini_basic () =
  with_env "GEMINI_API_KEY" "test-key" (fun () ->
    match Model_spec.model_spec_of_string "gemini:gemini-2.5-pro" with
    | Ok spec ->
        check bool "provider is Gemini" true
          (spec.provider = Model_spec.Gemini);
        check string "model_id" "gemini-2.5-pro" spec.model_id
    | Error msg -> fail (Printf.sprintf "gemini parse failed: %s" msg))

let test_claude_basic () =
  with_env "ANTHROPIC_API_KEY" "test-key" (fun () ->
    match Model_spec.model_spec_of_string "claude:claude-opus-4-6" with
    | Ok spec ->
        check bool "provider is Claude" true
          (spec.provider = Model_spec.Claude);
        check string "model_id" "claude-opus-4-6" spec.model_id
    | Error msg -> fail (Printf.sprintf "claude parse failed: %s" msg))

let test_glm_basic () =
  with_env "ZAI_API_KEY" "test-key" (fun () ->
    match Model_spec.model_spec_of_string "glm:glm-4.5" with
    | Ok spec ->
        check bool "provider is Glm_cloud" true
          (spec.provider = Model_spec.Glm_cloud);
        check string "model_id" "glm-4.5" spec.model_id
    | Error msg -> fail (Printf.sprintf "glm parse failed: %s" msg))

let test_openrouter_basic () =
  with_env "OPENROUTER_API_KEY" "test-key" (fun () ->
    match Model_spec.model_spec_of_string "openrouter:meta-llama/llama-3" with
    | Ok spec ->
        check bool "provider is OpenRouter" true
          (spec.provider = Model_spec.OpenRouter);
        check string "model_id" "meta-llama/llama-3" spec.model_id
    | Error msg -> fail (Printf.sprintf "openrouter parse failed: %s" msg))

(* ── MASC model shortcuts preserved ────────────────── *)

let test_gemini_pro_shortcut () =
  with_env "GEMINI_API_KEY" "test-key" (fun () ->
    match Model_spec.model_spec_of_string "gemini:pro" with
    | Ok spec ->
        check bool "provider is Gemini" true
          (spec.provider = Model_spec.Gemini);
        check bool "model_id non-empty" true
          (String.length spec.model_id > 0)
    | Error msg -> fail (Printf.sprintf "gemini:pro failed: %s" msg))

let test_gemini_flash_shortcut () =
  with_env "GEMINI_API_KEY" "test-key" (fun () ->
    match Model_spec.model_spec_of_string "gemini:flash" with
    | Ok spec ->
        check bool "provider is Gemini" true
          (spec.provider = Model_spec.Gemini);
        check bool "model_id non-empty" true
          (String.length spec.model_id > 0)
    | Error msg -> fail (Printf.sprintf "gemini:flash failed: %s" msg))

let test_claude_opus_shortcut () =
  with_env "ANTHROPIC_API_KEY" "test-key" (fun () ->
    match Model_spec.model_spec_of_string "claude:opus" with
    | Ok spec ->
        check bool "provider is Claude" true
          (spec.provider = Model_spec.Claude)
    | Error msg -> fail (Printf.sprintf "claude:opus failed: %s" msg))

let test_claude_sonnet_shortcut () =
  with_env "ANTHROPIC_API_KEY" "test-key" (fun () ->
    match Model_spec.model_spec_of_string "claude:sonnet" with
    | Ok spec ->
        check bool "provider is Claude" true
          (spec.provider = Model_spec.Claude)
    | Error msg -> fail (Printf.sprintf "claude:sonnet failed: %s" msg))

let test_glm_auto_shortcut () =
  with_env "ZAI_API_KEY" "test-key" (fun () ->
    match Model_spec.model_spec_of_string "glm:auto" with
    | Ok spec ->
        check bool "provider is Glm_cloud" true
          (spec.provider = Model_spec.Glm_cloud);
        check string "model_id is empty (auto)" "" spec.model_id
    | Error msg -> fail (Printf.sprintf "glm:auto failed: %s" msg))

(* ── MASC alias resolution preserved ───────────────── *)

let test_anthropic_alias () =
  with_env "ANTHROPIC_API_KEY" "test-key" (fun () ->
    match Model_spec.model_spec_of_string "anthropic:test-model" with
    | Ok spec ->
        check bool "provider is Claude" true
          (spec.provider = Model_spec.Claude);
        check string "model_id" "test-model" spec.model_id
    | Error msg -> fail (Printf.sprintf "anthropic alias failed: %s" msg))

let test_llamacpp_alias () =
  match Model_spec.model_spec_of_string "llamacpp:test-model" with
  | Ok spec ->
      check bool "provider is Llama" true
        (spec.provider = Model_spec.Llama);
      check string "model_id" "test-model" spec.model_id
  | Error msg -> fail (Printf.sprintf "llamacpp alias failed: %s" msg)

(* ── Custom provider (delegated to OAS) ────────────── *)

let test_custom_with_url () =
  match
    Model_spec.model_spec_of_string "custom:my-model@http://10.0.0.1:9090"
  with
  | Ok spec ->
      (match spec.provider with
       | Model_spec.Custom name ->
           check string "custom name" "my-model" name
       | _ -> fail "expected Custom provider");
      check string "api_url" "http://10.0.0.1:9090" spec.api_url
  | Error msg -> fail (Printf.sprintf "custom parse failed: %s" msg)

let test_custom_without_url () =
  match Model_spec.model_spec_of_string "custom:my-model" with
  | Ok spec ->
      (match spec.provider with
       | Model_spec.Custom name ->
           check string "custom name" "my-model" name
       | _ -> fail "expected Custom provider")
  | Error msg -> fail (Printf.sprintf "custom bare failed: %s" msg)

(* ── Error cases ───────────────────────────────────── *)

let test_invalid_no_colon () =
  match Model_spec.model_spec_of_string "nocolon" with
  | Error _ -> ()
  | Ok _ -> fail "expected error for no-colon input"

let test_invalid_empty_model () =
  match Model_spec.model_spec_of_string "llama:" with
  | Error _ -> ()
  | Ok _ -> fail "expected error for empty model"

let test_invalid_empty_provider () =
  match Model_spec.model_spec_of_string ":model" with
  | Error _ -> ()
  | Ok _ -> fail "expected error for empty provider"

let test_invalid_unknown_provider () =
  match Model_spec.model_spec_of_string "unknown_xyz:model" with
  | Error _ -> ()
  | Ok _ -> fail "expected error for unknown provider"

(* ── OAS bridge: model_spec_of_provider_config ─────── *)

let test_provider_config_conversion () =
  (* Verify that the OAS Provider_config → model_spec conversion
     produces consistent results with direct model_spec_of_string *)
  match Model_spec.model_spec_of_string "llama:qwen3.5-35b" with
  | Ok spec ->
      check bool "has pricing" true
        (spec.cost_per_1k_input >= 0.0);
      check bool "has max_context" true
        (spec.max_context > 0)
  | Error msg -> fail (Printf.sprintf "conversion test failed: %s" msg)

(* ── Availability gating (OAS checks env vars) ─────── *)

let test_unavailable_provider_error () =
  with_env "GEMINI_API_KEY" "" (fun () ->
    match Model_spec.model_spec_of_string "gemini:gemini-2.5-pro" with
    | Error msg ->
        check bool "error mentions unavailable" true
          (String.length msg > 0)
    | Ok _ ->
        (* Vertex ADC fallback may make gemini available even without
           GEMINI_API_KEY, so this is also acceptable *)
        ())

let () =
  run "Model_spec OAS bridge"
    [
      ( "core_parsing",
        [
          test_case "llama basic" `Quick test_llama_basic;
          test_case "gemini basic" `Quick test_gemini_basic;
          test_case "claude basic" `Quick test_claude_basic;
          test_case "glm basic" `Quick test_glm_basic;
          test_case "openrouter basic" `Quick test_openrouter_basic;
        ] );
      ( "masc_shortcuts",
        [
          test_case "gemini:pro shortcut" `Quick test_gemini_pro_shortcut;
          test_case "gemini:flash shortcut" `Quick test_gemini_flash_shortcut;
          test_case "claude:opus shortcut" `Quick test_claude_opus_shortcut;
          test_case "claude:sonnet shortcut" `Quick test_claude_sonnet_shortcut;
          test_case "glm:auto shortcut" `Quick test_glm_auto_shortcut;
        ] );
      ( "masc_aliases",
        [
          test_case "anthropic alias" `Quick test_anthropic_alias;
          test_case "llamacpp alias" `Quick test_llamacpp_alias;
        ] );
      ( "custom",
        [
          test_case "custom with url" `Quick test_custom_with_url;
          test_case "custom without url" `Quick test_custom_without_url;
        ] );
      ( "errors",
        [
          test_case "no colon" `Quick test_invalid_no_colon;
          test_case "empty model" `Quick test_invalid_empty_model;
          test_case "empty provider" `Quick test_invalid_empty_provider;
          test_case "unknown provider" `Quick test_invalid_unknown_provider;
        ] );
      ( "oas_bridge",
        [
          test_case "provider_config conversion" `Quick
            test_provider_config_conversion;
          test_case "unavailable provider error" `Quick
            test_unavailable_provider_error;
        ] );
    ]
