(* Unit tests for [Keeper_execution_receipt.assert_receipt_authoritative].

   The function enforces the OCaml-runtime image of the TLA+
   [ReceiptIsAuthoritative] invariant
   (specs/keeper-turn-fsm/KeeperTurnFSM.tla:336):

       receipt_outcome = "receipt_done" => turn_state = "done"

   Per [ReceiptMatchesState] the [Done] state also accepts
   [receipt_skipped] (PhaseGateSkip path), so a successful-terminal
   receipt ([`Ok] or [`Skipped]) must be paired with [turn_state =
   "done"]. [`Error] and [`Cancelled] are accepted unconditionally
   here because their state-pairing is enforced by
   [ReceiptMatchesState] (a separate invariant) — this helper is
   single-concern. *)

module R = Masc_mcp.Keeper_execution_receipt

let must_ok ~outcome ~turn_state =
  match R.assert_receipt_authoritative ~outcome ~turn_state with
  | Ok () -> ()
  | Error v ->
      failwith
        (Printf.sprintf
           "expected Ok for outcome=<variant> turn_state=%s but got \
            Error { outcome=%s; turn_state=%s }"
           turn_state v.outcome v.turn_state)

let must_error ~outcome ~turn_state ~expected_receipt_label =
  match R.assert_receipt_authoritative ~outcome ~turn_state with
  | Ok () ->
      failwith
        (Printf.sprintf
           "expected Error for outcome=<variant> turn_state=%s but got \
            Ok ()"
           turn_state)
  | Error v ->
      if v.outcome <> expected_receipt_label then
        failwith
          (Printf.sprintf
             "expected violation receipt label %s, got %s"
             expected_receipt_label v.outcome);
      if v.turn_state <> turn_state then
        failwith
          (Printf.sprintf
             "expected violation turn_state %s, got %s" turn_state
             v.turn_state)

let test_ok_done () = must_ok ~outcome:`Ok ~turn_state:"done"

let test_skipped_done () =
  (* PhaseGateSkip: turn reaches terminal Done without dispatching;
     this is the canonical case `Skipped invariant must accept. *)
  must_ok ~outcome:`Skipped ~turn_state:"done"

let test_ok_failed_violation () =
  must_error ~outcome:`Ok ~turn_state:"failed"
    ~expected_receipt_label:"receipt_done"

let test_ok_cancelled_violation () =
  must_error ~outcome:`Ok ~turn_state:"cancelled"
    ~expected_receipt_label:"receipt_done"

let test_ok_idle_violation () =
  (* receipt_done arriving while still in idle would be a serious
     state-machine bug — must surface as Error, never silently passed. *)
  must_error ~outcome:`Ok ~turn_state:"idle"
    ~expected_receipt_label:"receipt_done"

let test_skipped_failed_violation () =
  must_error ~outcome:`Skipped ~turn_state:"failed"
    ~expected_receipt_label:"receipt_skipped"

let test_skipped_phase_gating_violation () =
  (* If receipt_skipped is set but the turn is still in phase_gating,
     the FSM emitted a receipt before the PhaseGateSkip transition
     completed — invariant violated. *)
  must_error ~outcome:`Skipped ~turn_state:"phase_gating"
    ~expected_receipt_label:"receipt_skipped"

let test_error_failed_passes () =
  (* `Error pairing is the concern of ReceiptMatchesState, not
     ReceiptIsAuthoritative. Single-concern helper accepts. *)
  must_ok ~outcome:`Error ~turn_state:"failed"

let test_error_done_passes () =
  (* Even `Error + "done" passes here — that pairing is checked
     elsewhere. The receipt-authoritative direction is only about
     `Ok / `Skipped. *)
  must_ok ~outcome:`Error ~turn_state:"done"

let test_cancelled_cancelled_passes () =
  must_ok ~outcome:`Cancelled ~turn_state:"cancelled"

let test_cancelled_done_passes () =
  must_ok ~outcome:`Cancelled ~turn_state:"done"

let () =
  test_ok_done ();
  test_skipped_done ();
  test_ok_failed_violation ();
  test_ok_cancelled_violation ();
  test_ok_idle_violation ();
  test_skipped_failed_violation ();
  test_skipped_phase_gating_violation ();
  test_error_failed_passes ();
  test_error_done_passes ();
  test_cancelled_cancelled_passes ();
  test_cancelled_done_passes ();
  print_endline "test_keeper_receipt_authoritative: OK"
