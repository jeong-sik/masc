(* test/test_oas_bridge_judge_callers_9629.ml

   #9629: Operator compute_judgments calls [Masc_oas_bridge.run_safe]
   with a typed per-caller timeout instead of the global inference timeout.

   #13113 follow-up: live /Users/dancer/me evidence showed the opposite
   failure mode when an advisory dashboard judge inherited the 300s worker
   default: a CLI-backed child could pin operator surfaces and health checks.

   2026-07-01 follow-up: the no-wrapper default is retired. Dashboard
   judges are still advisory, but they must use a finite bridge budget so
   stale dashboard work cannot pin OAS bridge execution indefinitely.

   This test pins:

     1. Operator judge resolves to [dashboard_judge_default_sec] by default.
     2. The canonical per-caller env var
        is the only per-judge override surface. *)

let () =
  let dir =
    Filename.concat (Filename.get_temp_dir_name ())
      (Printf.sprintf "masc-test-judge-callers-9629-%06x"
         (Random.bits ()))
  in
  Unix.putenv "MASC_BASE_PATH" dir

module Cfg = Env_config_oas_bridge

let clear_all_envs () =
  Unix.putenv Cfg.global_env_var "";
  List.iter
    (fun caller -> Unix.putenv (Cfg.per_caller_env_var ~caller) "")
    (Cfg.known_callers ())

let check_timeout_equal label expected actual =
  if Float.is_infinite expected then
    Alcotest.(check bool)
      label
      true
      (Float.is_infinite actual && Float.compare expected actual = 0)
  else Alcotest.(check (float 0.0001)) label expected actual

let test_dashboard_judge_default_is_finite () =
  Alcotest.(check bool)
    "dashboard_judge_default_sec is finite"
    true
    (not (Float.is_infinite Cfg.dashboard_judge_default_sec)
     && Cfg.dashboard_judge_default_sec > 0.0);
  Alcotest.(check (float 0.0001))
    "dashboard_judge_default_sec"
    180.0
    Cfg.dashboard_judge_default_sec

let test_judge_defaults_preserve_bounded_timeout () =
  clear_all_envs ();
  check_timeout_equal
    "Operator_judge default equals dashboard_judge_default_sec"
    Cfg.dashboard_judge_default_sec
    (Cfg.timeout_sec ~caller:Cfg.Operator_judge ())

let test_canonical_env_overrides_judge_default () =
  clear_all_envs ();
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
    "Operator_judge appears in known_callers"
    true
    (List.mem "operator_judge" keys)

let () =
  Alcotest.run "oas_bridge_judge_callers_9629"
    [
      ( "defaults",
        [
          Alcotest.test_case "dashboard_judge_default_sec is finite"
            `Quick test_dashboard_judge_default_is_finite;
          Alcotest.test_case "judge defaults preserve bounded timeout"
            `Quick test_judge_defaults_preserve_bounded_timeout;
          Alcotest.test_case "judges listed in known_callers"
            `Quick test_judges_listed_in_known_callers;
        ] );
      ( "canonical_env",
        [
          Alcotest.test_case "canonical env overrides judge default"
            `Quick test_canonical_env_overrides_judge_default;
        ] );
    ]
