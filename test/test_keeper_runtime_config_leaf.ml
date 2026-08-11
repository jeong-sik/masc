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

let retired_toml_keys =
  [ "autonomous.fairness_cooldown_sec"
  ; "heartbeat.board_wakeup_max"
  ; "turn.cli_subprocess_idle_sec"
  ; "turn.capacity_limit"
  ; "turn.max_output_tokens"
  ]
;;

let test_registry_is_internally_consistent () =
  match Keeper_runtime_setting_registry.validate_registry () with
  | Ok () -> ()
  | Error errors -> fail (String.concat "; " errors)
;;

let test_retired_keys_have_no_active_mapping () =
  List.iter
    (fun key ->
       check
         (option string)
         (key ^ " has no active mapping")
         None
         (List.assoc_opt
            key
            Keeper_runtime_setting_registry.active_toml_mappings);
       match Keeper_runtime_setting_registry.find_by_toml_key key with
       | Some { lifecycle = Keeper_runtime_setting_registry.Retired _; _ } -> ()
       | Some _ -> failf "%s is unexpectedly active" key
       | None -> failf "%s lost its retired-key diagnostic" key)
    retired_toml_keys
;;

let test_active_toml_rows_prove_a_consumer () =
  Keeper_runtime_setting_registry.active_toml
  |> List.iter (fun (row : Keeper_runtime_setting_registry.setting) ->
    check bool (row.env_name ^ " has consumer proof") true (row.consumers <> []))
;;

let () =
  run
    "Keeper_runtime_config"
    [ ( "resolve_overrides"
      , [ test_case "known keys map to env names" `Quick
            test_resolve_overrides_maps_known_keys
        ; test_case "env vars preempt TOML" `Quick
            test_resolve_overrides_keeps_env_precedence
        ] )
    ; ( "setting_registry"
      , [ test_case "registry identities and consumers are valid" `Quick
            test_registry_is_internally_consistent
        ; test_case "retired no-op keys are not active mappings" `Quick
            test_retired_keys_have_no_active_mapping
        ; test_case "active TOML rows have consumer proof" `Quick
            test_active_toml_rows_prove_a_consumer
        ] )
    ]
;;
