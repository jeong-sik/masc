open Alcotest

module K = Keeper_runtime_config
module T = Keeper_toml_loader

let empty_env _ = None

let test_resolve_overrides_maps_known_keys () =
  let doc =
    [ "turn.batch_limit", T.Toml_int 9
    ; "turn.temperature", T.Toml_float 0.25
    ; "turn.execution_idle_timeout_sec", T.Toml_int 95
    ]
  in
  let count, overrides = K.resolve_overrides ~env_lookup:empty_env doc in
  check int "count" 3 count;
  check (option string) "batch limit"
    (Some "9")
    (List.assoc_opt "MASC_KEEPER_BATCH_LIMIT" overrides);
  check (option string) "temperature"
    (Some "0.25")
    (List.assoc_opt "MASC_KEEPER_UNIFIED_TEMP" overrides);
  check (option string) "execution idle timeout"
    (Some "95")
    (List.assoc_opt "MASC_KEEPER_EXECUTION_IDLE_TIMEOUT_SEC" overrides)
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

let () =
  run
    "Keeper_runtime_config"
    [ ( "resolve_overrides"
      , [ test_case "known keys map to env names" `Quick
            test_resolve_overrides_maps_known_keys
        ; test_case "env vars preempt TOML" `Quick
            test_resolve_overrides_keeps_env_precedence
        ] )
    ]
;;
