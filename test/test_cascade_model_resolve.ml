(** Unit tests for Cascade_model_resolve.resolve_auto_model_id.

    Focus: "auto" handling without reintroducing MASC-side concrete model
    lists. GLM resolves through the OAS ZAI catalog because the HTTP API needs
    a concrete model id. CLI providers keep "auto" as the default delegation
    path unless the operator supplies MASC_<PROVIDER>_AUTO_MODELS. *)

open Alcotest
module R = Masc_mcp.Cascade_model_resolve
module C = Masc_mcp.Cascade_config
module State = Masc_mcp.Cascade_state
module H = Masc_mcp.Cascade_health_tracker

(* RFC-0058 Phase 5.3a — the per-provider thin wrappers
   ([gemini_cli_auto_models], etc.) were deleted because they were unused
   in production. Tests now exercise the generic
   [Cascade_config.expand_auto_models] production path; the provider id is the
   test's pin, not a production literal in the test body. *)
let auto_models_for pid =
  let prefix = pid ^ ":" in
  let prefix_len = String.length prefix in
  C.expand_auto_models [ prefix ^ "auto" ]
  |> List.filter_map (fun spec ->
    if String.length spec >= prefix_len
       && String.equal (String.sub spec 0 prefix_len) prefix
    then Some (String.sub spec prefix_len (String.length spec - prefix_len))
    else None)
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
    ; "GEMINI_CLI_DEFAULT_MODEL"
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

let require_first_model label = function
  | first :: _ -> first
  | [] -> fail (label ^ " produced no models")
;;

let require_second_model label = function
  | _ :: second :: _ -> second
  | _ -> fail (label ^ " produced fewer than two models")
;;

let glm_coding_catalog_models () =
  let models = R.glm_coding_auto_models () in
  check bool "glm-coding catalog has concrete models" true (models <> []);
  check bool "glm-coding catalog does not delegate auto" true
    (not (List.exists (String.equal "auto") models));
  models
;;

let prefixed provider model = provider ^ ":" ^ model

let test_gemini_auto_without_env_delegates () =
  with_clean_env (fun () ->
    let resolved = R.resolve_auto_model_id "gemini" "auto" in
    check string "gemini:auto without env stays delegated" "auto" resolved)
;;

let test_gemini_cli_auto_without_env_delegates () =
  with_clean_env (fun () ->
    let resolved = R.resolve_auto_model_id "gemini_cli" "auto" in
    check string "gemini_cli:auto delegates to CLI default" "auto" resolved)
;;

let test_gemini_cli_explicit_model_passthrough () =
  with_clean_env (fun () ->
    let resolved = R.resolve_auto_model_id "gemini_cli" "explicit-model" in
    check string "explicit model untouched" "explicit-model" resolved)
;;

let test_gemini_env_override () =
  Unix.putenv "GEMINI_DEFAULT_MODEL" "operator-gemini-model";
  Unix.putenv "GEMINI_CLI_DEFAULT_MODEL" "operator-gemini-cli-model";
  let resolved_gemini = R.resolve_auto_model_id "gemini" "auto" in
  let resolved_cli = R.resolve_auto_model_id "gemini_cli" "auto" in
  Unix.putenv "GEMINI_DEFAULT_MODEL" "";
  Unix.putenv "GEMINI_CLI_DEFAULT_MODEL" "";
  check string "gemini respects env override" "operator-gemini-model" resolved_gemini;
  check
    string
    "gemini_cli respects cli env override"
    "operator-gemini-cli-model"
    resolved_cli
;;

let test_glm_coding_auto_maps_to_glm_5_1 () =
  with_clean_env (fun () ->
    let expected = require_first_model "glm-coding catalog" (glm_coding_catalog_models ()) in
    let resolved = R.resolve_auto_model_id "glm-coding" "auto" in
    check string "glm-coding:auto resolves to OAS catalog head" expected resolved)
;;

let test_glm_coding_auto_models_catalog_order () =
  with_clean_env (fun () ->
    let models = glm_coding_catalog_models () in
    check
      (list string)
      "generic expansion follows OAS catalog order"
      models
      (auto_models_for "glm-coding"))
;;

let test_gemini_cli_auto_models_default_rotation_order () =
  with_clean_env (fun () ->
    check
      (list string)
      "gemini_cli:auto default delegates to CLI"
      [ "auto" ]
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
      [ "auto" ]
      (auto_models_for "codex_cli");
    check
      (list string)
      "claude default delegates to CLI"
      [ "auto" ]
      (auto_models_for "claude_code");
    Unix.putenv "MASC_CODEX_CLI_AUTO_MODELS" "model-a,model-b";
    Unix.putenv "MASC_CLAUDE_CODE_AUTO_MODELS" "sonnet,opus";
    let codex = auto_models_for "codex_cli" in
    let claude = auto_models_for "claude_code" in
    Unix.putenv "MASC_CODEX_CLI_AUTO_MODELS" "";
    Unix.putenv "MASC_CLAUDE_CODE_AUTO_MODELS" "";
    check (list string) "codex operator rotation" [ "model-a"; "model-b" ] codex;
    check (list string) "claude operator rotation" [ "sonnet"; "opus" ] claude)
;;

let test_kimi_cli_auto_model_policy () =
  with_clean_env (fun () ->
    let declared_default =
      match auto_models_for "kimi_cli" with
      | [ model ] -> model
      | models ->
        fail
          (Printf.sprintf
             "expected one kimi_cli declared default, got: %s"
             (String.concat "," models))
    in
    check
      string
      "kimi_cli:auto resolves to concrete CLI default"
      declared_default
      (R.resolve_auto_model_id "kimi_cli" "auto");
    check
      (list string)
      "kimi_cli:auto expands to declared default"
      [ declared_default ]
      (auto_models_for "kimi_cli");
    Unix.putenv "MASC_KIMI_CLI_AUTO_MODELS" "model-a,model-b";
    let models = auto_models_for "kimi_cli" in
    Unix.putenv "MASC_KIMI_CLI_AUTO_MODELS" "";
    check (list string) "kimi cli operator rotation" [ "model-a"; "model-b" ] models)
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
      [ "gemini_cli:auto"
      ; "codex_cli:auto"
      ; "claude_code:auto"
      ; "kimi_cli:kimi-for-coding"
      ]
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
      [ "test-provider:model-a"
      ; "kimi_cli:kimi-for-coding"
      ; "test-provider:model-a"
      ; "kimi_cli:kimi-for-coding"
      ; "test-provider:model-a"
      ]
    in
    check
      (list string)
      "first occurrence wins, order preserved"
      [ "test-provider:model-a"; "kimi_cli:kimi-for-coding" ]
      (C.expand_model_strings_for_execution items))
