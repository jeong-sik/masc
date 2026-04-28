(* Cartesian sentinel matrix for [assert_receipt_authoritative].

   The single-concern helper enforces the OCaml-runtime image of the
   TLA+ [ReceiptIsAuthoritative] invariant
   (specs/keeper-turn-fsm/KeeperTurnFSM.tla:336):

       receipt_outcome = "receipt_done" => turn_state = "done"

   Per [ReceiptMatchesState] the [Done] state also accepts
   [receipt_skipped] (PhaseGateSkip path), so the helper rejects
   [`Ok] or [`Skipped] paired with anything but ["done"]. The
   [`Error] / [`Cancelled] pair is the concern of
   [ReceiptMatchesState], not this helper, so it accepts.

   The companion file [test_keeper_receipt_authoritative.ml] pins
   representative cases. This matrix instead enumerates every
   [(outcome, turn_state)] cell from [Keeper_turn_fsm.all_symbols]
   (ppx_tla derived, kept in sync with [TurnStateSet] by
   [test_keeper_turn_fsm_tla_parity]) so any of the following surfaces
   as a build failure:

   - a new turn_state added to the spec without considering its
     receipt-authority pairing,
   - a new [outcome_kind] variant that the helper does not classify,
   - a regression that loosens the helper to accept a forbidden pair.

   Production callers in [keeper_unified_turn] and [keeper_agent_run]
   currently derive [outcome] and the implied [turn_state] from the
   same [turn_result] expression, so wiring the helper into the
   runtime is trivially [Ok ()] today. The drift sentinel here is the
   value-bearing piece of Phase 1-3: it locks the helper's behaviour
   so that when callers do diverge (a concern that surfaces in
   [ReceiptMatchesState] coverage work) the helper is already pinned. *)

module R = Masc_mcp.Keeper_execution_receipt
module F = Masc_mcp.Keeper_turn_fsm

let all_outcomes : R.outcome_kind list =
  [ `Ok; `Skipped; `Error; `Cancelled ]

let outcome_label : R.outcome_kind -> string = function
  | `Ok -> "`Ok"
  | `Skipped -> "`Skipped"
  | `Error -> "`Error"
  | `Cancelled -> "`Cancelled"

type expectation = Ok_expected | Error_expected

let expected_of outcome turn_state =
  match outcome, turn_state with
  | (`Ok | `Skipped), "done" -> Ok_expected
  | (`Ok | `Skipped), _ -> Error_expected
  | (`Error | `Cancelled), _ -> Ok_expected

let expected_violation_label = function
  | `Ok -> "receipt_done"
  | `Skipped -> "receipt_skipped"
  | `Error | `Cancelled ->
      (* Never reached: these variants pass the helper for every
         turn_state. If a future change makes them violate, the
         caller's pattern match below will hit the [Error v] arm with
         these variants and we want a loud failure here. *)
      "<unreachable: error/cancelled never violate>"

let test_matrix_size () =
  let outcome_count = List.length all_outcomes in
  let state_count = List.length F.all_symbols in
  if outcome_count <> 4 then
    failwith
      (Printf.sprintf
         "expected 4 outcome_kind variants, got %d — \
          extend [all_outcomes] and reconsider expected_of"
         outcome_count);
  if state_count < 10 then
    failwith
      (Printf.sprintf
         "expected at least 10 turn states in [Keeper_turn_fsm.all_symbols] \
          (TurnStateSet floor); got %d"
         state_count);
  Printf.printf
    "receipt-authoritative matrix: %d outcomes × %d turn_states = %d cells\n"
    outcome_count state_count (outcome_count * state_count)

let test_matrix_completeness () =
  let mismatches = ref [] in
  List.iter
    (fun outcome ->
      List.iter
        (fun turn_state ->
          let actual = R.assert_receipt_authoritative ~outcome ~turn_state in
          let expected = expected_of outcome turn_state in
          match actual, expected with
          | Ok (), Ok_expected -> ()
          | Error v, Error_expected ->
              let want = expected_violation_label outcome in
              if v.outcome <> want || v.turn_state <> turn_state then
                mismatches :=
                  Printf.sprintf
                    "[label-drift] outcome=%s turn_state=%s got receipt=%s state=%s want receipt=%s"
                    (outcome_label outcome) turn_state v.outcome v.turn_state want
                  :: !mismatches
          | Ok (), Error_expected ->
              mismatches :=
                Printf.sprintf
                  "[expected-violation] outcome=%s turn_state=%s helper returned Ok"
                  (outcome_label outcome) turn_state
                :: !mismatches
          | Error v, Ok_expected ->
              mismatches :=
                Printf.sprintf
                  "[unexpected-violation] outcome=%s turn_state=%s receipt=%s state=%s"
                  (outcome_label outcome) turn_state v.outcome v.turn_state
                :: !mismatches)
        F.all_symbols)
    all_outcomes;
  match !mismatches with
  | [] -> ()
  | xs ->
      List.iter print_endline (List.rev xs);
      failwith
        (Printf.sprintf
           "%d mismatch(es) in receipt-authoritative matrix"
           (List.length xs))

let () =
  test_matrix_size ();
  test_matrix_completeness ();
  print_endline "test_keeper_receipt_authoritative_matrix: OK"
