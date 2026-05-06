(** test_stale_kill_class — Phase B PR-6 typed [stale_kill_class].

    The stale-watchdog kill reason used to collapse three distinct root
    causes (idle stall, active-turn hang, no-op failure loop) into a
    single [Stale_turn_timeout of float] variant.  Dashboards could not
    discriminate; operators had to grep the text log to figure out
    which class triggered.  This test pins the typed surface so a
    rename or signature change in [stale_kill_class] fails at the test
    boundary, not in production telemetry. *)

open Masc_mcp.Keeper_registry

module SW = Masc_mcp.Keeper_stale_watchdog

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

let test_failure_reason_to_string_stale_fleet_batch () =
  r "Stale_fleet_batch includes distinct count"
    "stale_fleet_batch(distinct_count=3)"
    (failure_reason_to_string (Stale_fleet_batch { distinct_count = 3 }))

let test_failure_reason_to_string_provider_runtime_error () =
  r "Provider_runtime_error includes terminal code"
    "provider_runtime_error(provider_error:kimi unicode crash)"
    (failure_reason_to_string
       (Provider_runtime_error
          { code = "provider_error"; detail = "kimi unicode crash" }))

let test_failure_reason_to_string_tool_required_unsatisfied () =
  r "Tool_required_unsatisfied includes terminal code"
    "tool_required_unsatisfied(required_tool_use_no_tool_call:no keeper tools)"
    (failure_reason_to_string
       (Tool_required_unsatisfied
          { code = "required_tool_use_no_tool_call";
            detail = "no keeper tools";
          }))

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

let test_stale_fleet_batch_cohort_key () =
  r "Stale_fleet_batch cohort_key" "stale_fleet_batch"
    (failure_reason_cohort_key
       (Some (Stale_fleet_batch { distinct_count = 3 })))

let test_terminal_failure_cohort_keys () =
  r "Provider_runtime_error cohort_key" "provider_runtime_error"
    (failure_reason_cohort_key
       (Some
          (Provider_runtime_error
             { code = "provider_error"; detail = "x" })));
  r "Tool_required_unsatisfied cohort_key" "tool_required_unsatisfied"
    (failure_reason_cohort_key
       (Some
          (Tool_required_unsatisfied
             { code = "required_tool_use_unsatisfied"; detail = "x" })))

let test_stale_watchdog_preserves_terminal_failure_reason () =
  let prior =
    Provider_runtime_error { code = "provider_error"; detail = "kimi" }
  in
  let kill_class = Idle_turn { stall_seconds = 305.0 } in
  match stale_watchdog_failure_reason ~prior:(Some prior) ~kill_class with
  | Some preserved ->
      r "preserves provider runtime error"
        (failure_reason_to_string prior)
        (failure_reason_to_string preserved)
  | None -> Alcotest.fail "expected preserved reason"

let test_stale_watchdog_uses_stale_reason_without_terminal_prior () =
  let kill_class = Idle_turn { stall_seconds = 305.0 } in
  match stale_watchdog_failure_reason ~prior:None ~kill_class with
  | Some reason ->
      r "uses stale reason when no prior terminal reason"
        "stale_turn_timeout(idle_turn(305s))"
        (failure_reason_to_string reason)
  | None -> Alcotest.fail "expected stale reason"

let root_cause_label reasons =
  reasons
  |> SW.classify_batch_root_cause_for_test
  |> SW.batch_root_cause_to_string

let test_batch_root_cause_labels () =
  r "cascade_unhealthy label" "cascade_unhealthy"
    (SW.batch_root_cause_to_string SW.Cascade_unhealthy);
  r "provider_auth label" "provider_auth"
    (SW.batch_root_cause_to_string SW.Provider_auth);
  r "fd_exhaustion label" "fd_exhaustion"
    (SW.batch_root_cause_to_string SW.Fd_exhaustion);
  r "mixed label" "mixed" (SW.batch_root_cause_to_string SW.Mixed);
  r "unknown label" "unknown" (SW.batch_root_cause_to_string SW.Unknown)

let test_batch_root_cause_provider_auth () =
  r "provider auth" "provider_auth"
    (root_cause_label
       [
         Provider_runtime_error
           { code = "auth_error"; detail = "bad key rejected" };
       ])

let test_batch_root_cause_fd_exhaustion () =
  r "fd exhaustion" "fd_exhaustion"
    (root_cause_label [ Exception "too many open files (os error 24)" ])

let test_batch_root_cause_cascade_unhealthy () =
  r "cascade unhealthy" "cascade_unhealthy"
    (root_cause_label [ Oas_timeout_budget_loop { count = 2 } ])

let test_batch_root_cause_mixed () =
  r "mixed" "mixed"
    (root_cause_label
       [
         Provider_runtime_error
           { code = "auth_error"; detail = "bad key rejected" };
         Exception "too many open files";
       ])

let test_batch_root_cause_unknown () =
  r "unknown" "unknown"
    (root_cause_label [ Heartbeat_consecutive_failures 3 ])

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
          Alcotest.test_case "Stale_fleet_batch wraps" `Quick
            test_failure_reason_to_string_stale_fleet_batch;
          Alcotest.test_case "Provider_runtime_error wraps" `Quick
            test_failure_reason_to_string_provider_runtime_error;
          Alcotest.test_case "Tool_required_unsatisfied wraps" `Quick
            test_failure_reason_to_string_tool_required_unsatisfied;
        ] );
      ( "failure_reason_cohort_key",
        [
          Alcotest.test_case "all sub-classes collapse to one cohort"
            `Quick test_cohort_key_collapses_subclasses;
          Alcotest.test_case "Oas_timeout_budget_loop cohort" `Quick
            test_oas_timeout_budget_loop_cohort_key;
          Alcotest.test_case "Stale_fleet_batch cohort" `Quick
            test_stale_fleet_batch_cohort_key;
          Alcotest.test_case "terminal failure cohorts" `Quick
            test_terminal_failure_cohort_keys;
        ] );
      ( "stale_watchdog_failure_reason",
        [
          Alcotest.test_case "preserves terminal failure" `Quick
            test_stale_watchdog_preserves_terminal_failure_reason;
          Alcotest.test_case "uses stale reason without terminal prior" `Quick
            test_stale_watchdog_uses_stale_reason_without_terminal_prior;
        ] );
      ( "batch_root_cause",
        [
          Alcotest.test_case "labels" `Quick test_batch_root_cause_labels;
          Alcotest.test_case "provider auth" `Quick
            test_batch_root_cause_provider_auth;
          Alcotest.test_case "fd exhaustion" `Quick
            test_batch_root_cause_fd_exhaustion;
          Alcotest.test_case "cascade unhealthy" `Quick
            test_batch_root_cause_cascade_unhealthy;
          Alcotest.test_case "mixed" `Quick test_batch_root_cause_mixed;
          Alcotest.test_case "unknown" `Quick
            test_batch_root_cause_unknown;
        ] );
    ]