;;

let test_expand_model_strings_for_execution_dedupe_explicit_and_auto () =
  with_clean_env (fun () ->
    let first_glm_model =
      require_first_model "glm-coding catalog" (glm_coding_catalog_models ())
    in
    let explicit_glm = prefixed "glm-coding" first_glm_model in
    (* Explicit model that an auto-expansion would also produce: the
       explicit one (declared first) wins; the auto-expansion's
       contribution of the same name is dropped, but its other entries
       remain in expansion order. *)
    let items = [ explicit_glm; "glm-coding:auto" ] in
    let expanded = C.expand_model_strings_for_execution items in
    (* (a) head is the explicit declaration *)
    check
      string
      "explicit first occurrence retained at head"
      explicit_glm
      (List.hd expanded);
    (* (b) duplicate of the explicit name does not reappear *)
    let occurrences =
      List.filter (String.equal explicit_glm) expanded |> List.length
    in
    check int "no duplicate of explicit name" 1 occurrences;
    (* (c) auto-expansion of other entries still present (sanity) *)
    check bool "auto-expanded siblings present" true (List.length expanded > 1))
;;

let test_expand_model_strings_for_execution_rotation_scope_rotates () =
  with_clean_env (fun () ->
    let models = glm_coding_catalog_models () in
    let first_model = require_first_model "glm-coding catalog" models in
    let second_model = require_second_model "glm-coding catalog" models in
    State.clear_all ();
    let first =
      C.expand_model_strings_for_execution
        ~rotation_scope:"primary"
        [ "glm-coding:auto" ]
    in
    let second =
      C.expand_model_strings_for_execution
        ~rotation_scope:"primary"
        [ "glm-coding:auto" ]
    in
    let other_scope =
      C.expand_model_strings_for_execution
        ~rotation_scope:"scoring"
        [ "glm-coding:auto" ]
    in
    check
      string
      "first scoped call starts at default head"
      (prefixed "glm-coding" first_model)
      (List.hd first);
    check
      string
      "second scoped call advances head"
      (prefixed "glm-coding" second_model)
      (List.hd second);
    check
      string
      "different scope has its own cursor"
      (prefixed "glm-coding" first_model)
      (List.hd other_scope))
