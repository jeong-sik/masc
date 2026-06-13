(* test/test_oas_bridge_judge_callers_9629.ml

   #9629: Governance compute_judgments and Operator compute_judgments
   were calling [Masc_oas_bridge.run_safe] directly with a timeout
   resolved from the legacy [Env_config.Inference.{operator,
   dashboard_governance}_judge_timeout_seconds] readers.  Operator_judge
   in particular fell back to the 30s global inference timeout — far
   below the observed p50 of LLM-via-OAS-worker calls — and produced
   the "Execution timed out after 60.0s" warnings reported in the
   issue.  Governance_judge had a 300s default but lived outside the
   per-caller Otel_metric_store counter.

   #13113 follow-up: live /Users/dancer/me evidence showed the opposite
   failure mode once both judges shared the 300s worker default: a dashboard
   governance judge can pin a CLI-backed child for minutes and make operator
   surfaces / health checks stale.  Dashboard judges are advisory, so their
   checked-in default is bounded separately while env overrides stay
   available.

   2026-06-08 follow-up (#20082): fleet-wide idle root cause was the
   45s per-judge wrapper firing before the OAS provider's first
   response (boot race + lane saturation).  Both dashboard judge
   callers now resolve to [Float.infinity] via
   [governance_judge_no_timeout] — the bridge applies no wrapper
   timeout to advisory dashboard judge cycles; real protection lives
   at the OAS provider boundary.  Per-caller env overrides
   ([MASC_OAS_BRIDGE_TIMEOUT_GOVERNANCE_JUDGE_SEC] etc.) still win
   for operators who want a finite budget.

   This test pins:

     1. Both judges resolve to [governance_judge_no_timeout] (i.e.
        [Float.infinity]) by default, so the bridge never wraps an
        advisory dashboard judge cycle in a timer.
     2. Removed pre-SSOT env vars
        ([MASC_OPERATOR_JUDGE_TIMEOUT_SEC],
        [MASC_DASHBOARD_GOVERNANCE_JUDGE_TIMEOUT_SEC]) are ignored.
     3. The canonical per-caller env var
        ([MASC_OAS_BRIDGE_TIMEOUT_GOVERNANCE_JUDGE_SEC] etc.) is the
        only per-judge override surface. *)

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

(* [dashboard_judge_default_sec] is the LEGACY pin (45.0s) that #9629
   originally bounded both judges to.  It is no longer the active
   default for either judge — both resolve to
   [governance_judge_no_timeout] = [Float.infinity] (2026-06-08
   #20082: 45s wrapper was firing before the OAS provider's first
   response, propagating fleet-wide idle).  The value is retained
   only so historical test fixtures that asserted on 45.0 keep a
   stable reference.  The active no-timeout pin lives in
   [Cfg.governance_judge_no_timeout]. *)
let test_dashboard_judge_default_is_45s () =
  Alcotest.(check (float 0.0001))
    "dashboard_judge_default_sec is the legacy 45.0s pin; \
     governance_judge_no_timeout is the active no-timeout value"
    45.0
    Cfg.dashboard_judge_default_sec

let test_judge_defaults_have_no_timeout () =
  clear_all_envs ();
  Alcotest.(check bool)
    "Governance_judge defaults to Float.infinity (governance_judge_no_timeout)"
    true
    (Float.is_infinite (Cfg.timeout_sec ~caller:Cfg.Governance_judge ()));
  Alcotest.(check bool)
    "Operator_judge defaults to Float.infinity (governance_judge_no_timeout)"
    true
    (Float.is_infinite (Cfg.timeout_sec ~caller:Cfg.Operator_judge ()));
  Alcotest.(check (float 0.0001))
    "Governance_judge default equals governance_judge_no_timeout pin"
    Cfg.governance_judge_no_timeout
    (Cfg.timeout_sec ~caller:Cfg.Governance_judge ());
  Alcotest.(check (float 0.0001))
    "Operator_judge default equals governance_judge_no_timeout pin"
    Cfg.governance_judge_no_timeout
    (Cfg.timeout_sec ~caller:Cfg.Operator_judge ())

let test_removed_envs_are_ignored () =
  clear_all_envs ();
  Unix.putenv "MASC_OPERATOR_JUDGE_TIMEOUT_SEC" "75.0";
  Unix.putenv "MASC_DASHBOARD_GOVERNANCE_JUDGE_TIMEOUT_SEC" "90.0";
  Alcotest.(check bool)
    "Operator_judge ignores removed env (still infinite)"
    true
    (Float.is_infinite (Cfg.timeout_sec ~caller:Cfg.Operator_judge ()));
  Alcotest.(check bool)
    "Governance_judge ignores removed env (still infinite)"
    true
    (Float.is_infinite (Cfg.timeout_sec ~caller:Cfg.Governance_judge ()));
  clear_all_envs ()

let test_canonical_env_overrides_judge_default () =
  clear_all_envs ();
  Unix.putenv "MASC_OPERATOR_JUDGE_TIMEOUT_SEC" "75.0";
  Unix.putenv
    (Cfg.per_caller_env_var ~caller:Cfg.Operator_judge)
    "55.0";
  Alcotest.(check (float 0.0001))
    "canonical per-caller env wins (finite budget overrides infinite default)"
    55.0
    (Cfg.timeout_sec ~caller:Cfg.Operator_judge ());
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
          Alcotest.test_case "dashboard_judge_default_sec is the legacy 45.0s pin"
            `Quick test_dashboard_judge_default_is_45s;
          Alcotest.test_case "judge defaults have no wrapper timeout"
            `Quick test_judge_defaults_have_no_timeout;
          Alcotest.test_case "judges listed in known_callers"
            `Quick test_judges_listed_in_known_callers;
        ] );
      ( "removed_envs",
        [
          Alcotest.test_case "removed envs are ignored"
            `Quick test_removed_envs_are_ignored;
          Alcotest.test_case "canonical env overrides judge default"
            `Quick test_canonical_env_overrides_judge_default;
        ] );
    ]
