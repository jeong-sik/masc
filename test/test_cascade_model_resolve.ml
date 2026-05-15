(** Unit tests for generic cascade model resolution.

    These tests install a synthetic OAS provider catalog so MASC verifies the
    boundary contract without pinning real vendor model catalogs. *)

open Alcotest
module R = Masc_mcp.Cascade_model_resolve
module C = Masc_mcp.Cascade_config
module State = Masc_mcp.Cascade_state
module H = Masc_mcp.Cascade_health_tracker

let synthetic_catalog_json =
  {|
{
  "schema_version": 1,
  "providers": [
    {
      "id": "synthetic-api",
      "aliases": ["synthetic_api"],
      "kind": "openai_compat",
      "transport": "http",
      "base_url": "https://synthetic.example/v1",
      "request_path": "/chat/completions",
      "auth": {"type": "api_key_env", "env": "SYNTHETIC_API_KEY"},
      "default_model": "api-default",
      "capabilities_base": "openai_chat",
      "capabilities": {
        "supported_models": ["api-a", "api-b", "api-c"]
      },
      "non_interactive": true,
      "interactive_required": false,
      "daemon_safe": true
    },
    {
      "id": "synthetic-cli",
      "aliases": ["synthetic_cli"],
      "kind": "codex_cli",
      "transport": "cli",
      "command": "synthetic-cli",
      "auth": {"type": "cli_cached_login"},
      "capabilities_base": "codex_cli",
      "non_interactive": true,
      "interactive_required": false,
      "daemon_safe": true
    },
    {
      "id": "synthetic-direct",
      "aliases": ["synthetic_direct"],
      "kind": "openai_compat",
      "transport": "http",
      "base_url": "https://direct.example/v1",
      "request_path": "/chat/completions",
      "auth": {"type": "api_key_env", "env": "SYNTHETIC_DIRECT_KEY"},
      "capabilities_base": "openai_chat",
      "non_interactive": true,
      "interactive_required": false,
      "daemon_safe": true
    },
    {
      "id": "synthetic-local",
      "aliases": ["synthetic_local"],
      "kind": "openai_compat",
      "transport": "http",
      "base_url": "http://127.0.0.1:8123",
      "request_path": "/v1/chat/completions",
      "auth": {"type": "none"},
      "capabilities_base": "openai_chat",
      "non_interactive": true,
      "interactive_required": false,
      "daemon_safe": true
    }
  ]
}
|}
;;

let install_synthetic_catalog () =
  match Llm_provider.Provider_catalog.of_json (Yojson.Safe.from_string synthetic_catalog_json) with
  | Error msg -> fail msg
  | Ok catalog -> Llm_provider.Provider_catalog.set_global catalog
;;

let unset_env k =
  try Unix.putenv k "" with
  | _ -> ()
;;

let with_clean_env f =
  List.iter
    unset_env
    [ "SYNTHETIC_API_DEFAULT_MODEL"
    ; "SYNTHETIC_CLI_DEFAULT_MODEL"
    ; "SYNTHETIC_DIRECT_DEFAULT_MODEL"
    ; "SYNTHETIC_LOCAL_DEFAULT_MODEL"
    ; "MASC_SYNTHETIC_API_AUTO_MODELS"
    ; "MASC_SYNTHETIC_CLI_AUTO_MODELS"
    ; "MASC_SYNTHETIC_DIRECT_AUTO_MODELS"
    ];
  f ()
;;

let prefixed provider model = provider ^ ":" ^ model

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

let require_first_model label = function
  | first :: _ -> first
  | [] -> fail (label ^ " produced no models")
;;

let require_second_model label = function
  | _ :: second :: _ -> second
  | _ -> fail (label ^ " produced fewer than two models")
;;

let test_api_auto_uses_binding_default () =
  with_clean_env (fun () ->
    let resolved = R.resolve_auto_model_id "synthetic-api" "auto" in
    check string "auto uses binding default" "api-default" resolved)
;;

