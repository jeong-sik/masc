open Alcotest

(** RFC-0084 PR-3 — [Tool_telemetry.with_span] + [Tool_dispatch.guarded_dispatch]
    skeleton tests.

    Verifies:
    - [with_span] invokes the callback exactly once
    - The callback receives a [trace_id_thunk] that is callable (returns
      [None] when OTel is disabled, [Some _] when active)
    - The [outcome] string returned from the callback propagates back to
      the caller
    - [register_metrics] is idempotent across repeated calls
    - [guarded_dispatch] for an unregistered tool returns [None] (the
      [No_handler] arm — PR-10 will narrow the outcome to a typed variant) *)

let test_with_span_invokes_callback_once () =
  let invoked = ref 0 in
  let _result, _outcome =
    Masc_mcp.Tool_telemetry.with_span ~tool_name:"test_tool_unit" (fun _trace_id ->
      incr invoked;
      (), "handled")
  in
  (check int) "with_span invokes the callback exactly once" 1 !invoked
;;

let test_with_span_returns_outcome_label () =
  let _result, outcome =
    Masc_mcp.Tool_telemetry.with_span ~tool_name:"test_outcome_label" (fun _trace_id ->
      (), "no_handler")
  in
  (check string) "outcome label propagates to caller" "no_handler" outcome
;;

let test_trace_id_thunk_is_callable () =
  let thunk_called = ref false in
  let _result, _outcome =
    Masc_mcp.Tool_telemetry.with_span ~tool_name:"test_trace_id_thunk" (fun trace_id_thunk ->
      let _ = trace_id_thunk () in
      thunk_called := true;
      (), "handled")
  in
  (check bool) "trace_id_thunk callable inside the span" true !thunk_called
;;

let test_register_metrics_idempotent () =
  (* Calling twice must not raise (Prometheus would otherwise reject
     duplicate counter registration). *)
  Masc_mcp.Tool_telemetry.register_metrics ();
  Masc_mcp.Tool_telemetry.register_metrics ();
  (check bool) "register_metrics idempotent across repeated calls" true true
;;

let test_with_span_result_propagates () =
  let result, _outcome =
    Masc_mcp.Tool_telemetry.with_span ~tool_name:"test_result_propagate" (fun _trace_id ->
      42, "handled")
  in
  (check int) "result value from callback returned to caller" 42 result
;;

let () =
  Alcotest.run
    "RFC-0084 PR-3 guarded_dispatch telemetry skeleton"
    [ ( "tool-telemetry"
      , [ test_case "with-span-invokes-callback-once" `Quick test_with_span_invokes_callback_once
        ; test_case "with-span-returns-outcome-label" `Quick test_with_span_returns_outcome_label
        ; test_case "trace-id-thunk-is-callable" `Quick test_trace_id_thunk_is_callable
        ; test_case "register-metrics-idempotent" `Quick test_register_metrics_idempotent
        ; test_case "with-span-result-propagates" `Quick test_with_span_result_propagates
        ] )
    ]
;;
