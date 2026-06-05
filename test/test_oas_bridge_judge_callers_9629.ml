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
   checked-in default is now bounded separately while env overrides stay
   available.

   This test pins:

     1. Both judges resolve to [dashboard_judge_default_sec] by default,
        instead of inheriting the generic 300s worker budget.
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

(* The PR's stated invariant is "dashboard judges resolve to a
   bounded 45.0s default, not the 300s worker budget".  Pin the
   numeric value of [dashboard_judge_default_sec] explicitly.
   Without this anchor, a future widen back toward the worker
   budget would still pass the existing
   [judge resolves to dashboard_judge_default_sec] checks because
   both sides of the comparison would shift in lockstep. *)
let test_dashboard_judge_default_is_45s () =
  Alcotest.(check (float 0.0001))
    "dashboard_judge_default_sec is bounded at 45.0s; widening it \
     back toward the 300s worker budget reintroduces the operator-\
     surface stall this PR is meant to prevent — see #13113 follow-up"
    45.0
    Cfg.dashboard_judge_default_sec

let test_judge_defaults_are_bounded () =
  clear_all_envs ();
  Alcotest.(check (float 0.0001))
    "Governance_judge defaults to dashboard_judge_default_sec"
    Cfg.dashboard_judge_default_sec
    (Cfg.timeout_sec ~caller:Cfg.Governance_judge ());
  Alcotest.(check (float 0.0001))
    "Operator_judge defaults to dashboard_judge_default_sec"
    Cfg.dashboard_judge_default_sec
    (Cfg.timeout_sec ~caller:Cfg.Operator_judge ())

let test_removed_envs_are_ignored () =
  clear_all_envs ();
  Unix.putenv "MASC_OPERATOR_JUDGE_TIMEOUT_SEC" "75.0";
  Unix.putenv "MASC_DASHBOARD_GOVERNANCE_JUDGE_TIMEOUT_SEC" "90.0";
  Alcotest.(check (float 0.0001))
    "Operator_judge ignores removed env"
    Cfg.dashboard_judge_default_sec
    (Cfg.timeout_sec ~caller:Cfg.Operator_judge ());
  Alcotest.(check (float 0.0001))
    "Governance_judge ignores removed env"
    Cfg.dashboard_judge_default_sec
    (Cfg.timeout_sec ~caller:Cfg.Governance_judge ());
  clear_all_envs ()

let test_canonical_env_overrides_judge_default () =
  clear_all_envs ();
  Unix.putenv "MASC_OPERATOR_JUDGE_TIMEOUT_SEC" "75.0";
  Unix.putenv
    (Cfg.per_caller_env_var ~caller:Cfg.Operator_judge)
    "55.0";
  Alcotest.(check (float 0.0001))
    "canonical per-caller env wins"
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
          Alcotest.test_case "dashboard_judge_default_sec is 45s"
            `Quick test_dashboard_judge_default_is_45s;
          Alcotest.test_case "judge defaults are bounded"
            `Quick test_judge_defaults_are_bounded;
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