let test_api_env_default_provenance () =
  let getenv = function
    | "SYNTHETIC_API_DEFAULT_MODEL" -> Some "operator-model"
    | _ -> None
  in
  let resolved =
    R.resolve_auto_model
      ~getenv
      "synthetic-api"
      (R.model_selector_of_string "auto")
  in
  check string "env default wins" "operator-model" resolved.resolved_model_id;
  check
    bool
    "env provenance"
    true
    (resolved.provenance = R.Env_default "SYNTHETIC_API_DEFAULT_MODEL")
;;

let test_cli_auto_delegates_without_catalog_models () =
  with_clean_env (fun () ->
    check
      string
      "cli auto delegates"
      "auto"
      (R.resolve_auto_model_id "synthetic-cli" "auto");
    check
      (list string)
      "cli auto expands to delegation token"
      [ "auto" ]
      (auto_models_for "synthetic-cli"))
;;

let test_explicit_model_passthrough_trims_result () =
  with_clean_env (fun () ->
    let resolved = R.resolve_auto_model_id "synthetic-api" " explicit-model " in
    check string "explicit model trimmed" "explicit-model" resolved)
;;

let test_unsupported_provider_auto_is_unresolved () =
  with_clean_env (fun () ->
    let resolved =
      R.resolve_auto_model
        ~getenv:(fun _ -> None)
        "unknown-provider"
        (R.model_selector_of_string "auto")
    in
    check string "unknown auto remains auto" "auto" resolved.resolved_model_id;
    check bool "unresolved provenance" true (resolved.provenance = R.Unresolved_auto))
;;

let test_supported_models_expand_from_binding () =
  with_clean_env (fun () ->
    check
      (list string)
      "supported models from OAS binding"
      [ "api-a"; "api-b"; "api-c" ]
      (auto_models_for "synthetic-api"))
;;

let test_auto_models_env_override () =
  with_clean_env (fun () ->
    Unix.putenv "MASC_SYNTHETIC_API_AUTO_MODELS" "override-a, override-b,, override-c ";
    let models = auto_models_for "synthetic-api" in
    Unix.putenv "MASC_SYNTHETIC_API_AUTO_MODELS" "";
    check
      (list string)
      "operator override trims blanks"
      [ "override-a"; "override-b"; "override-c" ]
      models)
;;

let test_direct_api_without_supported_models_does_not_expand () =
  with_clean_env (fun () ->
    check (list string) "no generic direct expansion" [ "auto" ] (auto_models_for "synthetic-direct");
    check
      string
      "runtime default remains delegated"
      "auto"
      (R.resolve_auto_model_id "synthetic-direct" "auto"))
;;

let test_expand_model_strings_for_execution_matches_auto_expansion () =
  with_clean_env (fun () ->
    let items = [ "synthetic-api:auto"; "synthetic-cli:auto" ] in
    check
      (list string)
      "execution expansion matches auto expansion"
      (C.expand_auto_models items)
      (C.expand_model_strings_for_execution items))
;;

let test_expand_model_strings_for_execution_dedupe_stable_repeated_inputs () =
  with_clean_env (fun () ->
    let items =
      [ "test-provider:model-a"
      ; "synthetic-api:api-a"
      ; "test-provider:model-a"
      ; "synthetic-api:api-a"
      ; "test-provider:model-a"
      ]
    in
    check
      (list string)
      "first occurrence wins, order preserved"
      [ "test-provider:model-a"; "synthetic-api:api-a" ]
      (C.expand_model_strings_for_execution items))
;;

let test_expand_model_strings_for_execution_dedupe_explicit_and_auto () =
  with_clean_env (fun () ->
    let first_model = require_first_model "synthetic-api catalog" (auto_models_for "synthetic-api") in
    let explicit = prefixed "synthetic-api" first_model in
    let items = [ explicit; "synthetic-api:auto" ] in
    let expanded = C.expand_model_strings_for_execution items in
    check string "explicit first occurrence retained at head" explicit (List.hd expanded);
    let occurrences = List.filter (String.equal explicit) expanded |> List.length in
    check int "no duplicate of explicit name" 1 occurrences;
    check bool "auto-expanded siblings present" true (List.length expanded > 1))
