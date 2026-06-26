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

module R = Masc.Keeper_execution_receipt

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

let check_bool label expected actual =
  if Bool.equal expected actual |> not then
    failwith
      (Printf.sprintf
         "%s: expected %b, got %b"
         label
         expected
         actual)

let stale_idle_failure stall_seconds =
  Some
    (Masc.Keeper_registry.Stale_turn_timeout
       (Masc.Keeper_registry.Idle_turn { stall_seconds }))

let stale_mid_turn_failure since_progress_seconds =
  Some
    (Masc.Keeper_registry.Stale_turn_timeout
       (Masc.Keeper_registry.Mid_turn_no_progress
          { active_seconds = since_progress_seconds +. 30.0
          ; since_progress_seconds
          ; progress_timeout_threshold = 300.0
          ; last_progress_kind = Some "runtime_state"
          }))

let emit_stale_for_testing
      ?(keeper_name = "keeper-a")
      ?(trace_id = "trace-a")
      ?(generation = 1)
      ?(stale_seconds = 120.0)
      ?(failure_reason = stale_idle_failure 120.0)
      ~emit
      ()
  =
  R.For_testing.emit_stale_keeper_broadcast_dedupe_for_testing
    ~keeper_name
    ~agent_name:"keeper-a-agent"
    ~runtime_id:"runtime-a"
    ~trace_id
    ~generation
    ~failure_reason
    ~stale_seconds
    ~emit

let should_emit_stale
      ?(keeper_name = "keeper-a")
      ?(trace_id = "trace-a")
      ?(generation = 1)
      ?(stale_seconds = 120.0)
      ?(failure_reason = stale_idle_failure 120.0)
      ()
  =
  emit_stale_for_testing
    ~keeper_name
    ~trace_id
    ~generation
    ~stale_seconds
    ~failure_reason
    ~emit:(fun () -> ())
    ()

let test_stale_watchdog_broadcast_dedupe () =
  Eio_main.run @@ fun _env ->
  R.For_testing.reset_stale_broadcast_dedupe ();
  check_bool "first stale watchdog alert emits" true (should_emit_stale ());
  check_bool "same keeper/failure/bucket suppresses" false (should_emit_stale ());
  check_bool
    "new stale bucket emits"
    true
    (should_emit_stale ~stale_seconds:650.0 ());
  check_bool
    "same new bucket suppresses"
    false
    (should_emit_stale ~stale_seconds:700.0 ());
  check_bool
    "new trace emits"
    true
    (should_emit_stale ~trace_id:"trace-b" ~stale_seconds:700.0 ());
  check_bool
    "new failure class emits"
    true
    (should_emit_stale
       ~trace_id:"trace-b"
       ~stale_seconds:700.0
       ~failure_reason:(stale_mid_turn_failure 700.0)
       ());
  let key_1 =
    R.For_testing.stale_broadcast_dedupe_key
      ~keeper_name:"keeper-a"
      ~agent_name:"keeper-a-agent"
      ~runtime_id:"runtime-a"
      ~trace_id:"trace-c"
      ~generation:1
      ~failure_reason:(stale_idle_failure 120.0)
      ~stale_seconds:120.0
  in
  let key_2 =
    R.For_testing.stale_broadcast_dedupe_key
      ~keeper_name:"keeper-a"
      ~agent_name:"keeper-a-agent"
      ~runtime_id:"runtime-a"
      ~trace_id:"trace-c"
      ~generation:1
      ~failure_reason:(stale_idle_failure 650.0)
      ~stale_seconds:650.0
  in
  check_bool "dedupe key includes stale bucket" false (key_1 = key_2)

let test_stale_watchdog_emit_regression () =
  Eio_main.run @@ fun _env ->
  R.For_testing.reset_stale_broadcast_dedupe ();
  let exception Emit_failed in
  let attempts = ref 0 in
  (try
     ignore
       (emit_stale_for_testing
          ~emit:(fun () ->
            incr attempts;
            raise Emit_failed)
          ());
     failwith "expected stale broadcast emit failure"
   with
   | Emit_failed -> ());
  check_bool "failed emit was attempted" true (!attempts = 1);
  check_bool
    "same key retries after failed emit"
    true
    (emit_stale_for_testing
       ~emit:(fun () ->
         incr attempts)
       ());
  check_bool "successful retry was attempted" true (!attempts = 2);
  check_bool
    "same key suppresses after successful emit"
    false
    (emit_stale_for_testing
       ~emit:(fun () -> failwith "duplicate should not call emit")
       ())

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
  test_stale_watchdog_broadcast_dedupe ();
  test_stale_watchdog_emit_regression ();
  print_endline "test_keeper_receipt_authoritative: OK"
