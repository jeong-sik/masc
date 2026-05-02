(** test_keeper_turn_fsm_emit — Step 4b sentinel.

    Pins the [Keeper_turn_fsm.emit_transition] surface so a future
    refactor that drops [?prev] or renames a cancel/failure
    variant fails compilation here, not at runtime.

    The function emits via [Log.Keeper.info] which is fail-open;
    we don't assert on the log ring contents (that would couple
    the test to log buffer internals).  What we *do* pin:
    - the function exists with the documented labels
    - every cancel_reason and failure_reason variant is reachable
      via the public [turn_state_label] surface so that
      [bin/masc-trace] grouping does not silently lose a state
*)

open Masc_mcp
module F = Keeper_turn_fsm

(* ── Compile-time signature anchor ─────────────────────────── *)

let test_emit_transition_signature_stable () =
  (* Pass concrete values so a signature drift (e.g. removing
     [?prev], or moving [keeper_name] off labelled args) fails
     to type-check. *)
  F.emit_transition
    ~keeper_name:"alice"
    ~turn_id:42
    ~prev:F.Phase_gating
    (F.Cancelled F.Cancelled_phase_gate_close);
  F.emit_transition
    ~keeper_name:"bob"
    ~turn_id:0
    (F.Failed (F.Failure_runtime_error "noop"));
  F.emit_transition ~keeper_name:"carol" ~turn_id:1 F.Idle;
  Alcotest.(check bool)
    "emit_transition accepts ?prev / labelled args / int turn_id"
    true
    true
;;

(* ── Label coverage ────────────────────────────────────────── *)

let test_turn_state_labels_cover_every_variant () =
  let pairs : (F.turn_state * string) list =
    [ F.Idle, "idle"
    ; F.Phase_gating, "phase_gating"
    ; F.Cascade_routing, "cascade_routing"
    ; F.Awaiting_provider, "awaiting_provider"
    ; F.Streaming, "streaming"
    ; F.Awaiting_tool_result, "awaiting_tool"
    ; F.Completing, "completing"
    ; F.Done, "done"
    ; F.Failed (F.Failure_runtime_error "x"), "failed:runtime_error"
    ; F.Cancelled F.Cancelled_phase_gate_close, "cancelled:phase_gate_close"
    ]
  in
  List.iter
    (fun (s, expected) ->
       Alcotest.(check string)
         ("turn_state_label " ^ expected)
         expected
         (F.turn_state_label s))
    pairs
;;

let check_action ?ctx expected ~from_state ~to_state =
  match F.classify_transition ?ctx ~from_state ~to_state () with
  | Some actual ->
    Alcotest.(check string)
      ("transition action " ^ F.transition_action_label expected)
      (F.transition_action_label expected)
      (F.transition_action_label actual)
  | None ->
    Alcotest.failf
      "expected transition action %s for %s -> %s"
      (F.transition_action_label expected)
      (F.turn_state_label from_state)
      (F.turn_state_label to_state)
;;

let test_transition_actions_cover_tla_next () =
  check_action F.StartTurn ~from_state:F.Idle ~to_state:F.Phase_gating;
  check_action F.PhaseGateSkip ~from_state:F.Phase_gating ~to_state:F.Done;
  check_action F.PhaseGateOk ~from_state:F.Phase_gating ~to_state:F.Cascade_routing;
  check_action F.CascadeRouted ~from_state:F.Cascade_routing ~to_state:F.Awaiting_provider;
  check_action
    F.CascadeUnavailable
    ~from_state:F.Cascade_routing
    ~to_state:
      (F.Failed (F.Failure_cascade_unavailable { base = "ollama"; resolved = None }));
  check_action F.ProviderResponded ~from_state:F.Awaiting_provider ~to_state:F.Streaming;
  check_action
    F.ProviderTimeout
    ~from_state:F.Awaiting_provider
    ~to_state:(F.Cancelled F.Cancelled_provider_timeout);
  check_action F.StreamYieldsTool ~from_state:F.Streaming ~to_state:F.Awaiting_tool_result;
  check_action F.ToolReturned ~from_state:F.Awaiting_tool_result ~to_state:F.Streaming;
  check_action F.StreamComplete ~from_state:F.Streaming ~to_state:F.Completing;
  check_action F.ContractOk ~from_state:F.Completing ~to_state:F.Done;
  check_action
    F.ContractViolation
    ~from_state:F.Completing
    ~to_state:
      (F.Failed (F.Failure_tool_contract_violation { reason_code = "passive_only" }));
  check_action
    F.ReceiptLost
    ~from_state:F.Completing
    ~to_state:
      (F.Failed (F.Failure_receipt_lost { primary_error = "io"; fallback_path = None }));
  check_action
    F.GenericFail
    ~from_state:F.Streaming
    ~to_state:(F.Failed (F.Failure_runtime_error "boom"));
  let stop_raised_ctx =
    { F.stop_signaled_before = false; stop_signaled_after = true }
  in
  check_action ~ctx:stop_raised_ctx
    F.SupervisorRequestsStop ~from_state:F.Streaming ~to_state:F.Streaming;
  check_action
    F.HonorStopSignal
    ~from_state:F.Streaming
    ~to_state:(F.Cancelled F.Cancelled_supervisor_stop);
  check_action F.TerminalStutter ~from_state:F.Done ~to_state:F.Done
