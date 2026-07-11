(* Producer↔wire↔consumer contract for the turn-budget-exhausted disposition.

   This is the regression guard for the #22618 test-backdoor. The receipt
   producer [Keeper_execution_receipt_types.stop_reason_to_string] used to emit
   a colon form ["turn_budget_exhausted:<used>/<limit>"], while the dashboard /
   runtime-trust consumer [Keeper_turn_disposition.of_wire] only parses the
   paren grammar ["turn_budget_exhausted(<used>/<limit>)"]. The mismatch made
   [of_wire] return [Unknown], so the dashboard misreported the keeper budget
   state. #22618 hid this by hand-editing the fixtures to a fabricated
   full-detail form no producer emits, instead of fixing the producer.

   The fix routes the producer through [Keeper_turn_disposition.to_wire] so the
   wire grammar has a single SSOT. This test pins both halves of the contract:
   the producer's exact output, and the consumer accepting it as a typed
   [Turn_budget_exhausted]. It is non-vacuous against the original bug: reverting
   the producer to the colon form turns assertion 1 and 3 red. *)

(* The same boundary must keep runtime-stop and final-disposition domains
   distinct: [Runtime_agent.Completed] remains ["completed"] in runtime
   telemetry, while a terminal receipt projects it to canonical ["success"]. *)

module D = Masc.Keeper_turn_disposition
module Receipt = Masc.Keeper_execution_receipt_types

let failures = ref []
let check name cond = if not cond then failures := name :: !failures

let () =
  let runtime_stop_wire = Receipt.stop_reason_to_string Runtime_agent.Completed in
  check
    (Printf.sprintf "runtime stop keeps completed wire (got %S)" runtime_stop_wire)
    (String.equal runtime_stop_wire "completed");
  let success_wire =
    Receipt.receipt_terminal_reason_code_of_stop_reason Runtime_agent.Completed
  in
  check
    (Printf.sprintf "terminal receipt emits canonical success (got %S)" success_wire)
    (String.equal success_wire "success");
  check
    "canonical success round-trips as Success"
    (D.is_success (D.of_wire success_wire));
  check
    "runtime completed is not a final disposition"
    (match D.of_wire "completed" with
     | D.Unknown _ -> true
     | _ -> false);
  check
    "whitespace success is not silently normalized"
    (match D.of_wire " success " with
     | D.Unknown _ -> true
     | _ -> false);
  check
    "uppercase legacy spelling is not silently normalized"
    (match D.of_wire "COMPLETED" with
     | D.Unknown _ -> true
     | _ -> false);
  check
    "runtime-attempt completion keeps its distinct typed wire"
    (String.equal
       (Receipt.runtime_outcome_to_string Receipt.Runtime_completed)
       "completed");
  let used = 1070 and limit = 1070 in
  let wire =
    Receipt.stop_reason_to_string
      (Runtime_agent.TurnBudgetExhausted { turns_used = used; limit })
  in
  (* 1. Producer emits the detail-less paren form (the SSOT wire grammar). *)
  check
    (Printf.sprintf "producer emits paren detail-less form (got %S)" wire)
    (String.equal wire (Printf.sprintf "turn_budget_exhausted(%d/%d)" used limit));
  (* 2. Producer output round-trips through the consumer to the typed value the
     dashboard reads. [detail] is None because [Runtime_agent] carries no such
     detail. *)
  (match D.of_wire wire with
   | D.Turn_budget_exhausted { detail = None; used = u; limit = l } ->
     check "round-trip used" (u = used);
     check "round-trip limit" (l = limit)
   | other ->
     check
       (Printf.sprintf
          "consumer classifies producer output as Turn_budget_exhausted (got %s)"
          (D.to_wire other))
       false);
  (* 3. The grammar is strict and single: the legacy colon form is intentionally
     NOT tolerated by of_wire. There is no migration for receipts persisted in the
     colon form before this fix — they read as Unknown and self-heal on the
     keeper's next turn (an idle keeper's stale field is transient). Re-adding a
     colon-tolerant read path (as #22549 did) turns this red. *)
  (match D.of_wire (Printf.sprintf "turn_budget_exhausted:%d/%d" used limit) with
   | D.Unknown _ -> ()
   | other ->
     check
       (Printf.sprintf
          "colon form should be Unknown, not %s — colon tolerance reintroduced"
          (D.to_wire other))
       false);
  match !failures with
  | [] -> print_endline "test_keeper_execution_receipt_budget_wire: OK"
  | xs ->
    List.iter (fun n -> print_endline ("FAIL: " ^ n)) (List.rev xs);
    failwith
      (Printf.sprintf "%d disposition-wire contract assertion(s) failed" (List.length xs))
;;
