(* test/test_oas_bridge_timeout_ssot_10094.ml

   #10094: seven hardcoded [Masc_oas_bridge.run_safe ~timeout_s:N.N]
   literals lived in five different lib modules with three distinct
   values (60, 120, 180).  The 60s budgets in [auto_responder] and
   [dashboard_provider_runs] did not match observed p50 latency
   (50–700s) and produced 27 timeouts/session.

   [Env_config_oas_bridge] is the new SSOT.  This test pins:

     1. The known caller table preserves the deliberate 120s/180s
        budgets that were originally chosen for compute-heavy
        callers — a future refactor that drops them by accident
        regresses autoresearch / deep_review / anti_rationalization
        rather than just the fantasy 60s sites this PR fixed.
     2. The two fantasy 60s budgets are raised to the global
        default (300s) — the explicit symptom from the issue.
     3. Per-caller env-var override takes precedence over the
        hardcoded default (operator can tune any single caller).
     4. The global env-var override
        ([MASC_OAS_BRIDGE_TIMEOUT_DEFAULT_SEC]) shifts UNKNOWN
        callers (typo / future caller without a default) without
        affecting known callers — the global is a fallback, not
        an override.
     5. Per-caller env var beats global env var.
*)

(* MASC_BASE_PATH must be set BEFORE Masc_mcp module init —
   #9903 prod-guard fires under HOME otherwise.  Same dune
   [setenv] pattern as #10091 / #10097 / #10101. *)
let () =
  let dir =
    Filename.concat (Filename.get_temp_dir_name ())
      (Printf.sprintf "masc-test-oas-bridge-timeout-10094-%06x"
         (Random.bits ()))
  in
  Unix.putenv "MASC_BASE_PATH" dir

module Cfg = Env_config_oas_bridge

let clear_envs () =
  Unix.putenv Cfg.global_env_var "";
  List.iter
    (fun caller ->
       Unix.putenv (Cfg.per_caller_env_var ~caller) "")
    (Cfg.known_callers ());
  (* Clear an unknown-caller override too so the global-fallback
     test starts clean. *)
  Unix.putenv (Cfg.per_caller_env_var ~caller:"unknown_caller_test_10094") ""

(* The intentional 120s / 180s budgets must remain after this
   PR.  If a future refactor accidentally drops them (e.g. by
   collapsing every caller onto the global default), this test
   regresses the heavy-compute paths and reports the exact
   caller name. *)
let test_intentional_budgets_preserved () =
  clear_envs ();
  let cases =
    [
      "autoresearch_codegen", 120.0;
      "keeper_persona_authoring", 120.0;
      "server_openai_compat", 120.0;
      "tool_deep_review", 180.0;
      "anti_rationalization", 180.0;
    ]
  in
  List.iter
    (fun (caller, expected) ->
      let got = Cfg.timeout_sec ~caller () in
      Alcotest.(check (float 0.0001))
        (Printf.sprintf "preserved budget for %s" caller)
        expected got)
    cases

(* The two fantasy 60s budgets must be raised to the global
   default (300s).  This is the direct symptom from #10094. *)
let test_fantasy_60s_budgets_raised () =
  clear_envs ();
  Alcotest.(check (float 0.0001))
    "auto_responder raised to global default"
    Cfg.global_default_sec
    (Cfg.timeout_sec ~caller:"auto_responder" ());
  Alcotest.(check (float 0.0001))
    "dashboard_provider_runs raised to global default"
    Cfg.global_default_sec
    (Cfg.timeout_sec ~caller:"dashboard_provider_runs" ())

(* Per-caller env override beats the hardcoded default. *)
let test_per_caller_env_override () =
  clear_envs ();
  Unix.putenv
    (Cfg.per_caller_env_var ~caller:"auto_responder")
    "45.5";
  Alcotest.(check (float 0.0001))
    "auto_responder env overrides default"
    45.5
    (Cfg.timeout_sec ~caller:"auto_responder" ());
  (* Other callers must NOT be affected by this single override. *)
  Alcotest.(check (float 0.0001))
    "tool_deep_review unaffected"
    180.0
    (Cfg.timeout_sec ~caller:"tool_deep_review" ());
  clear_envs ()

(* Global env var (MASC_OAS_BRIDGE_TIMEOUT_DEFAULT_SEC) is a
   FALLBACK — it shifts the default for unknown callers but
   does NOT override per-caller hardcoded defaults.  Otherwise
   bumping the global env var to absorb one slow provider would
   silently change every other caller's budget. *)
let test_global_env_does_not_override_known_callers () =
  clear_envs ();
  Unix.putenv Cfg.global_env_var "999.0";
  Alcotest.(check (float 0.0001))
    "tool_deep_review keeps 180.0 (global env is a fallback, not an override)"
    180.0
    (Cfg.timeout_sec ~caller:"tool_deep_review" ());
  Alcotest.(check (float 0.0001))
    "unknown caller picks up global env"
    999.0
    (Cfg.timeout_sec ~caller:"unknown_caller_test_10094" ());
  clear_envs ()

(* Per-caller env var beats global env var.  Operator should
   always be able to fix one caller at a time without affecting
   others. *)
let test_per_caller_env_beats_global_env () =
  clear_envs ();
  Unix.putenv Cfg.global_env_var "999.0";
  Unix.putenv
    (Cfg.per_caller_env_var ~caller:"tool_deep_review")
    "42.0";
  Alcotest.(check (float 0.0001))
    "per-caller env wins over global env"
    42.0
    (Cfg.timeout_sec ~caller:"tool_deep_review" ());
  clear_envs ()

(* Per-caller env-var name follows the documented convention.
   Pin it so dashboards / runbooks that reference the literal
   name keep matching what the code reads. *)
let test_env_var_name_convention () =
  Alcotest.(check string)
    "auto_responder env var"
    "MASC_OAS_BRIDGE_TIMEOUT_AUTO_RESPONDER_SEC"
    (Cfg.per_caller_env_var ~caller:"auto_responder");
  Alcotest.(check string)
    "tool_deep_review env var"
    "MASC_OAS_BRIDGE_TIMEOUT_TOOL_DEEP_REVIEW_SEC"
    (Cfg.per_caller_env_var ~caller:"tool_deep_review");
  Alcotest.(check string)
    "global env var"
    "MASC_OAS_BRIDGE_TIMEOUT_DEFAULT_SEC"
    Cfg.global_env_var

let () =
  Alcotest.run "oas_bridge_timeout_ssot_10094"
    [
      ( "defaults",
        [
          Alcotest.test_case "intentional 120/180s budgets preserved"
            `Quick test_intentional_budgets_preserved;
          Alcotest.test_case "fantasy 60s budgets raised to global default"
            `Quick test_fantasy_60s_budgets_raised;
        ] );
      ( "env_overrides",
        [
          Alcotest.test_case "per-caller env wins over hardcoded default"
            `Quick test_per_caller_env_override;
          Alcotest.test_case "global env does not override known callers"
            `Quick test_global_env_does_not_override_known_callers;
          Alcotest.test_case "per-caller env wins over global env"
            `Quick test_per_caller_env_beats_global_env;
        ] );
      ( "naming_contract",
        [
          Alcotest.test_case "env var name convention" `Quick
            test_env_var_name_convention;
        ] );
    ]