;;

let test_invalid_transition_rejected () =
  match F.assert_transition_allowed ~from_state:F.Idle ~to_state:F.Done () with
  | Error violation ->
    Alcotest.(check string) "invalid edge from state" "idle" violation.from_state;
    Alcotest.(check string) "invalid edge to state" "done" violation.to_state;
    Alcotest.(check string)
      "invalid edge reason"
      "not_in_keeper_turn_fsm_next"
      violation.reason
  | Ok action ->
    Alcotest.failf
      "Idle -> Done unexpectedly classified as %s"
      (F.transition_action_label action)
;;

let test_stop_signaled_blocks_forward_transitions () =
  let stop_active_ctx =
    { F.stop_signaled_before = true; stop_signaled_after = true }
  in
  (* StartTurn must be rejected when stop_signaled is already active *)
  (match F.classify_transition ~ctx:stop_active_ctx
            ~from_state:F.Idle ~to_state:F.Phase_gating () with
   | None -> ()
   | Some action ->
     Alcotest.failf
       "StartTurn should be blocked by stop_signaled, got %s"
       (F.transition_action_label action));
  (* PhaseGateOk must be rejected when stop_signaled is active *)
  (match F.classify_transition ~ctx:stop_active_ctx
            ~from_state:F.Phase_gating ~to_state:F.Cascade_routing () with
   | None -> ()
   | Some action ->
     Alcotest.failf
       "PhaseGateOk should be blocked by stop_signaled, got %s"
       (F.transition_action_label action))
;;

let test_omitted_stop_context_keeps_legacy_stop_fallback () =
  (* Older callers did not pass the orthogonal stop context.  Keep their
     active-state self transition fallback as SupervisorRequestsStop. *)
  match F.classify_transition ~from_state:F.Streaming ~to_state:F.Streaming () with
  | Some F.SupervisorRequestsStop -> ()
  | None -> Alcotest.fail "omitted ctx should preserve SupervisorRequestsStop fallback"
  | Some action ->
    Alcotest.failf
      "omitted ctx should be SupervisorRequestsStop, got %s"
      (F.transition_action_label action)
;;

let test_same_state_with_explicit_no_stop_signal_is_none () =
  (* Once callers pass ctx explicitly, false -> false is not a stop request. *)
  let no_signal_ctx =
    { F.stop_signaled_before = false; F.stop_signaled_after = false }
  in
  (match F.classify_transition ~ctx:no_signal_ctx
            ~from_state:F.Streaming ~to_state:F.Streaming () with
   | None -> ()
   | Some action ->
     Alcotest.failf
       "same-state with explicit no signal should be None, got %s"
       (F.transition_action_label action))
;;

let test_supervisor_requests_stop_requires_signal_transition () =
  (* stop_signaled staying false -> false should NOT be SupervisorRequestsStop *)
  let no_signal_ctx =
    { F.stop_signaled_before = false; F.stop_signaled_after = false }
  in
  (match F.classify_transition ~ctx:no_signal_ctx
            ~from_state:F.Streaming ~to_state:F.Streaming () with
   | None -> ()
   | Some action ->
     Alcotest.failf
       "same-state with no signal change should be None, got %s"
       (F.transition_action_label action));
  (* stop_signaled already true and staying true should NOT be SupervisorRequestsStop *)
  let signal_already_true_ctx =
    { F.stop_signaled_before = true; F.stop_signaled_after = true }
  in
  (match F.classify_transition ~ctx:signal_already_true_ctx
            ~from_state:F.Streaming ~to_state:F.Streaming () with
   | None -> ()
   | Some action ->
     Alcotest.failf
      "same-state with signal already true should be None, got %s"
      (F.transition_action_label action))
;;

let test_honor_stop_signal_requires_active_signal_context () =
  let no_signal_ctx =
    { F.stop_signaled_before = false; F.stop_signaled_after = false }
  in
  (match F.classify_transition ~ctx:no_signal_ctx
            ~from_state:F.Streaming
            ~to_state:(F.Cancelled F.Cancelled_supervisor_stop) () with
   | None -> ()
   | Some action ->
     Alcotest.failf
       "HonorStopSignal should require active stop context, got %s"
       (F.transition_action_label action));
  let stop_active_ctx =
    { F.stop_signaled_before = true; F.stop_signaled_after = true }
  in
  match F.classify_transition ~ctx:stop_active_ctx
          ~from_state:F.Streaming
          ~to_state:(F.Cancelled F.Cancelled_supervisor_stop) () with
  | Some F.HonorStopSignal -> ()
  | None -> Alcotest.fail "active stop context should allow HonorStopSignal"
  | Some action ->
    Alcotest.failf
      "active stop context should be HonorStopSignal, got %s"
      (F.transition_action_label action)
