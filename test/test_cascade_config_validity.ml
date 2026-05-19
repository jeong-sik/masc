(** RFC-0058 cascade config SSOT validity gate.

    CI calls this test directly to keep [config/cascade.toml] as the checked-in
    authoring source and to prevent the retired [config/cascade.json] from
    reappearing as a second source of truth. *)

open Alcotest

module Adapter = Masc_mcp.Cascade_declarative_adapter
module Parser = Cascade_declarative_parser
module Types = Cascade_declarative_types
module Validator = Cascade_declarative_validator

let config_path name =
  Filename.concat
    (Filename.concat (Masc_test_deps.find_project_root ()) "config")
    name
;;

let parse_errors_to_string errs =
  errs
  |> List.map (fun (err : Parser.parse_error) ->
    Printf.sprintf "%s: %s" err.path err.message)
  |> String.concat "; "
;;

let validation_errors_to_string errs =
  errs
  |> List.map (fun (err : Validator.validation_error) ->
    Printf.sprintf "%s %s: %s" err.rule err.path err.message)
  |> String.concat "; "
;;

let adapter_errors_to_string errs =
  errs |> List.map Adapter.show_adapter_error |> String.concat "; "
;;

let load_checked_in_cascade_toml () =
  let path = config_path "cascade.toml" in
  match Parser.parse_file path with
  | Ok cfg -> cfg
  | Error errs ->
    failf "failed to parse %s: %s" path (parse_errors_to_string errs)
;;

let test_cascade_toml_validates () =
  let cfg = load_checked_in_cascade_toml () in
  let validation_errors = Validator.validate cfg in
  check
    string
    "validator errors"
    ""
    (validation_errors_to_string validation_errors);
  let (catalog : Adapter.adapted_catalog) = Adapter.adapt_config cfg in
  check string "adapter errors" "" (adapter_errors_to_string catalog.errors);
  check bool "profiles generated" true (List.length catalog.profiles > 0);
  check bool "routes generated" true (List.length catalog.routes > 0)
;;

let set_env_opt key = function
  | Some value -> Unix.putenv key value
  | None -> Unix.putenv key ""
;;

let with_env key value f =
  let previous = Sys.getenv_opt key in
  Fun.protect
    ~finally:(fun () -> set_env_opt key previous)
    (fun () ->
       set_env_opt key value;
       f ())
;;

let reset_runtime_config_caches () =
  Config_dir_resolver.reset ();
  Masc_mcp.Cascade_catalog_runtime.reset_cache_for_tests ()
;;

let test_cascade_toml_runtime_validates_without_rejected_profiles () =
  let path = config_path "cascade.toml" in
  let config_dir = Filename.dirname path in
  with_env "MASC_TEST_ALLOW_CONFIG_PATH_OVERRIDE" (Some "1") @@ fun () ->
  with_env "MASC_CONFIG_DIR" (Some config_dir) @@ fun () ->
  Fun.protect
    ~finally:reset_runtime_config_caches
    (fun () ->
       reset_runtime_config_caches ();
       match Masc_mcp.Cascade_catalog_runtime.inspect_active () with
       | Ok (Masc_mcp.Cascade_catalog_runtime.Validated _) -> ()
       | Ok (Masc_mcp.Cascade_catalog_runtime.Validated_with_rejections { rejected_update; _ })
       | Ok (Masc_mcp.Cascade_catalog_runtime.Serving_last_known_good { rejected_update; _ })
         ->
         failf
           "checked-in cascade.toml should not produce rejected runtime profiles: %s"
           (Yojson.Safe.to_string
              (Masc_mcp.Cascade_catalog_runtime.rejection_to_yojson rejected_update))
       | Error rejection ->
         failf
           "checked-in cascade.toml should validate at runtime: %s"
           (Yojson.Safe.to_string
              (Masc_mcp.Cascade_catalog_runtime.rejection_to_yojson rejection)))
;;

let test_cascade_json_absent () =
  check bool "config/cascade.json absent" false (Sys.file_exists (config_path "cascade.json"))
;;

let find_tier_group cfg name =
  cfg.Types.tier_groups
  |> List.find_opt (fun (group : Types.cascade_tier_group) ->
    String.equal group.name name)
;;

let index_of value values =
  let rec loop index = function
    | [] -> None
    | candidate :: rest ->
      if String.equal candidate value then Some index else loop (index + 1) rest
  in
  loop 0 values
;;

let test_ollama_cloud_stable_is_system_only () =
  let cfg = load_checked_in_cascade_toml () in
  match find_tier_group cfg "ollama_cloud_stable" with
  | None -> fail "missing tier-group.ollama_cloud_stable"
  | Some group ->
    check
      (option bool)
      "ollama_cloud_stable keeper-assignable"
      (Some false)
      group.keeper_assignable
;;

let test_strict_tool_group_does_not_bypass_glm_before_ollama_cloud () =
  let cfg = load_checked_in_cascade_toml () in
  match find_tier_group cfg "strict_tool_candidates" with
  | None -> fail "missing tier-group.strict_tool_candidates"
  | Some group ->
    (match index_of "ollama_cloud_stable" group.tiers with
     | None -> ()
     | Some cloud_index ->
       (match index_of "glm-coding-with-spark" group.tiers with
        | Some glm_index when glm_index < cloud_index -> ()
        | Some _ ->
          fail
            "strict_tool_candidates must try glm-coding-with-spark before \
             ollama_cloud_stable"
        | None ->
          fail
            "strict_tool_candidates must not include ollama_cloud_stable without \
             glm-coding-with-spark ahead of it"))
;;

let check_qwen_thinking_control cfg model_id =
  match Types.model_capabilities_for_id cfg model_id with
  | Some c ->
    check bool (model_id ^ " reasoning budget") true c.supports_reasoning_budget;
    check
      string
      (model_id ^ " thinking control")
      "Cascade_declarative_types.Chat_template_kwargs"
      (Types.show_cascade_thinking_control_format c.thinking_control_format)
  | None -> failf "missing capabilities for %s" model_id
;;

let test_qwen_models_use_chat_template_kwargs () =
  let cfg = load_checked_in_cascade_toml () in
  check_qwen_thinking_control cfg "qwen3";
  check_qwen_thinking_control cfg "qwen3-5"
;;

let () =
  run
    "cascade config validity"
    [ ( "checked-in seed"
      , [ test_case "cascade.toml parses, validates, and adapts" `Quick test_cascade_toml_validates
        ; test_case
            "cascade.toml has no rejected runtime profiles"
            `Quick
            test_cascade_toml_runtime_validates_without_rejected_profiles
        ; test_case "cascade.json is not a checked-in source" `Quick test_cascade_json_absent
        ; test_case
            "ollama_cloud_stable is system-only"
            `Quick
            test_ollama_cloud_stable_is_system_only
        ; test_case
            "strict tool group does not bypass GLM before Ollama Cloud"
            `Quick
            test_strict_tool_group_does_not_bypass_glm_before_ollama_cloud
        ; test_case
            "qwen models use chat_template_kwargs thinking control"
            `Quick
            test_qwen_models_use_chat_template_kwargs
        ] )
    ]
;;