;;

let test_expand_model_strings_for_execution_rotation_scope_rotates () =
  with_clean_env (fun () ->
    let models = auto_models_for "synthetic-api" in
    let first_model = require_first_model "synthetic-api catalog" models in
    let second_model = require_second_model "synthetic-api catalog" models in
    State.clear_all ();
    let first =
      C.expand_model_strings_for_execution
        ~rotation_scope:"primary"
        [ "synthetic-api:auto" ]
    in
    let second =
      C.expand_model_strings_for_execution
        ~rotation_scope:"primary"
        [ "synthetic-api:auto" ]
    in
    let other_scope =
      C.expand_model_strings_for_execution
        ~rotation_scope:"scoring"
        [ "synthetic-api:auto" ]
    in
    check
      string
      "first scoped call starts at default head"
      (prefixed "synthetic-api" first_model)
      (List.hd first);
    check
      string
      "second scoped call advances head"
      (prefixed "synthetic-api" second_model)
      (List.hd second);
    check
      string
      "different scope has its own cursor"
      (prefixed "synthetic-api" first_model)
      (List.hd other_scope))
;;

let test_order_weighted_entries_rotation_scope_rotates_generically () =
  with_clean_env (fun () ->
    let models = auto_models_for "synthetic-api" in
    let first_model = require_first_model "synthetic-api catalog" models in
    let second_model = require_second_model "synthetic-api catalog" models in
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
      C.order_weighted_entries ~rotation_scope:"primary" [ entry "synthetic-api:auto" ]
      |> List.map (fun (e : Masc_mcp.Cascade_config_loader.weighted_entry) -> e.model)
    in
    let second =
      C.order_weighted_entries ~rotation_scope:"primary" [ entry "synthetic-api:auto" ]
      |> List.map (fun (e : Masc_mcp.Cascade_config_loader.weighted_entry) -> e.model)
    in
    let other_scope =
      C.order_weighted_entries ~rotation_scope:"scoring" [ entry "synthetic-api:auto" ]
      |> List.map (fun (e : Masc_mcp.Cascade_config_loader.weighted_entry) -> e.model)
    in
    check
      string
      "weighted first call keeps default head"
      (prefixed "synthetic-api" first_model)
      (List.hd first);
    check
      string
      "weighted second call advances head"
      (prefixed "synthetic-api" second_model)
      (List.hd second);
    check
      string
      "weighted rotation is scoped"
      (prefixed "synthetic-api" first_model)
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
      [ entry "provider-a:model"; entry "provider-b:model"; entry "provider-c:model" ]
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
    check string "first call starts with declared provider" "provider-a:model" (List.hd first);
    check string "second call rotates to next provider" "provider-b:model" (List.hd second);
    check string "third call rotates to third provider" "provider-c:model" (List.hd third);
    check
      string
      "different scope restarts top-level provider order"
      "provider-a:model"
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
    check string "cooled provider model is skipped" "other-provider:model-a" (List.hd ordered))
;;

let () =
  install_synthetic_catalog ();
  run
    "Cascade_model_resolve"
    [ ( "generic auto"
      , [ test_case "api auto binding default" `Quick test_api_auto_uses_binding_default
        ; test_case "api env default provenance" `Quick test_api_env_default_provenance
        ; test_case "cli auto delegates by default" `Quick test_cli_auto_delegates_without_catalog_models
        ; test_case "explicit model passthrough" `Quick test_explicit_model_passthrough_trims_result
        ; test_case "unknown auto unresolved" `Quick test_unsupported_provider_auto_is_unresolved
        ; test_case "supported model expansion" `Quick test_supported_models_expand_from_binding
        ; test_case "auto model env override" `Quick test_auto_models_env_override
        ; test_case
            "direct api without supported models"
            `Quick
            test_direct_api_without_supported_models_does_not_expand
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
