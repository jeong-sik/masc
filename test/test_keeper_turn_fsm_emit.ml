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

let check_action expected ~from_state ~to_state =
  match F.classify_transition ~from_state ~to_state with
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
  check_action F.SupervisorRequestsStop ~from_state:F.Streaming ~to_state:F.Streaming;
  check_action
    F.HonorStopSignal
    ~from_state:F.Streaming
    ~to_state:(F.Cancelled F.Cancelled_supervisor_stop);
  check_action F.TerminalStutter ~from_state:F.Done ~to_state:F.Done
;;

let test_invalid_transition_rejected () =
  match F.assert_transition_allowed ~from_state:F.Idle ~to_state:F.Done with
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

(* ── fsm_state / classify_fsm_transition ──────────────────────── *)

(** Build an [fsm_state] concisely for tests. *)
let fsm ?(ss = false) ts = F.make_fsm_state ~stop_signaled:ss ts

let check_fsm_action expected ~from_state ~to_state =
  match F.classify_fsm_transition ~from_state ~to_state with
  | Some actual ->
    Alcotest.(check string)
      ("fsm transition action " ^ F.transition_action_label expected)
      (F.transition_action_label expected)
      (F.transition_action_label actual)
  | None ->
    Alcotest.failf
      "expected fsm transition action %s for %s(ss=%b) -> %s(ss=%b)"
      (F.transition_action_label expected)
      (F.turn_state_label from_state.F.turn_state)
      from_state.F.stop_signaled
      (F.turn_state_label to_state.F.turn_state)
      to_state.F.stop_signaled
;;

let check_fsm_rejected ~from_state ~to_state =
  match F.classify_fsm_transition ~from_state ~to_state with
  | None -> ()
  | Some action ->
    Alcotest.failf
      "expected fsm transition %s(ss=%b) -> %s(ss=%b) to be rejected, \
       got %s"
      (F.turn_state_label from_state.F.turn_state)
      from_state.F.stop_signaled
      (F.turn_state_label to_state.F.turn_state)
      to_state.F.stop_signaled
      (F.transition_action_label action)
;;

let test_fsm_forward_transitions_require_no_stop_signal () =
  (* All forward transitions must be rejected when stop_signaled is set.
     Per the TLA+ spec, every forward-edge action has the ~stop_signaled
     precondition.  HonorStopSignal is the only allowed exit from an
     active state once stop_signaled = true. *)
  let active_cancelled =
    F.Cancelled F.Cancelled_supervisor_stop
  in
  (* StartTurn blocked when stop_signaled *)
  check_fsm_rejected
    ~from_state:(fsm ~ss:true F.Idle)
    ~to_state:(fsm ~ss:true F.Phase_gating);
  (* PhaseGateOk blocked when stop_signaled *)
  check_fsm_rejected
    ~from_state:(fsm ~ss:true F.Phase_gating)
    ~to_state:(fsm ~ss:true F.Cascade_routing);
  (* CascadeRouted blocked when stop_signaled *)
  check_fsm_rejected
    ~from_state:(fsm ~ss:true F.Cascade_routing)
    ~to_state:(fsm ~ss:true F.Awaiting_provider);
  (* ProviderResponded blocked when stop_signaled *)
  check_fsm_rejected
    ~from_state:(fsm ~ss:true F.Awaiting_provider)
    ~to_state:(fsm ~ss:true F.Streaming);
  (* StreamComplete blocked when stop_signaled *)
  check_fsm_rejected
    ~from_state:(fsm ~ss:true F.Streaming)
    ~to_state:(fsm ~ss:true F.Completing);
  (* ContractOk blocked when stop_signaled *)
  check_fsm_rejected
    ~from_state:(fsm ~ss:true F.Completing)
    ~to_state:(fsm ~ss:true F.Done);
  (* GenericFail blocked when stop_signaled *)
  check_fsm_rejected
    ~from_state:(fsm ~ss:true F.Streaming)
    ~to_state:(fsm ~ss:true (F.Failed (F.Failure_runtime_error "x")));
  (* HonorStopSignal IS allowed when stop_signaled *)
  check_fsm_action F.HonorStopSignal
    ~from_state:(fsm ~ss:true F.Streaming)
    ~to_state:(fsm ~ss:true active_cancelled)
;;

