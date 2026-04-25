(* test/test_oas_bridge_judge_callers_9629.ml

   #9629: Governance compute_judgments and Operator compute_judgments
   were calling [Masc_oas_bridge.run_safe] directly with a timeout
   resolved from the legacy [Env_config.Inference.{operator,
   dashboard_governance}_judge_timeout_seconds] readers.  Operator_judge
   in particular fell back to the 30s global inference timeout — far
   below the observed p50 of LLM-via-OAS-worker calls — and produced
   the "Execution timed out after 60.0s" warnings reported in the
   issue.  Governance_judge had a 300s default but lived outside the
   per-caller Prometheus counter.

   This test pins:

     1. Both judges resolve to [global_default_sec] (300s) by default,
        matching the other LLM-via-OAS-worker callers
        (Auto_responder / Dashboard_provider_runs).
     2. The legacy per-caller env vars
        ([MASC_OPERATOR_JUDGE_TIMEOUT_SEC],
        [MASC_DASHBOARD_GOVERNANCE_JUDGE_TIMEOUT_SEC]) are still
        honoured as a fallback so operator deployment configs that
        pin the pre-SSOT names continue to take effect.
     3. The new per-caller env var
        ([MASC_OAS_BRIDGE_TIMEOUT_GOVERNANCE_JUDGE_SEC] etc.) beats
        the legacy env var when both are set — operators migrating
        to the SSOT do not have to unset the legacy var first.
     4. The legacy override does not leak into other callers — only
        the registered judge consumes its alias. *)

let () =
  let dir =
    Filename.concat (Filename.get_temp_dir_name ())
      (Printf.sprintf "masc-test-judge-callers-9629-%06x"
         (Random.bits ()))
  in
  Unix.putenv "MASC_BASE_PATH" dir

module Cfg = Env_config_oas_bridge

let legacy_envs =
  [
    "MASC_OPERATOR_JUDGE_TIMEOUT_SEC";
    "MASC_DASHBOARD_GOVERNANCE_JUDGE_TIMEOUT_SEC";
  ]

let clear_all_envs () =
  Unix.putenv Cfg.global_env_var "";
  List.iter
    (fun caller -> Unix.putenv (Cfg.per_caller_env_var ~caller) "")
    (Cfg.known_callers ());
  List.iter (fun name -> Unix.putenv name "") legacy_envs

let test_judge_defaults_match_global () =
  clear_all_envs ();
  Alcotest.(check (float 0.0001))
    "Governance_judge defaults to global_default_sec"
    Cfg.global_default_sec
    (Cfg.timeout_sec ~caller:Cfg.Governance_judge ());
  Alcotest.(check (float 0.0001))
    "Operator_judge defaults to global_default_sec"
    Cfg.global_default_sec
    (Cfg.timeout_sec ~caller:Cfg.Operator_judge ())

let test_legacy_env_honoured_as_fallback () =
  clear_all_envs ();
  Unix.putenv "MASC_OPERATOR_JUDGE_TIMEOUT_SEC" "75.0";
  Unix.putenv "MASC_DASHBOARD_GOVERNANCE_JUDGE_TIMEOUT_SEC" "90.0";
  Alcotest.(check (float 0.0001))
    "Operator_judge honours legacy env"
    75.0
    (Cfg.timeout_sec ~caller:Cfg.Operator_judge ());
  Alcotest.(check (float 0.0001))
    "Governance_judge honours legacy env"
    90.0
    (Cfg.timeout_sec ~caller:Cfg.Governance_judge ());
  clear_all_envs ()

let test_new_env_beats_legacy_env () =
  clear_all_envs ();
  Unix.putenv "MASC_OPERATOR_JUDGE_TIMEOUT_SEC" "75.0";
  Unix.putenv
    (Cfg.per_caller_env_var ~caller:Cfg.Operator_judge)
    "55.0";
  Alcotest.(check (float 0.0001))
    "new per-caller env wins over legacy env"
    55.0
    (Cfg.timeout_sec ~caller:Cfg.Operator_judge ());
  clear_all_envs ()

let test_legacy_env_does_not_leak_to_other_callers () =
  clear_all_envs ();
  Unix.putenv "MASC_OPERATOR_JUDGE_TIMEOUT_SEC" "13.0";
  Alcotest.(check (float 0.0001))
    "Tool_deep_review unaffected by Operator_judge legacy env"
    180.0
    (Cfg.timeout_sec ~caller:Cfg.Tool_deep_review ());
  Alcotest.(check (float 0.0001))
    "Auto_responder unaffected by Operator_judge legacy env"
    Cfg.global_default_sec
    (Cfg.timeout_sec ~caller:Cfg.Auto_responder ());
  clear_all_envs ()

let test_judges_listed_in_known_callers () =
  let keys =
    List.map Cfg.caller_key (Cfg.known_callers ())
  in
  Alcotest.(check bool)
    "Governance_judge appears in known_callers"
    true
    (List.mem "governance_judge" keys);
  Alcotest.(check bool)
    "Operator_judge appears in known_callers"
    true
    (List.mem "operator_judge" keys)

let () =
  Alcotest.run "oas_bridge_judge_callers_9629"
    [
      ( "defaults",
        [
          Alcotest.test_case "judge defaults match global default"
            `Quick test_judge_defaults_match_global;
          Alcotest.test_case "judges listed in known_callers"
            `Quick test_judges_listed_in_known_callers;
        ] );
      ( "legacy_aliases",
        [
          Alcotest.test_case "legacy env honoured as fallback"
            `Quick test_legacy_env_honoured_as_fallback;
          Alcotest.test_case "new env beats legacy env"
            `Quick test_new_env_beats_legacy_env;
          Alcotest.test_case "legacy env does not leak"
            `Quick test_legacy_env_does_not_leak_to_other_callers;
        ] );
    ]
