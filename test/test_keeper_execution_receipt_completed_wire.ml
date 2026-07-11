(* Producer↔wire↔consumer contract for the Completed disposition (#24073 point 5).

   The receipt producer [Keeper_execution_receipt_types.stop_reason_to_string]
   used to emit the raw literal ["completed"] for [Runtime_agent.Completed]. The
   dashboard / runtime-trust consumer [Keeper_turn_disposition.of_wire] only maps
   ["success"] to [Success]; ["completed"] fell through to [Unknown], so a
   genuinely completed turn displayed severity=bad (observed on a paused keeper's
   stale terminal_reason). The fix routes the producer through the single
   [Keeper_turn_disposition.to_wire] SSOT (= "success"), exactly as the adjacent
   [TurnBudgetExhausted] case already does. Mirrors
   test_keeper_execution_receipt_budget_wire. Non-vacuous: reverting the producer
   to the raw "completed" literal turns assertions 1 and 2 red. *)

module D = Masc.Keeper_turn_disposition
module Receipt = Masc.Keeper_execution_receipt_types

let failures = ref []
let check name cond = if not cond then failures := name :: !failures

let () =
  let wire = Receipt.stop_reason_to_string Runtime_agent.Completed in
  (* 1. Producer emits the canonical success wire (the SSOT grammar). *)
  check
    (Printf.sprintf "producer emits canonical success wire (got %S)" wire)
    (String.equal wire "success");
  (* 2. Producer output round-trips through the consumer to the typed value the
     dashboard reads. *)
  (match D.of_wire wire with
   | D.Success -> ()
   | other ->
     check
       (Printf.sprintf
          "consumer classifies producer output as Success (got %s)"
          (D.to_wire other))
       false);
  (* 3. The legacy raw "completed" is intentionally NOT tolerated by of_wire:
     receipts persisted before this fix read as Unknown and self-heal on the
     keeper's next turn (same migration stance as the budget-wire fix — a
     completed-tolerant of_wire path is the rejected decoder-alias workaround). *)
  (match D.of_wire "completed" with
   | D.Unknown _ -> ()
   | other ->
     check
       (Printf.sprintf
          "legacy 'completed' should read Unknown, not %s — alias reintroduced"
          (D.to_wire other))
       false);
  match !failures with
  | [] -> print_endline "test_keeper_execution_receipt_completed_wire: OK"
  | xs ->
    List.iter (fun n -> print_endline ("FAIL: " ^ n)) (List.rev xs);
    failwith
      (Printf.sprintf "%d completed-wire contract assertion(s) failed"
         (List.length xs))
;;
