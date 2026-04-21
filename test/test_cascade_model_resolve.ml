(** Unit tests for Cascade_model_resolve.resolve_auto_model_id.

    Focus: "auto" → concrete model ID translation for cloud providers.
    2026-04-20 regression guard — `gemini_cli:auto` used to fall
    through to the wildcard tail and reach OAS as the literal string
    "auto". OAS transport_gemini_cli.build_args then omits --model,
    letting the Gemini CLI choose its own default (gemini-3.1-pro-preview)
    whose quota 429'd the fleet. *)

open Alcotest
module R = Masc_mcp.Cascade_model_resolve
module C = Masc_mcp.Cascade_config
module State = Masc_mcp.Cascade_state

let unset_env k =
  try Unix.putenv k "" with _ -> ()

let with_clean_env f =
  List.iter unset_env [
    "ZAI_CODING_DEFAULT_MODEL";
    "ZAI_CODING_AUTO_MODELS";
    "GEMINI_DEFAULT_MODEL";
    "ANTHROPIC_DEFAULT_MODEL";
    "OPENAI_DEFAULT_MODEL";
    "OPENROUTER_DEFAULT_MODEL";
    "OLLAMA_DEFAULT_MODEL";
    "MASC_GEMINI_CLI_AUTO_MODELS";
    "MASC_CODEX_CLI_AUTO_MODELS";
    "MASC_CLAUDE_CODE_AUTO_MODELS";
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

let test_glm_coding_auto_maps_to_glm_5_1 () =
  with_clean_env (fun () ->
    let resolved = R.resolve_auto_model_id "glm-coding" "auto" in
    check string "glm-coding:auto → glm-5.1"
      "glm-5.1" resolved)

let test_glm_coding_auto_models_default_order () =
  with_clean_env (fun () ->
    check (list string) "glm-coding:auto expands to coding-plan order"
      [
        "glm-5.1";
        "glm-5";
        "glm-5-turbo";
        "glm-4.7";
        "glm-4.5-air";
      ]
      (R.glm_coding_auto_models ()))

let test_gemini_cli_auto_models_default_rotation_order () =
  with_clean_env (fun () ->
    check (list string) "gemini_cli:auto expands to quota-aware rotation"
      [
        "gemini-3-flash-preview";
        "gemini-3.1-flash-lite-preview";
        "gemini-2.5-flash";
        "gemini-2.5-flash-lite";
        "gemini-3.1-pro-preview";
        "gemini-2.5-pro";
      ]
      (R.gemini_cli_auto_models ()))

let test_gemini_cli_auto_models_env_override () =
  Unix.putenv "MASC_GEMINI_CLI_AUTO_MODELS"
    "gemini-a, gemini-b,, gemini-c ";
  let models = R.gemini_cli_auto_models () in
  Unix.putenv "MASC_GEMINI_CLI_AUTO_MODELS" "";
  check (list string) "operator override trims blanks"
    [ "gemini-a"; "gemini-b"; "gemini-c" ] models

let test_codex_and_claude_cli_auto_models_env_override () =
  with_clean_env (fun () ->
    check (list string) "codex default keeps ChatGPT-supported models only"
      [
        "gpt-5.2";
        "gpt-5.3-codex-spark";
        "gpt-5.3-codex";
        "gpt-5.4-mini";
        "gpt-5.4";
      ]
      (R.codex_cli_auto_models ());
    check (list string) "claude default delegates to CLI"
      [ "auto" ] (R.claude_code_auto_models ());
    Unix.putenv "MASC_CODEX_CLI_AUTO_MODELS" "gpt-a,gpt-b";
    Unix.putenv "MASC_CLAUDE_CODE_AUTO_MODELS" "sonnet,opus";
    let codex = R.codex_cli_auto_models () in
    let claude = R.claude_code_auto_models () in
    Unix.putenv "MASC_CODEX_CLI_AUTO_MODELS" "";
    Unix.putenv "MASC_CLAUDE_CODE_AUTO_MODELS" "";
    check (list string) "codex operator rotation"
      [ "gpt-a"; "gpt-b" ] codex;
    check (list string) "claude operator rotation"
      [ "sonnet"; "opus" ] claude)

let test_expand_auto_models_includes_cli_auto_specs () =
  with_clean_env (fun () ->
    let expanded =
      C.expand_auto_models
        [ "gemini_cli:auto"; "codex_cli:auto"; "claude_code:auto" ]
    in
    check (list string) "CLI auto specs expand in-place"
      [
        "gemini_cli:gemini-3-flash-preview";
        "gemini_cli:gemini-3.1-flash-lite-preview";
        "gemini_cli:gemini-2.5-flash";
        "gemini_cli:gemini-2.5-flash-lite";
        "gemini_cli:gemini-3.1-pro-preview";
        "gemini_cli:gemini-2.5-pro";
        "codex_cli:gpt-5.2";
        "codex_cli:gpt-5.3-codex-spark";
        "codex_cli:gpt-5.3-codex";
        "codex_cli:gpt-5.4-mini";
        "codex_cli:gpt-5.4";
        "claude_code:auto";
      ]
      expanded)

let test_expand_model_strings_for_execution_matches_auto_expansion () =
  with_clean_env (fun () ->
    let items = [ "glm-coding:auto"; "gemini_cli:auto" ] in
    check (list string) "execution expansion matches auto expansion"
      (C.expand_auto_models items)
      (C.expand_model_strings_for_execution items))

let test_expand_model_strings_for_execution_rotation_scope_rotates () =
  with_clean_env (fun () ->
    State.clear_all ();
    let first =
      C.expand_model_strings_for_execution
        ~rotation_scope:"keeper_unified"
        [ "gemini_cli:auto" ]
    in
    let second =
      C.expand_model_strings_for_execution
        ~rotation_scope:"keeper_unified"
        [ "gemini_cli:auto" ]
    in
    let other_scope =
      C.expand_model_strings_for_execution
        ~rotation_scope:"tool_rerank"
        [ "gemini_cli:auto" ]
    in
    check string "first scoped call starts at default head"
      "gemini_cli:gemini-3-flash-preview"
      (List.hd first);
    check string "second scoped call advances head"
      "gemini_cli:gemini-3.1-flash-lite-preview"
      (List.hd second);
    check string "different scope has its own cursor"
      "gemini_cli:gemini-3-flash-preview"
      (List.hd other_scope))

let test_order_weighted_entries_rotation_scope_rotates_generically () =
  with_clean_env (fun () ->
    State.clear_all ();
    let entry model =
      {
        Masc_mcp.Cascade_config_loader.model = model;
        weight = 1;
        supports_tool_choice = None;
      }
    in
    let first =
      C.order_weighted_entries
        ~rotation_scope:"keeper_unified"
        [ entry "codex_cli:auto" ]
      |> List.map (fun (e : Masc_mcp.Cascade_config_loader.weighted_entry) ->
             e.model)
    in
    let second =
      C.order_weighted_entries
        ~rotation_scope:"keeper_unified"
        [ entry "codex_cli:auto" ]
      |> List.map (fun (e : Masc_mcp.Cascade_config_loader.weighted_entry) ->
             e.model)
    in
    let other_scope =
      C.order_weighted_entries
        ~rotation_scope:"tool_rerank"
        [ entry "codex_cli:auto" ]
      |> List.map (fun (e : Masc_mcp.Cascade_config_loader.weighted_entry) ->
             e.model)
    in
    check string "weighted first call keeps default head"
      "codex_cli:gpt-5.2"
      (List.hd first);
    check string "weighted second call advances head"
      "codex_cli:gpt-5.3-codex-spark"
      (List.hd second);
    check string "weighted rotation is scoped"
      "codex_cli:gpt-5.2"
      (List.hd other_scope))

let () =
  run "Cascade_model_resolve" [
    "gemini auto", [
      test_case "glm-coding:auto"
        `Quick test_glm_coding_auto_maps_to_glm_5_1;
      test_case "glm-coding:auto model list"
        `Quick test_glm_coding_auto_models_default_order;
      test_case "gemini:auto"
        `Quick test_gemini_auto_maps_to_flash_preview;
      test_case "gemini_cli:auto (regression 2026-04-20)"
        `Quick test_gemini_cli_auto_maps_to_flash_preview;
      test_case "gemini_cli explicit"
        `Quick test_gemini_cli_explicit_model_passthrough;
      test_case "GEMINI_DEFAULT_MODEL env override"
        `Quick test_gemini_env_override;
      test_case "gemini_cli:auto model list"
        `Quick test_gemini_cli_auto_models_default_rotation_order;
      test_case "gemini_cli:auto env list override"
        `Quick test_gemini_cli_auto_models_env_override;
      test_case "codex/claude cli auto env list override"
        `Quick test_codex_and_claude_cli_auto_models_env_override;
      test_case "expand_auto_models covers CLI auto"
        `Quick test_expand_auto_models_includes_cli_auto_specs;
      test_case "execution expansion matches auto expansion"
        `Quick test_expand_model_strings_for_execution_matches_auto_expansion;
      test_case "execution expansion can rotate by scope"
        `Quick test_expand_model_strings_for_execution_rotation_scope_rotates;
      test_case "weighted ordering rotates auto by scope"
        `Quick test_order_weighted_entries_rotation_scope_rotates_generically;
    ];
  ]
