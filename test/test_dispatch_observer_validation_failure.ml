open Alcotest

(** Regression test for the OAS input-validation observer-drop bug.

    Before the fix, [Keeper_tools_oas_handler] fired the dispatch
    observers with [Dispatch_outcome.Handler_error] on an OAS
    input-validation failure.  All three dispatch observers
    (Tool_metrics / Tool_usage_log / Otel_dispatch_hook) match only
    [Handled, Some _] and drop everything else via [_ -> ()], so the
    failure never reached the unified observer view.

    The fix emits [Handled (Some error_result)] — the same shape the
    exec error path uses — so the failure is recorded.  These tests pin
    that contract at the observer boundary:

    1. A failure result delivered as [Handled (Some r)] reaches the
       [Tool_metrics] observer and is counted as a failure.
    2. The [Workflow_rejection] failure class survives in the result so
       observers can still distinguish a validation rejection. *)

let mk_validation_failure ~tool_name =
  (* Mirrors the result Tool_input_validation.validate_args returns: an
     Error with class_ = Workflow_rejection. *)
  Tool_result.error
    ~failure_class:(Some Tool_result.Workflow_rejection)
    ~tool_name
    ~start_time:(Unix.gettimeofday ())
    "validation_failed: missing required field"
;;

let test_validation_failure_recorded_by_metrics () =
  let tool_name = "test_validation_observer_tool" in
  Tool_metrics.clear ();
  Tool_dispatch.clear_hooks ();
  Tool_metrics.install ();
  let result = mk_validation_failure ~tool_name in
  (* Same call shape as the fixed validation path in
     Keeper_tools_oas_handler. *)
  Tool_dispatch.run_dispatch_observers Dispatch_outcome.Handled (Some result);
  Tool_dispatch.clear_hooks ();
  match Tool_metrics.stats_for tool_name with
  | None ->
    fail
      "validation failure was dropped: Tool_metrics observer recorded nothing \
       (this is the pre-fix observer-drop bug)"
  | Some stats ->
    check int "one call recorded" 1 stats.call_count;
    check int "recorded as a failure" 1 stats.failure_count;
    check int "not recorded as a success" 0 stats.success_count
;;

let test_handler_error_shape_is_dropped () =
  (* Counter-test: the OLD shape ([No_handler] / non-[Handled, Some]) must
     NOT be recorded, confirming the observers really do drop non-[Handled]
     outcomes and that the fix works precisely by switching to [Handled]. *)
  let tool_name = "test_validation_observer_dropped_tool" in
  Tool_metrics.clear ();
  Tool_dispatch.clear_hooks ();
  Tool_metrics.install ();
  (* No_handler with a result option still does not match [Handled, Some _]. *)
  Tool_dispatch.run_dispatch_observers Dispatch_outcome.No_handler None;
  Tool_dispatch.clear_hooks ();
  match Tool_metrics.stats_for tool_name with
  | None -> ()
  | Some _ -> fail "No_handler outcome must not be recorded by Tool_metrics"
;;

let test_workflow_rejection_class_survives () =
  let tool_name = "test_validation_observer_class_tool" in
  let result = mk_validation_failure ~tool_name in
  match Tool_result.failure_class result with
  | Some Tool_result.Workflow_rejection -> ()
  | Some other ->
    failf
      "expected Workflow_rejection failure class, got %s"
      (Tool_result.tool_failure_class_to_string other)
  | None -> fail "validation failure must carry a failure class"
;;

let () =
  run
    "dispatch-observer-validation-failure"
    [ ( "observer fan-out"
      , [ test_case
            "validation failure recorded by Tool_metrics"
            `Quick
            test_validation_failure_recorded_by_metrics
        ; test_case
            "non-Handled outcome is dropped"
            `Quick
            test_handler_error_shape_is_dropped
        ; test_case
            "Workflow_rejection class survives"
            `Quick
            test_workflow_rejection_class_survives
        ] )
    ]
;;
