(** What [/health?full=1]'s [overall_status] is answerable for.

    Each case pins one edge of the derivation that replaced the eight
    hand-named sections (#34893). The rule is: a section is rolled up when it
    is cached and its [status] parses as a grade. *)

open Alcotest
module R = Server_health_rollup

let summary ?(sections = []) ?(runtime_startup_degradation = `Assoc [])
    ?(keeper_config_schema_status = "ok") ?(keeper_config_schema_blocking = false)
    ?(keeper_config_schema_terminal_reason = "")
    ?(keeper_config_operator_action_required = false)
    ?(lazy_task_boot_guard_fires_total = 0) () =
  R.operator_summary
    ~sections
    ~runtime_startup_degradation
    ~keeper_config_schema_status
    ~keeper_config_schema_blocking
    ~keeper_config_schema_terminal_reason
    ~keeper_config_operator_action_required
    ~lazy_task_boot_guard_fires_total

let section name status = (name, `Assoc [ "status", `String status ])

let test_cached_grade_moves_the_status () =
  let status, action, reasons =
    summary ~sections:[ section "keeper_event_queue" "degraded" ] ()
  in
  check string "a degraded cached section is the overall status" "degraded" status;
  (* Degraded ranks 2 and [requires_operator_action] is rank >= 3, so the
     status moves and no reason is raised. An operator watching the rollup for
     reasons alone would not see this one, which is what the status field is
     for. *)
  check bool "degraded alone raises no operator action" false action;
  check (list string) "degraded alone raises no reason" [] reasons

let test_error_grade_raises_a_reason () =
  let status, action, reasons =
    summary
      ~sections:
        [ ( "keeper_fleet_safety"
          , `Assoc [ "status", `String "error"; "blocker", `String "no owner" ] )
        ]
      ()
  in
  check string "an errored section is the overall status" "error" status;
  check bool "an errored section needs an operator" true action;
  check (list string) "the blocker is the reason, prefixed"
    [ "keeper_fleet_safety:no owner" ] reasons

let test_status_reasons_win_over_the_fallback () =
  let _, _, reasons =
    summary
      ~sections:
        [ ( "keeper_owner"
          , `Assoc
              [ "status", `String "error"
              ; "blocker", `String "ignored"
              ; "status_reasons", `List [ `String "first"; `String "second" ]
              ] )
        ]
      ()
  in
  check (list string) "every declared reason is carried, prefixed"
    [ "keeper_owner:first"; "keeper_owner:second" ] reasons

(* The cache boundary is the rollup's reach. [overall_status] is itself cached,
   so it is computed in the snapshot pass, and a section the probe pass
   supplies fresh is not there to be read. schedule_runner is one of those:
   this is why naming it in the rollup would not have worked (#34893). *)
let test_an_uncached_section_is_not_reached () =
  let status, action, reasons =
    summary ~sections:[ section "schedule_runner" "error" ] ()
  in
  check string "an uncached section does not move the status" "ok" status;
  check bool "an uncached section raises no action" false action;
  check (list string) "an uncached section raises no reason" [] reasons

(* [Health_status.of_string] folds an unrecognised word to [Unknown], which
   ranks alongside [Degraded]. Were the rollup to read a cached section
   reporting a state name, a listening socket would rank as a troubled
   subsystem. The parse is what keeps them apart. *)
let test_a_state_name_is_not_a_grade () =
  let status, _, reasons =
    summary ~sections:[ section "feature_flags" "active" ] ()
  in
  check string "a state name does not move the status" "ok" status;
  check (list string) "a state name raises no reason" [] reasons

(* The section the hand-named list left out. Cached, grade-bearing, and in the
   payload since it was added. *)
let test_observability_artifacts_are_rolled_up () =
  let status, _, _ =
    summary ~sections:[ section "keeper_observability_artifacts" "degraded" ] ()
  in
  check string "keeper_observability_artifacts reaches the rollup" "degraded" status

(* Most cached fields are not sections: keeper_fibers is an int, and
   keeper_config_errors a list. A field with no status says nothing about
   health and must not arrive as unknown. *)
let test_a_field_without_a_status_is_skipped () =
  let status, action, reasons =
    summary
      ~sections:[ ("keeper_fibers", `Int 3); ("keeper_config_errors", `List []) ]
      ()
  in
  check string "a field with no status does not move the status" "ok" status;
  check bool "a field with no status raises no action" false action;
  check (list string) "a field with no status raises no reason" [] reasons

(* Rolled up and not cached: the value the response carries comes from the
   probe pass, and this is the copy that is judged. *)
let test_startup_degradation_is_rolled_up_outside_the_cache () =
  let status, _, reasons =
    summary
      ~runtime_startup_degradation:
        (`Assoc
           [ "status", `String "error"
           ; "terminal_reason", `String "runtime absent"
           ])
      ()
  in
  check string "startup degradation is the overall status" "error" status;
  check (list string) "its terminal reason is carried"
    [ "runtime_startup_degradation:runtime absent" ] reasons

let test_the_worst_grade_wins () =
  let status, _, _ =
    summary
      ~sections:
        [ section "keeper_owner" "ok"
        ; section "keeper_event_queue" "degraded"
        ; section "keeper_reaction_ledger" "blocked"
        ]
      ()
  in
  check string "the worst cached grade is the overall status" "blocked" status

let test_lazy_task_boot_guard_degrades () =
  let status, action, reasons = summary ~lazy_task_boot_guard_fires_total:2 () in
  check string "a fired boot guard degrades" "degraded" status;
  check bool "a fired boot guard needs an operator" true action;
  check (list string) "the count is the reason"
    [ "lazy_task_boot_guard_fires_total:2" ] reasons

let () =
  run
    "server_health_rollup"
    [ ( "reach"
      , [ test_case "a cached grade moves the status" `Quick
            test_cached_grade_moves_the_status
        ; test_case "an uncached section is not reached" `Quick
            test_an_uncached_section_is_not_reached
        ; test_case "observability artifacts are rolled up" `Quick
            test_observability_artifacts_are_rolled_up
        ; test_case "startup degradation is rolled up outside the cache" `Quick
            test_startup_degradation_is_rolled_up_outside_the_cache
        ] )
    ; ( "grades"
      , [ test_case "a state name is not a grade" `Quick
            test_a_state_name_is_not_a_grade
        ; test_case "a field without a status is skipped" `Quick
            test_a_field_without_a_status_is_skipped
        ; test_case "the worst grade wins" `Quick test_the_worst_grade_wins
        ] )
    ; ( "reasons"
      , [ test_case "an error grade raises a reason" `Quick
            test_error_grade_raises_a_reason
        ; test_case "status_reasons win over the fallback" `Quick
            test_status_reasons_win_over_the_fallback
        ; test_case "a fired boot guard degrades" `Quick
            test_lazy_task_boot_guard_degrades
        ] )
    ]
;;
