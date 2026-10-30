open Alcotest

module K = Keeper_runtime_config
module T = Keeper_toml_loader

let empty_env _ = None

let test_boot_float_strings_round_trip_without_changing_simple_spellings () =
  let values =
    [ 0.65; 0.1234567; 123456789.0; 1.0000000000000002
    ; Float.next_after 0.0 infinity; Float.max_float; -0.0 ]
  in
  List.iter (fun value ->
    let _, overrides = K.resolve_overrides ~env_lookup:empty_env
        [ "web_search.cache_ttl_sec", T.Toml_float value ] in
    match List.assoc_opt "MASC_WEB_SEARCH_CACHE_TTL_SEC" overrides with
    | None -> fail "float boot override missing"
    | Some rendered ->
      (match float_of_string_opt rendered with
       | Some parsed ->
         check bool (Printf.sprintf "%S retains the exact float" rendered) true
           (Int64.bits_of_float parsed = Int64.bits_of_float value)
       | None -> failf "boot override is not a float: %S" rendered)) values;
  List.iter (fun value ->
    let _, overrides = K.resolve_overrides ~env_lookup:empty_env
        [ "turn.temperature", T.Toml_float value ] in
    check (option string) "an already exact short spelling stays byte-identical"
      (Some (Printf.sprintf "%g" value))
      (List.assoc_opt "MASC_KEEPER_UNIFIED_TEMP" overrides))
    [ 0.0; -0.0; 0.5; 0.65; 1.23; 120.5; 1e9; 1e-7 ]
;;

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

let test_memory_count_settings () =
  let doc =
    [ "memory.category_cap", T.Toml_int 2
    ; "memory.facts_per_category_cap", T.Toml_int 7 ]
  in
  let count, overrides = K.resolve_overrides ~env_lookup:empty_env doc in
  check int "both count settings reach the boot overlay" 2 count;
  check (option string) "category cap" (Some "2")
    (List.assoc_opt Env_config_keeper.KeeperMemoryOs.category_cap_env_key overrides);
  check (option string) "items per category" (Some "7")
    (List.assoc_opt Env_config_keeper.KeeperMemoryOs.facts_per_category_cap_env_key overrides)
;;

let test_resolve_overrides_keeps_env_precedence () =
  let env_lookup = function
    | "MASC_KEEPER_HEARTBEAT_INTERVAL_SEC" | "MASC_KEEPER_BATCH_LIMIT" -> Some "from-env"
    | _ -> None
  in
  let count, overrides =
    K.resolve_overrides
      ~env_lookup
      [ "heartbeat.interval_sec", T.Toml_int 9
      ; "turn.batch_limit", T.Toml_int 9
      ; "turn.temperature", T.Toml_float 0.25
      ]
  in
  check int "count" 2 count;
  check (option string) "env preempts a row that still reads the environment"
    None
    (List.assoc_opt "MASC_KEEPER_HEARTBEAT_INTERVAL_SEC" overrides);
  check (option string) "env does not preempt a row the file alone feeds"
    (Some "9")
    (List.assoc_opt "MASC_KEEPER_BATCH_LIMIT" overrides);
  check (option string) "unset key applies"
    (Some "0.25")
    (List.assoc_opt "MASC_KEEPER_UNIFIED_TEMP" overrides)
;;

let test_h2_listener_capacity_maps_from_toml () =
  let count, overrides = K.resolve_overrides ~env_lookup:empty_env
    ["transport.h2_max_concurrent_streams", T.Toml_int 100;
     "transport.h2_max_pending_response_bytes", T.Toml_int 67108864] in
  check int "both capacities reach the boot overlay" 2 count;
  check (option string) "peer stream capacity" (Some "100")
    (List.assoc_opt "MASC_H2_MAX_CONCURRENT_STREAMS" overrides);
  check (option string) "listener payload capacity" (Some "67108864")
    (List.assoc_opt "MASC_H2_MAX_PENDING_RESPONSE_BYTES" overrides)
;;

let test_h2_listener_capacity_rejects_invalid_values () =
  let name = "MASC_H2_MAX_CONCURRENT_STREAMS" in
  Fun.protect ~finally:Config_boot_overrides.reset_for_tests (fun () ->
    List.iter (fun value ->
      Config_boot_overrides.reset_for_tests ();
      Config_boot_overrides.declare_file_owned [name];
      Config_boot_overrides.set name value;
      match H2_response_limits.max_concurrent_streams () with
      | _ -> failf "invalid transport capacity accepted: %S" value
      | exception Env_config_core.Config_error _ -> ())
      [""; "0"; "-1"; "not-an-integer"; "2147483648"])
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
  ; "ZAI_API_KEY"
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
       | Keeper_runtime_setting_registry.Toml_and_env key
       | Keeper_runtime_setting_registry.Toml_only key ->
         failf "%s leaked a TOML key: %s" env_name key);
      check string
        (env_name ^ " category")
        "web_search"
        (Keeper_runtime_setting_registry.category_label row.category);
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
        ; test_case "boot floats retain their exact value" `Quick
            test_boot_float_strings_round_trip_without_changing_simple_spellings
        ; test_case "the otel switch maps from TOML" `Quick
            test_resolve_overrides_maps_otel_switch
        ; test_case "memory category and item settings map from TOML" `Quick
            test_memory_count_settings
        ; test_case "env vars preempt TOML" `Quick
            test_resolve_overrides_keeps_env_precedence
        ; test_case "vision output budget maps from TOML" `Quick
            test_vision_max_output_tokens_maps_from_toml
        ; test_case "H2 listener capacities map from TOML" `Quick
            test_h2_listener_capacity_maps_from_toml
        ; test_case "invalid H2 capacity fails startup" `Quick
            test_h2_listener_capacity_rejects_invalid_values
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
