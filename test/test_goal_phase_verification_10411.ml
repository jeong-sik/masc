(** #10411: Goal_phase.Awaiting_verification was a dead end — the only
    transition out was [Drop].  A goal that entered verification (via
    Executing + Request_complete + has_effective_verifier_policy) had
    no FSM path for verifier success/failure or operator pause/block,
    so verifier outcomes could not propagate to goal completion in
    code (`Goal_phase.Completed` was never assigned via FSM).

    These tests pin the four new transitions and the existing Drop
    semantics. *)

open Alcotest
module GP = Masc_mcp.Goal_phase

let outcome_eq a b =
  match (a, b) with
  | GP.Complete, GP.Complete -> true
  | GP.Open_verification, GP.Open_verification -> true
  | GP.Open_approval, GP.Open_approval -> true
  | GP.Move_to p1, GP.Move_to p2 -> GP.to_string p1 = GP.to_string p2
  | _ -> false

let outcome_pp fmt = function
  | GP.Complete -> Format.fprintf fmt "Complete"
  | GP.Open_verification -> Format.fprintf fmt "Open_verification"
  | GP.Open_approval -> Format.fprintf fmt "Open_approval"
  | GP.Move_to p -> Format.fprintf fmt "Move_to %s" (GP.to_string p)

let outcome = testable outcome_pp outcome_eq

let decide ~phase ~action =
  GP.decide_transition ~phase ~action
    ~has_effective_verifier_policy:false
    ~require_completion_approval:false

let test_approve_completion_completes_verification () =
  match decide ~phase:GP.Awaiting_verification ~action:GP.Approve_completion with
  | Ok o -> check outcome "verifier pass routes to Complete" GP.Complete o
  | Error e -> fail e

let test_reject_completion_blocks_verification () =
  match decide ~phase:GP.Awaiting_verification ~action:GP.Reject_completion with
  | Ok o ->
      check outcome "verifier fail routes to Blocked"
        (GP.Move_to GP.Blocked) o
  | Error e -> fail e

let test_pause_pauses_verification () =
  match decide ~phase:GP.Awaiting_verification ~action:GP.Pause with
  | Ok o ->
      check outcome "Pause from verification reaches Paused"
        (GP.Move_to GP.Paused) o
  | Error e -> fail e

let test_operator_block_blocks_verification () =
  match decide ~phase:GP.Awaiting_verification ~action:GP.Operator_block with
  | Ok o ->
      check outcome "Operator_block from verification reaches Blocked"
        (GP.Move_to GP.Blocked) o
  | Error e -> fail e

let test_drop_still_drops_verification () =
  match decide ~phase:GP.Awaiting_verification ~action:GP.Drop with
  | Ok o ->
      check outcome "Drop preserved"
        (GP.Move_to GP.Dropped) o
  | Error e -> fail e

(* Regression: actions that have no business in verification should
   still raise the directed error.  Resume / Operator_unblock / Reopen
   never made sense from this phase pre-fix and must stay rejected. *)
let test_unrelated_action_rejected () =
  let unrelated = [
    GP.Resume;
    GP.Operator_unblock;
    GP.Reopen;
    GP.Request_complete;
  ] in
  List.iter (fun action ->
    match decide ~phase:GP.Awaiting_verification ~action with
    | Ok _ ->
        fail (Printf.sprintf "%s should be rejected from Awaiting_verification"
                (GP.action_to_string action))
    | Error _ -> ()) unrelated

let () =
  run "goal_phase_verification_10411" [
    ("verification_exits", [
        test_case "Approve_completion -> Complete" `Quick
          test_approve_completion_completes_verification;
        test_case "Reject_completion -> Blocked" `Quick
          test_reject_completion_blocks_verification;
        test_case "Pause -> Paused" `Quick
          test_pause_pauses_verification;
        test_case "Operator_block -> Blocked" `Quick
          test_operator_block_blocks_verification;
        test_case "Drop preserved" `Quick
          test_drop_still_drops_verification;
        test_case "unrelated actions stay rejected" `Quick
          test_unrelated_action_rejected;
      ]);
  ]
