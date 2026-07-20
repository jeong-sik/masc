open Alcotest

module K = Keeper_runtime_config
module T = Keeper_toml_loader

let empty_env _ = None

let resolve_or_fail ~env_lookup doc =
  match K.resolve_overrides ~env_lookup doc with
  | Ok resolved -> resolved
  | Error msg -> failf "Keeper runtime config resolution failed: %s" msg

let test_resolve_overrides_maps_known_keys () =
  let doc =
    [ "turn.enable_thinking", T.Toml_bool true
    ; "turn.temperature", T.Toml_float 0.25
    ]
  in
  let count, overrides = resolve_or_fail ~env_lookup:empty_env doc in
  check int "count" 2 count;
  check (option string) "thinking"
    (Some "true")
    (List.assoc_opt "MASC_KEEPER_ENABLE_THINKING" overrides);
  check (option string) "temperature"
    (Some "0.25")
    (List.assoc_opt "MASC_KEEPER_UNIFIED_TEMP" overrides)
;;

let test_resolve_overrides_keeps_env_precedence () =
  let env_lookup = function
    | "MASC_KEEPER_UNIFIED_TEMP" -> Some "from-env"
    | _ -> None
  in
  let count, overrides =
    resolve_or_fail
      ~env_lookup
      [ "turn.enable_thinking", T.Toml_bool true
      ; "turn.temperature", T.Toml_float 0.25
      ]
  in
  check int "count" 1 count;
  check (option string) "env preempts toml"
    None
    (List.assoc_opt "MASC_KEEPER_UNIFIED_TEMP" overrides);
  check (option string) "unset key applies"
    (Some "true")
    (List.assoc_opt "MASC_KEEPER_ENABLE_THINKING" overrides)
;;

let test_unknown_owned_key_is_rejected () =
  let doc = [ "turn.retry_limit", T.Toml_int 3 ] in
  match K.resolve_overrides ~env_lookup:empty_env doc with
  | Ok _ -> fail "unknown Keeper-owned key must not be ignored"
  | Error msg ->
    check string "explicit unknown key"
      "unknown Keeper runtime TOML keys: turn.retry_limit"
      msg
;;

let test_invalid_value_is_rejected_before_env_precedence () =
  let env_lookup = function
    | "MASC_KEEPER_UNIFIED_TEMP" -> Some "from-env"
    | _ -> None
  in
  let doc = [ "turn.temperature", T.Toml_string_array [ "0.25" ] ] in
  match K.resolve_overrides ~env_lookup doc with
  | Ok _ -> fail "environment precedence must not hide invalid TOML"
  | Error msg ->
    check string "explicit unsupported value"
      "turn.temperature: string arrays are not supported"
      msg
;;

let test_foreign_table_is_left_to_its_owner () =
  let doc = [ "providers.example.base_url", T.Toml_string "https://example.test" ] in
  let count, overrides = resolve_or_fail ~env_lookup:empty_env doc in
  check int "no Keeper values" 0 count;
  check int "no Keeper overrides" 0 (List.length overrides)
;;

let () =
  run
    "Keeper_runtime_config"
    [ ( "resolve_overrides"
      , [ test_case "known keys map to env names" `Quick
            test_resolve_overrides_maps_known_keys
        ; test_case "env vars preempt TOML" `Quick
            test_resolve_overrides_keeps_env_precedence
        ; test_case "unknown Keeper key is rejected" `Quick
            test_unknown_owned_key_is_rejected
        ; test_case "invalid value survives env precedence" `Quick
            test_invalid_value_is_rejected_before_env_precedence
        ; test_case "foreign table remains foreign" `Quick
            test_foreign_table_is_left_to_its_owner
        ] )
    ]
;;