;;

let test_order_weighted_entries_rotation_scope_rotates_generically () =
  with_clean_env (fun () ->
    let models = glm_coding_catalog_models () in
    let first_model = require_first_model "glm-coding catalog" models in
    let second_model = require_second_model "glm-coding catalog" models in
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
      C.order_weighted_entries ~rotation_scope:"primary" [ entry "glm-coding:auto" ]
      |> List.map (fun (e : Masc_mcp.Cascade_config_loader.weighted_entry) -> e.model)
    in
    let second =
      C.order_weighted_entries ~rotation_scope:"primary" [ entry "glm-coding:auto" ]
      |> List.map (fun (e : Masc_mcp.Cascade_config_loader.weighted_entry) -> e.model)
    in
    let other_scope =
      C.order_weighted_entries ~rotation_scope:"scoring" [ entry "glm-coding:auto" ]
      |> List.map (fun (e : Masc_mcp.Cascade_config_loader.weighted_entry) -> e.model)
    in
    check
      string
      "weighted first call keeps default head"
      (prefixed "glm-coding" first_model)
      (List.hd first);
    check
      string
      "weighted second call advances head"
      (prefixed "glm-coding" second_model)
      (List.hd second);
    check
      string
      "weighted rotation is scoped"
      (prefixed "glm-coding" first_model)
      (List.hd other_scope))
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
      C.order_weighted_entries ~rotation_scope:"primary" entries
      |> List.map (fun (e : Masc_mcp.Cascade_config_loader.weighted_entry) -> e.model)
    in
    let second =
      C.order_weighted_entries ~rotation_scope:"primary" entries
      |> List.map (fun (e : Masc_mcp.Cascade_config_loader.weighted_entry) -> e.model)
    in
    let third =
      C.order_weighted_entries ~rotation_scope:"primary" entries
      |> List.map (fun (e : Masc_mcp.Cascade_config_loader.weighted_entry) -> e.model)
    in
    let other_scope =
      C.order_weighted_entries ~rotation_scope:"scoring" entries
      |> List.map (fun (e : Masc_mcp.Cascade_config_loader.weighted_entry) -> e.model)
    in
    check
      string
      "first call starts with declared provider"
      "claude_code:auto"
      (List.hd first);
    check
      string
      "second call rotates to codex provider"
      "codex_cli:auto"
      (List.hd second);
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
            test_glm_coding_auto_models_catalog_order
        ; test_case "gemini:auto" `Quick test_gemini_auto_without_env_delegates
        ; test_case
            "gemini_cli:auto delegates by default"
            `Quick
            test_gemini_cli_auto_without_env_delegates
        ; test_case
            "gemini_cli explicit"
            `Quick
            test_gemini_cli_explicit_model_passthrough
        ; test_case "GEMINI_DEFAULT_MODEL env override" `Quick test_gemini_env_override
        ; test_case
            "gemini_cli:auto model list"
            `Quick
            test_gemini_cli_auto_models_default_rotation_order
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
