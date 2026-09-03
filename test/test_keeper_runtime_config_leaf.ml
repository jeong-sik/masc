open Alcotest

module K = Keeper_runtime_config
module T = Keeper_toml_loader

let empty_env _ = None

let test_resolve_overrides_maps_known_keys () =
  let doc =
    [ "turn.batch_limit", T.Toml_int 9
    ; "turn.temperature", T.Toml_float 0.25
    ]
  in
  let count, overrides = K.resolve_overrides ~env_lookup:empty_env doc in
  check int "count" 2 count;
  check (option string) "batch limit"
    (Some "9")
    (List.assoc_opt "MASC_KEEPER_BATCH_LIMIT" overrides);
  check (option string) "temperature"
    (Some "0.25")
    (List.assoc_opt "MASC_KEEPER_UNIFIED_TEMP" overrides)
;;

let test_resolve_overrides_maps_otel_switch () =
  let doc = [ "otel.enabled", T.Toml_bool true ] in
  let _, overrides = K.resolve_overrides ~env_lookup:empty_env doc in
  check (option string) "otel.enabled reaches MASC_OTEL_ENABLED"
    (Some "true")
    (List.assoc_opt "MASC_OTEL_ENABLED" overrides)
;;

let test_resolve_overrides_keeps_env_precedence () =
  let env_lookup = function
    | "MASC_KEEPER_BATCH_LIMIT" -> Some "from-env"
    | _ -> None
  in
  let count, overrides =
    K.resolve_overrides
      ~env_lookup
      [ "turn.batch_limit", T.Toml_int 9; "turn.temperature", T.Toml_float 0.25 ]
  in
  check int "count" 1 count;
  check (option string) "env preempts toml"
    None
    (List.assoc_opt "MASC_KEEPER_BATCH_LIMIT" overrides);
  check (option string) "unset key applies"
    (Some "0.25")
    (List.assoc_opt "MASC_KEEPER_UNIFIED_TEMP" overrides)
;;

let test_vision_max_output_tokens_maps_from_toml () =
  let _, overrides =
    K.resolve_overrides
      ~env_lookup:empty_env
      [ "vision.max_output_tokens", T.Toml_int 40000 ]
  in
  check
    (option string)
    "vision.max_output_tokens maps to its env name"
    (Some "40000")
    (List.assoc_opt "MASC_KEEPER_VISION_MAX_OUTPUT_TOKENS" overrides)
;;

let test_registry_is_internally_consistent () =
  match Keeper_runtime_setting_registry.validate_registry () with
  | Ok () -> ()
  | Error errors -> fail (String.concat "; " errors)
;;

let test_toml_rows_prove_a_consumer () =
  Keeper_runtime_setting_registry.toml_settings
  |> List.iter (fun (row : Keeper_runtime_setting_registry.setting) ->
    check bool (row.env_name ^ " has consumer proof") true (row.consumers <> []))
;;

(* Feature contract: every credential that admits a web-search provider
   is named by the registry, environment-only (credentials never gain a
   TOML key in a committed file), and points at its consumer. *)
let test_web_search_credentials_are_registered_env_only () =
  [ "BRAVE_SEARCH_API_KEY"
  ; "TAVILY_API_KEY"
  ; "EXA_API_KEY"
  ; "BING_SEARCH_API_KEY"
  ; "AZURE_BING_SEARCH_API_KEY"
  ]
  |> List.iter (fun env_name ->
    match
      List.find_opt
        (fun (row : Keeper_runtime_setting_registry.setting) ->
          String.equal row.env_name env_name)
        Keeper_runtime_setting_registry.all
    with
    | None -> failf "%s is not registered" env_name
    | Some row ->
      (match row.exposure with
       | Keeper_runtime_setting_registry.Env_only -> ()
       | Keeper_runtime_setting_registry.Toml_and_env key ->
         failf "%s leaked a TOML key: %s" env_name key);
      check string (env_name ^ " category") "web_search" row.category;
      check bool
        (env_name ^ " names its consumer")
        true
        (List.mem "Tool_misc_web_search" row.consumers))
;;

let () =
  run
    "Keeper_runtime_config"
    [ ( "resolve_overrides"
      , [ test_case "known keys map to env names" `Quick
            test_resolve_overrides_maps_known_keys
        ; test_case "the otel switch maps from TOML" `Quick
            test_resolve_overrides_maps_otel_switch
        ; test_case "env vars preempt TOML" `Quick
            test_resolve_overrides_keeps_env_precedence
        ; test_case "vision output budget maps from TOML" `Quick
            test_vision_max_output_tokens_maps_from_toml
        ] )
    ; ( "setting_registry"
      , [ test_case "registry identities and consumers are valid" `Quick
            test_registry_is_internally_consistent
        ; test_case "TOML rows have consumer proof" `Quick
            test_toml_rows_prove_a_consumer
        ; test_case "web-search credentials are registered env-only" `Quick
            test_web_search_credentials_are_registered_env_only
        ] )
    ]
;;
