(** Unit tests for Cascade_model_resolve.resolve_auto_model_id.

    Focus: "auto" → concrete model ID translation for cloud providers.
    Current boundary: MASC does not bake hosted CLI model menus into the
    runtime catalog. CLI `auto` is passed through unless an operator provides
    an explicit `MASC_<PROVIDER>_AUTO_MODELS` rotation override. *)

open Alcotest
module R = Masc_mcp.Cascade_model_resolve
module C = Masc_mcp.Cascade_config
module State = Masc_mcp.Cascade_state
module H = Masc_mcp.Cascade_health_tracker
module PA = Masc_mcp.Runtime_catalog

(* RFC-0058 Phase 5.3a — the per-provider thin wrappers
   ([gemini_cli_auto_models], etc.) were deleted because they were unused
   in production. Tests now exercise the generic
   [Runtime_catalog.auto_models_for_cascade_prefix] entry point directly;
   the provider id is the test's pin, not a production literal. *)
let auto_models_for pid =
  PA.auto_models_for_cascade_prefix pid |> Option.value ~default:[]
;;

let unset_env k =
  try Unix.putenv k "" with
  | _ -> ()
;;

let with_clean_env f =
  List.iter
    unset_env
    [ "ZAI_CODING_DEFAULT_MODEL"
    ; "ZAI_CODING_AUTO_MODELS"
    ; "GEMINI_DEFAULT_MODEL"
    ; "ANTHROPIC_DEFAULT_MODEL"
    ; "OPENAI_DEFAULT_MODEL"
    ; "OPENROUTER_DEFAULT_MODEL"
    ; "OLLAMA_DEFAULT_MODEL"
    ; "MASC_GEMINI_CLI_AUTO_MODELS"
    ; "MASC_CODEX_CLI_AUTO_MODELS"
    ; "MASC_CLAUDE_CODE_AUTO_MODELS"
    ; "MASC_KIMI_CLI_AUTO_MODELS"
    ];
  f ()
;;

let test_gemini_auto_maps_to_flash_preview () =
  with_clean_env (fun () ->
    let resolved = R.resolve_auto_model_id "gemini" "auto" in
    check string "gemini:auto → gemini-3-flash-preview" "gemini-3-flash-preview" resolved)
;;

let test_gemini_cli_auto_passes_through () =
  with_clean_env (fun () ->
    let resolved = R.resolve_auto_model_id "gemini_cli" "auto" in
    check string "gemini_cli:auto passes through to CLI" "auto" resolved)
;;

let test_gemini_cli_explicit_model_passthrough () =
  with_clean_env (fun () ->
    let resolved = R.resolve_auto_model_id "gemini_cli" "gemini-3-flash-preview" in
    check string "explicit model untouched" "gemini-3-flash-preview" resolved)
;;

let test_gemini_env_override () =
  Unix.putenv "GEMINI_DEFAULT_MODEL" "gemini-3-flash-preview";
  let resolved_gemini = R.resolve_auto_model_id "gemini" "auto" in
  let resolved_cli = R.resolve_auto_model_id "gemini_cli" "auto" in
  Unix.putenv "GEMINI_DEFAULT_MODEL" "";
  check string "gemini respects env override" "gemini-3-flash-preview" resolved_gemini;
  check
    string
    "gemini_cli ignores API default env and delegates to CLI"
    "auto"
    resolved_cli
;;

let test_glm_coding_auto_maps_to_glm_5_1 () =
  with_clean_env (fun () ->
    let resolved = R.resolve_auto_model_id "glm-coding" "auto" in
    check string "glm-coding:auto → glm-5.1" "glm-5.1" resolved)
;;

let test_glm_coding_auto_models_default_order () =
  with_clean_env (fun () ->
    check
      (list string)
      "glm-coding:auto expands to coding-plan order"
      [ "glm-5.1"; "glm-5"; "glm-5-turbo"; "glm-4.7"; "glm-4.5-air" ]
      (R.glm_coding_auto_models ()))
;;

let test_gemini_cli_auto_models_has_no_default_rotation () =
  with_clean_env (fun () ->
    check
      (list string)
      "gemini_cli:auto has no baked-in rotation"
      []
      (auto_models_for "gemini_cli"))
;;

let test_gemini_cli_auto_models_env_override () =
  Unix.putenv "MASC_GEMINI_CLI_AUTO_MODELS" "gemini-a, gemini-b,, gemini-c ";
  let models = auto_models_for "gemini_cli" in
  Unix.putenv "MASC_GEMINI_CLI_AUTO_MODELS" "";
  check
    (list string)
    "operator override trims blanks"
    [ "gemini-a"; "gemini-b"; "gemini-c" ]
    models
;;

let test_codex_and_claude_cli_auto_models_env_override () =
  with_clean_env (fun () ->
    check
      (list string)
      "codex default delegates to CLI"
      []
      (auto_models_for "codex_cli");
    check
      (list string)
      "claude default delegates to CLI"
      []
      (auto_models_for "claude_code");
    Unix.putenv "MASC_CODEX_CLI_AUTO_MODELS" "gpt-a,gpt-b";
    Unix.putenv "MASC_CLAUDE_CODE_AUTO_MODELS" "sonnet,opus";
    let codex = auto_models_for "codex_cli" in
    let claude = auto_models_for "claude_code" in
    Unix.putenv "MASC_CODEX_CLI_AUTO_MODELS" "";
    Unix.putenv "MASC_CLAUDE_CODE_AUTO_MODELS" "";
    check (list string) "codex operator rotation" [ "gpt-a"; "gpt-b" ] codex;
    check (list string) "claude operator rotation" [ "sonnet"; "opus" ] claude)
;;

let test_kimi_cli_auto_model_policy () =
  with_clean_env (fun () ->
    check
      string
      "kimi_cli:auto delegates to CLI"
      "auto"
      (R.resolve_auto_model_id "kimi_cli" "auto");
    check
      (list string)
      "kimi_cli:auto has no baked-in rotation"
      []
      (auto_models_for "kimi_cli");
    Unix.putenv "MASC_KIMI_CLI_AUTO_MODELS" "kimi-a,kimi-b";
    let models = auto_models_for "kimi_cli" in
    Unix.putenv "MASC_KIMI_CLI_AUTO_MODELS" "";
    check (list string) "kimi cli operator rotation" [ "kimi-a"; "kimi-b" ] models)
;;

let test_expand_auto_models_includes_cli_auto_specs () =
  with_clean_env (fun () ->
    let expanded =
      C.expand_auto_models
        [ "gemini_cli:auto"; "codex_cli:auto"; "claude_code:auto"; "kimi_cli:auto" ]
    in
    check
      (list string)
      "CLI auto specs expand in-place"
      [ "gemini_cli:auto"; "codex_cli:auto"; "claude_code:auto"; "kimi_cli:auto" ]
      expanded)
;;

let test_expand_model_strings_for_execution_matches_auto_expansion () =
  with_clean_env (fun () ->
    let items = [ "glm-coding:auto"; "gemini_cli:auto" ] in
    check
      (list string)
      "execution expansion matches auto expansion"
      (C.expand_auto_models items)
      (C.expand_model_strings_for_execution items))
;;

let test_expand_model_strings_for_execution_dedupe_stable_repeated_inputs () =
  with_clean_env (fun () ->
    (* Pure repeated literals: dedupe must keep first occurrence and
       preserve insertion order. *)
    let items =
      [ "codex_cli:gpt-5.2"
      ; "kimi_cli:kimi-for-coding"
      ; "codex_cli:gpt-5.2"
      ; "kimi_cli:kimi-for-coding"
      ; "codex_cli:gpt-5.2"
      ]
    in
    check
      (list string)
      "first occurrence wins, order preserved"
      [ "codex_cli:gpt-5.2"; "kimi_cli:kimi-for-coding" ]
      (C.expand_model_strings_for_execution items))
;;

let test_expand_model_strings_for_execution_dedupe_explicit_and_auto () =
  with_clean_env (fun () ->
    (* Explicit model that an auto-expansion would also produce: the
       explicit one (declared first) wins; the auto-expansion's
       contribution of the same name is dropped, but its other entries
       remain in expansion order. *)
    let items = [ "codex_cli:gpt-5.2"; "codex_cli:auto" ] in
    let expanded = C.expand_model_strings_for_execution items in
    (* (a) head is the explicit declaration *)
    check
      string
      "explicit first occurrence retained at head"
      "codex_cli:gpt-5.2"
      (List.hd expanded);
    (* (b) duplicate of the explicit name does not reappear *)
    let occurrences =
      List.filter (String.equal "codex_cli:gpt-5.2") expanded |> List.length
    in
    check int "no duplicate of explicit name" 1 occurrences;
    (* (c) CLI auto is a distinct runtime selector, not a baked-in model list. *)
    check bool "cli auto selector remains present" true
      (List.exists (String.equal "codex_cli:auto") expanded))
;;

let test_expand_model_strings_for_execution_rotation_scope_rotates () =
  with_clean_env (fun () ->
    State.clear_all ();
    let first =
      C.expand_model_strings_for_execution
        ~rotation_scope:"big_three"
        [ "glm-coding:auto" ]
    in
    let second =
      C.expand_model_strings_for_execution
        ~rotation_scope:"big_three"
        [ "glm-coding:auto" ]
    in
    let other_scope =
      C.expand_model_strings_for_execution
        ~rotation_scope:"tool_rerank"
        [ "glm-coding:auto" ]
    in
    check
      string
      "first scoped call starts at default head"
      "glm-coding:glm-5.1"
      (List.hd first);
    check
      string
      "second scoped call advances head"
      "glm-coding:glm-5"
      (List.hd second);
    check
      string
      "different scope has its own cursor"
      "glm-coding:glm-5.1"
      (List.hd other_scope))
;;

let test_order_weighted_entries_rotation_scope_rotates_generically () =
  with_clean_env (fun () ->
    State.clear_all ();
    let entry model =
      { Masc_mcp.Cascade_config_loader.model
      ; weight = 1
      ; supports_tool_choice = None
      ; secondary = None
      ; secondary_supports_tool_choice = None
      }
    in
    let first =
      C.order_weighted_entries ~rotation_scope:"big_three" [ entry "glm-coding:auto" ]
      |> List.map (fun (e : Masc_mcp.Cascade_config_loader.weighted_entry) -> e.model)
    in
    let second =
      C.order_weighted_entries ~rotation_scope:"big_three" [ entry "glm-coding:auto" ]
      |> List.map (fun (e : Masc_mcp.Cascade_config_loader.weighted_entry) -> e.model)
    in
    let other_scope =
      C.order_weighted_entries ~rotation_scope:"tool_rerank" [ entry "glm-coding:auto" ]
      |> List.map (fun (e : Masc_mcp.Cascade_config_loader.weighted_entry) -> e.model)
    in
    check
      string
      "weighted first call keeps default head"
      "glm-coding:glm-5.1"
      (List.hd first);
    check
      string
      "weighted second call advances head"
      "glm-coding:glm-5"
      (List.hd second);
    check string "weighted rotation is scoped" "glm-coding:glm-5.1" (List.hd other_scope))
;;

let test_order_weighted_entries_rotation_scope_rotates_top_level_providers () =
  with_clean_env (fun () ->
    State.clear_all ();
    let entry model =
      { Masc_mcp.Cascade_config_loader.model
      ; weight = 1
      ; supports_tool_choice = None
      ; secondary = None
      ; secondary_supports_tool_choice = None
      }
    in
    let entries =
      [ entry "claude_code:auto"; entry "codex_cli:auto"; entry "gemini_cli:auto" ]
    in
    let first =
      C.order_weighted_entries ~rotation_scope:"big_three" entries
      |> List.map (fun (e : Masc_mcp.Cascade_config_loader.weighted_entry) -> e.model)
    in
    let second =
      C.order_weighted_entries ~rotation_scope:"big_three" entries
      |> List.map (fun (e : Masc_mcp.Cascade_config_loader.weighted_entry) -> e.model)
    in
    let third =
      C.order_weighted_entries ~rotation_scope:"big_three" entries
      |> List.map (fun (e : Masc_mcp.Cascade_config_loader.weighted_entry) -> e.model)
    in
    let other_scope =
      C.order_weighted_entries ~rotation_scope:"tool_rerank" entries
      |> List.map (fun (e : Masc_mcp.Cascade_config_loader.weighted_entry) -> e.model)
    in
    check
      string
      "first call starts with declared provider"
      "claude_code:auto"
      (List.hd first);
    check string "second call rotates to codex provider" "codex_cli:auto" (List.hd second);
    check
      string
      "third call rotates to gemini provider"
      "gemini_cli:auto"
      (List.hd third);
    check
      string
      "different scope restarts top-level provider order"
      "claude_code:auto"
      (List.hd other_scope))
;;

let test_order_weighted_entries_cooldown_is_provider_scoped () =
  with_clean_env (fun () ->
    let entry model =
      { Masc_mcp.Cascade_config_loader.model
      ; weight = 100
      ; supports_tool_choice = None
      ; secondary = None
      ; secondary_supports_tool_choice = None
      }
    in
    H.record_failure H.global ~provider_key:"test-provider" ();
    H.record_failure H.global ~provider_key:"test-provider" ();
    H.record_failure H.global ~provider_key:"test-provider" ();
    let ordered =
      C.order_weighted_entries
        ~rand_int:(fun _ -> 0)
        [ entry "test-provider:model-a"; entry "other-provider:model-a" ]
      |> List.map (fun (e : Masc_mcp.Cascade_config_loader.weighted_entry) -> e.model)
    in
    check
      string
      "cooled provider model is skipped"
      "other-provider:model-a"
      (List.hd ordered))
;;

let () =
  run
    "Cascade_model_resolve"
    [ ( "gemini auto"
      , [ test_case "glm-coding:auto" `Quick test_glm_coding_auto_maps_to_glm_5_1
        ; test_case
            "glm-coding:auto model list"
            `Quick
            test_glm_coding_auto_models_default_order
        ; test_case "gemini:auto" `Quick test_gemini_auto_maps_to_flash_preview
        ; test_case
            "gemini_cli:auto (regression 2026-04-20)"
            `Quick
            test_gemini_cli_auto_passes_through
        ; test_case
            "gemini_cli explicit"
            `Quick
            test_gemini_cli_explicit_model_passthrough
        ; test_case "GEMINI_DEFAULT_MODEL env override" `Quick test_gemini_env_override
        ; test_case
            "gemini_cli:auto model list"
            `Quick
            test_gemini_cli_auto_models_has_no_default_rotation
        ; test_case
            "gemini_cli:auto env list override"
            `Quick
            test_gemini_cli_auto_models_env_override
        ; test_case
            "codex/claude cli auto env list override"
            `Quick
            test_codex_and_claude_cli_auto_models_env_override
        ; test_case "kimi_cli:auto policy" `Quick test_kimi_cli_auto_model_policy
        ; test_case
            "expand_auto_models covers CLI auto"
            `Quick
            test_expand_auto_models_includes_cli_auto_specs
        ; test_case
            "execution expansion matches auto expansion"
            `Quick
            test_expand_model_strings_for_execution_matches_auto_expansion
        ; test_case
            "dedupe_stable: first wins on repeats"
            `Quick
            test_expand_model_strings_for_execution_dedupe_stable_repeated_inputs
        ; test_case
            "dedupe_stable: explicit beats auto-expansion"
            `Quick
            test_expand_model_strings_for_execution_dedupe_explicit_and_auto
        ; test_case
            "execution expansion can rotate by scope"
            `Quick
            test_expand_model_strings_for_execution_rotation_scope_rotates
        ; test_case
            "weighted ordering rotates auto by scope"
            `Quick
            test_order_weighted_entries_rotation_scope_rotates_generically
        ; test_case
            "weighted ordering rotates provider order by scope"
            `Quick
            test_order_weighted_entries_rotation_scope_rotates_top_level_providers
        ; test_case
            "weighted ordering cooldown is provider scoped"
            `Quick
            test_order_weighted_entries_cooldown_is_provider_scoped
        ] )
    ]
;;
