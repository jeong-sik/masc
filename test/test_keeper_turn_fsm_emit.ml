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
  F.emit_transition ~keeper_name:"alice" ~turn_id:42
    ~prev:F.Phase_gating
    (F.Cancelled F.Cancelled_phase_gate_close);
  F.emit_transition ~keeper_name:"bob" ~turn_id:0
    (F.Failed (F.Failure_runtime_error "noop"));
  F.emit_transition ~keeper_name:"carol" ~turn_id:1
    F.Idle;
  Alcotest.(check bool)
    "emit_transition accepts ?prev / labelled args / int turn_id"
    true true

(* ── Label coverage ────────────────────────────────────────── *)

let test_turn_state_labels_cover_every_variant () =
  let pairs : (F.turn_state * string) list =
    [
      (F.Idle, "idle");
      (F.Phase_gating, "phase_gating");
      (F.Cascade_routing, "cascade_routing");
      (F.Awaiting_provider, "awaiting_provider");
      (F.Streaming, "streaming");
      (F.Awaiting_tool_result, "awaiting_tool_result");
      (F.Completing, "completing");
      (F.Done, "done");
      ( F.Failed (F.Failure_runtime_error "x"),
        "failed:runtime_error" );
      ( F.Cancelled F.Cancelled_phase_gate_close,
        "cancelled:phase_gate_close" );
    ]
  in
  List.iter
    (fun (s, expected) ->
      Alcotest.(check string)
        ("turn_state_label " ^ expected)
        expected (F.turn_state_label s))
    pairs

let test_cancel_reason_labels_documented () =
  let pairs : (F.cancel_reason * string) list =
    [
      (F.Cancelled_supervisor_stop, "supervisor_stop");
      (F.Cancelled_phase_gate_close, "phase_gate_close");
      (F.Cancelled_provider_timeout, "provider_timeout");
      (F.Cancelled_fleet_shutdown, "fleet_shutdown");
    ]
  in
  List.iter
    (fun (r, expected) ->
      Alcotest.(check string)
        ("cancel_reason " ^ expected)
        expected (F.cancel_reason_label r))
    pairs

let test_failure_reason_labels_documented () =
  let pairs : (F.failure_reason * string) list =
    [
      ( F.Failure_cascade_unavailable
          { base = "ollama:7b"; resolved = None },
        "cascade_unavailable" );
      ( F.Failure_provider_error { kind = "k"; detail = "d" },
        "provider_error" );
      ( F.Failure_tool_contract_violation { reason_code = "rc" },
        "tool_contract_violation" );
      ( F.Failure_receipt_lost
          { primary_error = "e"; fallback_path = None },
        "receipt_lost" );
      (F.Failure_runtime_error "msg", "runtime_error");
      ( F.Failure_unexpected_exception
          { exn = "Boom"; backtrace = None },
        "unexpected_exception" );
    ]
  in
  List.iter
    (fun (r, expected) ->
      Alcotest.(check string)
        ("failure_reason " ^ expected)
        expected (F.failure_reason_label r))
    pairs

let () =
  Alcotest.run "keeper_turn_fsm_emit"
    [
      ( "signature_anchor",
        [
          Alcotest.test_case "emit_transition surface stable"
            `Quick test_emit_transition_signature_stable;
        ] );
      ( "labels",
        [
          Alcotest.test_case "turn_state covers every variant"
            `Quick test_turn_state_labels_cover_every_variant;
          Alcotest.test_case "cancel_reason labels match docs"
            `Quick test_cancel_reason_labels_documented;
          Alcotest.test_case "failure_reason labels match docs"
            `Quick test_failure_reason_labels_documented;
        ] );
    ]
