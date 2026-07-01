(* test/test_oas_bridge_timeout_ssot_10094.ml

   [Env_config_oas_bridge] is the SSOT for the remaining trusted OAS bridge
   callers. Removed runtime-invocation surfaces must not stay pinned here as
   hidden configuration. *)

let () =
  let dir =
    Filename.concat (Filename.get_temp_dir_name ())
      (Printf.sprintf
         "masc-test-oas-bridge-timeout-10094-%06x"
         (Random.bits ()))
  in
  Unix.putenv "MASC_BASE_PATH" dir

module Cfg = Env_config_oas_bridge

let clear_envs () =
  Unix.putenv Cfg.global_env_var "";
  List.iter
    (fun caller -> Unix.putenv (Cfg.per_caller_env_var ~caller) "")
    (Cfg.known_callers ());
  Unix.putenv
    (Cfg.per_caller_env_var ~caller:(Cfg.Unknown "unknown_caller_test_10094"))
    ""
;;

let check_timeout_equal label expected actual =
  if Float.is_infinite expected then
    Alcotest.(check bool)
      label
      true
      (Float.is_infinite actual && Float.compare expected actual = 0)
  else Alcotest.(check (float 0.0001)) label expected actual
;;

let test_remaining_defaults () =
  clear_envs ();
  let cases =
    [ Cfg.Anti_rationalization, 180.0
    ; Cfg.Governance_judge, Cfg.dashboard_judge_default_sec
    ; Cfg.Operator_judge, Cfg.dashboard_judge_default_sec
    ]
  in
  List.iter
    (fun (caller, expected) ->
       check_timeout_equal
         (Printf.sprintf "default for %s" (Cfg.caller_key caller))
         expected
         (Cfg.timeout_sec ~caller ()))
    cases
;;

let test_per_caller_env_override () =
  clear_envs ();
  Unix.putenv
    (Cfg.per_caller_env_var ~caller:Cfg.Anti_rationalization)
    "45.5";
  Alcotest.(check (float 0.0001))
    "anti_rationalization env overrides default"
    45.5
    (Cfg.timeout_sec ~caller:Cfg.Anti_rationalization ());
  check_timeout_equal
    "governance_judge unaffected by anti_rationalization env"
    Cfg.dashboard_judge_default_sec
    (Cfg.timeout_sec ~caller:Cfg.Governance_judge ());
  clear_envs ()
;;

let test_infinite_env_falls_back () =
  clear_envs ();
  Unix.putenv
    (Cfg.per_caller_env_var ~caller:Cfg.Anti_rationalization)
    "infinity";
  Alcotest.(check (float 0.0001))
    "infinite per-caller env falls back"
    Cfg.global_default_sec
    (Cfg.timeout_sec ~caller:Cfg.Anti_rationalization ());
  Unix.putenv Cfg.global_env_var "infinity";
  Alcotest.(check (float 0.0001))
    "infinite global env falls back"
    Cfg.global_default_sec
    (Cfg.timeout_sec ~caller:(Cfg.Unknown "unknown_caller_test_10094") ());
  clear_envs ()
;;

let test_global_env_does_not_override_known_callers () =
  clear_envs ();
  Unix.putenv Cfg.global_env_var "999.0";
  Alcotest.(check (float 0.0001))
    "anti_rationalization keeps default"
    180.0
    (Cfg.timeout_sec ~caller:Cfg.Anti_rationalization ());
  Alcotest.(check (float 0.0001))
    "unknown caller picks up global env"
    999.0
    (Cfg.timeout_sec ~caller:(Cfg.Unknown "unknown_caller_test_10094") ());
  clear_envs ()
;;

let test_per_caller_env_beats_global_env () =
  clear_envs ();
  Unix.putenv Cfg.global_env_var "999.0";
  Unix.putenv
    (Cfg.per_caller_env_var ~caller:Cfg.Anti_rationalization)
    "42.0";
  Alcotest.(check (float 0.0001))
    "per-caller env wins over global env"
    42.0
    (Cfg.timeout_sec ~caller:Cfg.Anti_rationalization ());
  clear_envs ()
;;

let test_env_var_name_convention () =
  Alcotest.(check string)
    "anti_rationalization env var"
    "MASC_OAS_BRIDGE_TIMEOUT_ANTI_RATIONALIZATION_SEC"
    (Cfg.per_caller_env_var ~caller:Cfg.Anti_rationalization);
  Alcotest.(check string)
    "governance_judge env var"
    "MASC_OAS_BRIDGE_TIMEOUT_GOVERNANCE_JUDGE_SEC"
    (Cfg.per_caller_env_var ~caller:Cfg.Governance_judge);
  Alcotest.(check string)
    "global env var"
    "MASC_OAS_BRIDGE_TIMEOUT_DEFAULT_SEC"
    Cfg.global_env_var
;;

let () =
  Alcotest.run
    "oas_bridge_timeout_ssot_10094"
    [ ( "defaults"
      , [ Alcotest.test_case "remaining defaults" `Quick test_remaining_defaults ]
      )
    ; ( "env_overrides"
      , [ Alcotest.test_case
            "per-caller env wins over hardcoded default"
            `Quick
            test_per_caller_env_override
        ; Alcotest.test_case
            "global env does not override known callers"
            `Quick
            test_global_env_does_not_override_known_callers
        ; Alcotest.test_case
            "per-caller env wins over global env"
            `Quick
            test_per_caller_env_beats_global_env
        ; Alcotest.test_case
            "infinite env falls back"
            `Quick
            test_infinite_env_falls_back
        ] )
    ; ( "naming_contract"
      , [ Alcotest.test_case
            "env var name convention"
            `Quick
            test_env_var_name_convention
        ] )
    ]
;;
