(** Unit tests for Cascade_model_resolve.resolve_auto_model_id.

    Focus: "auto" → concrete model ID translation for cloud providers.
    2026-04-20 regression guard — `gemini_cli:auto` used to fall
    through to the wildcard tail and reach OAS as the literal string
    "auto". OAS transport_gemini_cli.build_args then omits --model,
    letting the Gemini CLI choose its own default (gemini-3.1-pro-preview)
    whose quota 429'd the fleet. *)

open Alcotest
module R = Masc_mcp.Cascade_model_resolve

let unset_env k =
  try Unix.putenv k "" with _ -> ()

let with_clean_env f =
  List.iter unset_env [
    "GEMINI_DEFAULT_MODEL";
    "ANTHROPIC_DEFAULT_MODEL";
    "OPENAI_DEFAULT_MODEL";
    "OPENROUTER_DEFAULT_MODEL";
    "OLLAMA_DEFAULT_MODEL";
  ];
  f ()

let test_gemini_auto_maps_to_flash_preview () =
  with_clean_env (fun () ->
    let resolved = R.resolve_auto_model_id "gemini" "auto" in
    check string "gemini:auto → gemini-3-flash-preview"
      "gemini-3-flash-preview" resolved)

let test_gemini_cli_auto_maps_to_flash_preview () =
  with_clean_env (fun () ->
    let resolved = R.resolve_auto_model_id "gemini_cli" "auto" in
    check string "gemini_cli:auto → gemini-3-flash-preview"
      "gemini-3-flash-preview" resolved)

let test_gemini_cli_explicit_model_passthrough () =
  with_clean_env (fun () ->
    let resolved =
      R.resolve_auto_model_id "gemini_cli" "gemini-2.5-flash"
    in
    check string "explicit model untouched"
      "gemini-2.5-flash" resolved)

let test_gemini_env_override () =
  Unix.putenv "GEMINI_DEFAULT_MODEL" "gemini-2.5-flash";
  let resolved_gemini = R.resolve_auto_model_id "gemini" "auto" in
  let resolved_cli = R.resolve_auto_model_id "gemini_cli" "auto" in
  Unix.putenv "GEMINI_DEFAULT_MODEL" "";
  check string "gemini respects env override"
    "gemini-2.5-flash" resolved_gemini;
  check string "gemini_cli respects same env override"
    "gemini-2.5-flash" resolved_cli

let () =
  run "Cascade_model_resolve" [
    "gemini auto", [
      test_case "gemini:auto"
        `Quick test_gemini_auto_maps_to_flash_preview;
      test_case "gemini_cli:auto (regression 2026-04-20)"
        `Quick test_gemini_cli_auto_maps_to_flash_preview;
      test_case "gemini_cli explicit"
        `Quick test_gemini_cli_explicit_model_passthrough;
      test_case "GEMINI_DEFAULT_MODEL env override"
        `Quick test_gemini_env_override;
    ];
  ]