;;

let test_terminal_stutter_requires_unchanged_stop_context () =
  let stop_changed_ctx =
    { F.stop_signaled_before = false; F.stop_signaled_after = true }
  in
  (match F.classify_transition ~ctx:stop_changed_ctx
            ~from_state:F.Done ~to_state:F.Done () with
   | None -> ()
   | Some action ->
     Alcotest.failf
       "TerminalStutter should reject changed stop context, got %s"
       (F.transition_action_label action));
  let stop_unchanged_ctx =
    { F.stop_signaled_before = true; F.stop_signaled_after = true }
  in
  match F.classify_transition ~ctx:stop_unchanged_ctx
          ~from_state:F.Done ~to_state:F.Done () with
  | Some F.TerminalStutter -> ()
  | None -> Alcotest.fail "unchanged terminal stop context should stutter"
  | Some action ->
    Alcotest.failf
      "unchanged terminal stop context should be TerminalStutter, got %s"
      (F.transition_action_label action)
;;

let test_cancel_reason_labels_documented () =
  let pairs : (F.cancel_reason * string) list =
    [ F.Cancelled_supervisor_stop, "supervisor_stop"
    ; F.Cancelled_phase_gate_close, "phase_gate_close"
    ; F.Cancelled_provider_timeout, "provider_timeout"
    ; F.Cancelled_fleet_shutdown, "fleet_shutdown"
    ]
  in
  List.iter
    (fun (r, expected) ->
       Alcotest.(check string)
         ("cancel_reason " ^ expected)
         expected
         (F.cancel_reason_label r))
    pairs
;;

let test_failure_reason_labels_documented () =
  let pairs : (F.failure_reason * string) list =
    [ ( F.Failure_cascade_unavailable { base = "ollama:7b"; resolved = None }
      , "cascade_unavailable" )
    ; F.Failure_provider_error { kind = "k"; detail = "d" }, "provider_error"
    ; F.Failure_tool_contract_violation { reason_code = "rc" }, "tool_contract_violation"
    ; F.Failure_receipt_lost { primary_error = "e"; fallback_path = None }, "receipt_lost"
    ; ( F.Failure_turn_livelock_blocked { reason = "stuck_after_sec" }
      , "turn_livelock_blocked" )
    ; F.Failure_runtime_error "msg", "runtime_error"
    ; ( F.Failure_unexpected_exception { exn = "Boom"; backtrace = None }
      , "unexpected_exception" )
    ]
  in
  List.iter
    (fun (r, expected) ->
       Alcotest.(check string)
         ("failure_reason " ^ expected)
         expected
         (F.failure_reason_label r))
    pairs
;;

let () =
  Alcotest.run
    "keeper_turn_fsm_emit"
    [ ( "signature_anchor"
      , [ Alcotest.test_case
            "emit_transition surface stable"
            `Quick
            test_emit_transition_signature_stable
        ] )
    ; ( "labels"
      , [ Alcotest.test_case
            "turn_state covers every variant"
            `Quick
            test_turn_state_labels_cover_every_variant
        ; Alcotest.test_case
            "transition actions cover TLA Next"
            `Quick
            test_transition_actions_cover_tla_next
        ; Alcotest.test_case
            "invalid transition rejected"
            `Quick
            test_invalid_transition_rejected
        ; Alcotest.test_case
            "stop_signaled blocks forward transitions"
            `Quick
            test_stop_signaled_blocks_forward_transitions
        ; Alcotest.test_case
            "omitted stop context keeps legacy fallback"
            `Quick
            test_omitted_stop_context_keeps_legacy_stop_fallback
        ; Alcotest.test_case
            "same-state with explicit no stop signal is None"
            `Quick
            test_same_state_with_explicit_no_stop_signal_is_none
        ; Alcotest.test_case
            "SupervisorRequestsStop requires signal transition"
            `Quick
            test_supervisor_requests_stop_requires_signal_transition
        ; Alcotest.test_case
            "HonorStopSignal requires active signal context"
            `Quick
            test_honor_stop_signal_requires_active_signal_context
        ; Alcotest.test_case
            "TerminalStutter requires unchanged stop context"
            `Quick
            test_terminal_stutter_requires_unchanged_stop_context
        ; Alcotest.test_case
            "cancel_reason labels match docs"
            `Quick
            test_cancel_reason_labels_documented
        ; Alcotest.test_case
            "failure_reason labels match docs"
            `Quick
            test_failure_reason_labels_documented
        ] )
    ]
;;