let test_fsm_supervisor_requests_stop_orthogonal () =
  (* SupervisorRequestsStop must flip stop_signaled false→true while
     keeping turn_state UNCHANGED (any active state). *)
  check_fsm_action F.SupervisorRequestsStop
    ~from_state:(fsm ~ss:false F.Streaming)
    ~to_state:(fsm ~ss:true F.Streaming);
  check_fsm_action F.SupervisorRequestsStop
    ~from_state:(fsm ~ss:false F.Awaiting_tool_result)
    ~to_state:(fsm ~ss:true F.Awaiting_tool_result);
  (* Flip without an active state: rejected *)
  check_fsm_rejected
    ~from_state:(fsm ~ss:false F.Idle)
    ~to_state:(fsm ~ss:true F.Idle);
  (* stop_signaled already true: not a new SupervisorRequestsStop *)
  check_fsm_rejected
    ~from_state:(fsm ~ss:true F.Streaming)
    ~to_state:(fsm ~ss:true F.Streaming)
;;

let test_fsm_honor_stop_signal_requires_signaled () =
  (* HonorStopSignal requires stop_signaled = true in from_state.
     Without it, a Cancelled transition from an active state is invalid. *)
  check_fsm_rejected
    ~from_state:(fsm ~ss:false F.Streaming)
    ~to_state:
      (fsm ~ss:false (F.Cancelled F.Cancelled_supervisor_stop));
  (* With stop_signaled = true, HonorStopSignal is allowed *)
  check_fsm_action F.HonorStopSignal
    ~from_state:(fsm ~ss:true F.Phase_gating)
    ~to_state:
      (fsm ~ss:true (F.Cancelled F.Cancelled_phase_gate_close));
  check_fsm_action F.HonorStopSignal
    ~from_state:(fsm ~ss:true F.Completing)
    ~to_state:
      (fsm ~ss:true (F.Cancelled F.Cancelled_fleet_shutdown))
;;

let test_fsm_stop_signaled_orthogonal_to_turn_state () =
  (* Happy-path: stop_signaled must be UNCHANGED (false→false) for all
     forward edges. Changing stop_signaled on a forward-edge transition
     is only legal as SupervisorRequestsStop (same turn_state). *)
  (* stop_signaled must not change on a forward turn-state edge *)
  check_fsm_rejected
    ~from_state:(fsm ~ss:false F.Idle)
    ~to_state:(fsm ~ss:true F.Phase_gating);  (* StartTurn + spurious ss flip *)
  check_fsm_rejected
    ~from_state:(fsm ~ss:false F.Streaming)
    ~to_state:(fsm ~ss:true F.Completing);  (* StreamComplete + spurious ss flip *)
  (* Normal forward edges accepted with ss=false on both sides *)
  check_fsm_action F.StartTurn
    ~from_state:(fsm ~ss:false F.Idle)
    ~to_state:(fsm ~ss:false F.Phase_gating);
  check_fsm_action F.StreamComplete
    ~from_state:(fsm ~ss:false F.Streaming)
    ~to_state:(fsm ~ss:false F.Completing)
;;

let test_fsm_terminal_stutter_preserves_stop_signaled () =
  (* TerminalStutter keeps all vars UNCHANGED, so stop_signaled must not
     change either. *)
  check_fsm_action F.TerminalStutter
    ~from_state:(fsm ~ss:false F.Done)
    ~to_state:(fsm ~ss:false F.Done);
  check_fsm_action F.TerminalStutter
    ~from_state:(fsm ~ss:true (F.Cancelled F.Cancelled_supervisor_stop))
    ~to_state:(fsm ~ss:true (F.Cancelled F.Cancelled_supervisor_stop));
  (* Changing stop_signaled during terminal stutter is rejected *)
  check_fsm_rejected
    ~from_state:(fsm ~ss:false F.Done)
    ~to_state:(fsm ~ss:true F.Done)
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
            "cancel_reason labels match docs"
            `Quick
            test_cancel_reason_labels_documented
        ; Alcotest.test_case
            "failure_reason labels match docs"
            `Quick
            test_failure_reason_labels_documented
        ] )
    ; ( "fsm_state_orthogonality"
      , [ Alcotest.test_case
            "forward transitions require stop_signaled=false"
            `Quick
            test_fsm_forward_transitions_require_no_stop_signal
        ; Alcotest.test_case
            "SupervisorRequestsStop flips stop_signaled false->true"
            `Quick
            test_fsm_supervisor_requests_stop_orthogonal
        ; Alcotest.test_case
            "HonorStopSignal requires stop_signaled=true"
            `Quick
            test_fsm_honor_stop_signal_requires_signaled
        ; Alcotest.test_case
            "stop_signaled orthogonal to turn_state on forward edges"
            `Quick
            test_fsm_stop_signaled_orthogonal_to_turn_state
        ; Alcotest.test_case
            "TerminalStutter preserves stop_signaled"
            `Quick
            test_fsm_terminal_stutter_preserves_stop_signaled
        ] )
    ]
;;
