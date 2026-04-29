(** test_stale_kill_class — Phase B PR-6 typed [stale_kill_class].

    The stale-watchdog kill reason used to collapse three distinct root
    causes (idle stall, active-turn hang, no-op failure loop) into a
    single [Stale_turn_timeout of float] variant.  Dashboards could not
    discriminate; operators had to grep the text log to figure out
    which class triggered.  This test pins the typed surface so a
    rename or signature change in [stale_kill_class] fails at the test
    boundary, not in production telemetry. *)

open Masc_mcp.Keeper_registry

let r = Alcotest.(check string)

let test_idle_turn_label () =
  r "idle_turn label" "idle_turn(305s)"
    (stale_kill_class_to_string (Idle_turn { stall_seconds = 305.0 }))

let test_in_turn_hung_label () =
  r "in_turn_hung label"
    "in_turn_hung(active=720s threshold=600s)"
    (stale_kill_class_to_string
       (In_turn_hung
          { active_seconds = 720.0; timeout_threshold = 600.0 }))

let test_noop_failure_loop_label () =
  r "noop_failure_loop label" "noop_failure_loop(noop=4)"
    (stale_kill_class_to_string
       (Noop_failure_loop { noop_count = 4 }))

let test_failure_reason_to_string_idle () =
  r "Stale_turn_timeout(Idle_turn) wraps with prefix"
    "stale_turn_timeout(idle_turn(305s))"
    (failure_reason_to_string
       (Stale_turn_timeout (Idle_turn { stall_seconds = 305.0 })))

let test_failure_reason_to_string_in_turn () =
  r "Stale_turn_timeout(In_turn_hung) wraps with prefix"
    "stale_turn_timeout(in_turn_hung(active=720s threshold=600s))"
    (failure_reason_to_string
       (Stale_turn_timeout
          (In_turn_hung
             { active_seconds = 720.0; timeout_threshold = 600.0 })))

let test_failure_reason_to_string_noop () =
  r "Stale_turn_timeout(Noop_failure_loop) wraps with prefix"
    "stale_turn_timeout(noop_failure_loop(noop=4))"
    (failure_reason_to_string
       (Stale_turn_timeout
          (Noop_failure_loop { noop_count = 4 })))

let test_failure_reason_to_string_oas_timeout_budget_loop () =
  r "Oas_timeout_budget_loop includes count"
    "oas_timeout_budget_loop(count=3)"
    (failure_reason_to_string (Oas_timeout_budget_loop { count = 3 }))

let test_cohort_key_collapses_subclasses () =
  (* The cohort key intentionally ignores the sub-class — every stale
     kill is one cohort for dashboard rate computation.  Operators
     drill down via [failure_reason_to_string] when they need the
     class. *)
  r "Idle_turn cohort_key" "stale_turn_timeout"
    (failure_reason_cohort_key
       (Some (Stale_turn_timeout (Idle_turn { stall_seconds = 1.0 }))));
  r "In_turn_hung cohort_key" "stale_turn_timeout"
    (failure_reason_cohort_key
       (Some
          (Stale_turn_timeout
             (In_turn_hung
                { active_seconds = 1.0; timeout_threshold = 1.0 }))));
  r "Noop_failure_loop cohort_key" "stale_turn_timeout"
    (failure_reason_cohort_key
       (Some (Stale_turn_timeout (Noop_failure_loop { noop_count = 1 }))))

let test_oas_timeout_budget_loop_cohort_key () =
  r "Oas_timeout_budget_loop cohort_key" "oas_timeout_budget_loop"
    (failure_reason_cohort_key
       (Some (Oas_timeout_budget_loop { count = 3 })))

let () =
  Alcotest.run "stale_kill_class"
    [
      ( "stale_kill_class_to_string",
        [
          Alcotest.test_case "Idle_turn label" `Quick test_idle_turn_label;
          Alcotest.test_case "In_turn_hung label" `Quick
            test_in_turn_hung_label;
          Alcotest.test_case "Noop_failure_loop label" `Quick
            test_noop_failure_loop_label;
        ] );
      ( "failure_reason_to_string",
        [
          Alcotest.test_case "Stale_turn_timeout(Idle_turn) wraps" `Quick
            test_failure_reason_to_string_idle;
          Alcotest.test_case "Stale_turn_timeout(In_turn_hung) wraps" `Quick
            test_failure_reason_to_string_in_turn;
          Alcotest.test_case "Stale_turn_timeout(Noop_failure_loop) wraps"
            `Quick test_failure_reason_to_string_noop;
          Alcotest.test_case "Oas_timeout_budget_loop wraps" `Quick
            test_failure_reason_to_string_oas_timeout_budget_loop;
        ] );
      ( "failure_reason_cohort_key",
        [
          Alcotest.test_case "all sub-classes collapse to one cohort"
            `Quick test_cohort_key_collapses_subclasses;
          Alcotest.test_case "Oas_timeout_budget_loop cohort" `Quick
            test_oas_timeout_budget_loop_cohort_key;
        ] );
    ]
