(** #10411 — pin the [Awaiting_verification] FSM exit transitions.

    Pre-fix [Goal_phase.decide_transition] held only one
    transition out of [Awaiting_verification] — [Drop] →
    [Dropped].  A goal that entered verification (via
    [verifier_policy] firing on [Request_complete]) had no
    automatic path to [Completed] (verification passed) or
    [Blocked] (verification failed); the verifier emitted its
    verdict and the goal stayed pinned, requiring manual
    operator override that bypassed the verification result.

    This made [verifier_policy] effectively unusable — the
    sibling [Awaiting_approval] phase already carried
    [Approve_completion] / [Reject_completion] / [Drop], so the
    asymmetry was unintentional.

    Tests pin:

    1. [Approve_completion] → [Complete] (verifier passed).
    2. [Reject_completion] → [Move_to Blocked] (verifier failed).
    3. [Pause] → [Move_to Paused] (manual hold during
       verification).
    4. [Operator_block] → [Move_to Blocked] (manual block).
    5. [Drop] → [Move_to Dropped] still works (regression).
    6. Invalid actions (e.g. [Resume], [Reopen]) still rejected.
    7. Escapability invariant: every non-terminal phase has at
       least one outgoing transition. *)

open Alcotest

module GP = Masc_mcp.Goal_phase

(* --- helper: short-hand caller for decide_transition ---- *)

let decide ~phase ~action =
  GP.decide_transition ~phase ~action
    ~has_effective_verifier_policy:false
    ~require_completion_approval:false

let outcome_eq a b =
  match a, b with
  | GP.Move_to p1, GP.Move_to p2 -> p1 = p2
  | GP.Open_verification, GP.Open_verification -> true
  | GP.Open_approval, GP.Open_approval -> true
  | GP.Complete, GP.Complete -> true
  | _ -> false

let outcome_to_string = function
  | GP.Move_to p -> "Move_to " ^ GP.to_string p
  | GP.Open_verification -> "Open_verification"
  | GP.Open_approval -> "Open_approval"
  | GP.Complete -> "Complete"

let assert_ok ~msg ~phase ~action expected =
  match decide ~phase ~action with
  | Error e ->
      failf "%s — expected %s, got Error %S" msg
        (outcome_to_string expected) e
  | Ok actual ->
      check bool
        (Printf.sprintf "%s (got %s)" msg (outcome_to_string actual))
        true (outcome_eq expected actual)

let assert_error ~msg ~phase ~action =
  match decide ~phase ~action with
  | Ok actual ->
      failf "%s — expected Error but got Ok %s" msg
        (outcome_to_string actual)
  | Error _ -> ()

(* --- 1-2. verification verdicts ----------------------- *)

let test_approve_completes_goal () =
  assert_ok
    ~msg:"Approve_completion completes the goal"
    ~phase:GP.Awaiting_verification
    ~action:GP.Approve_completion GP.Complete

let test_reject_blocks_goal () =
  assert_ok
    ~msg:"Reject_completion blocks the goal"
    ~phase:GP.Awaiting_verification
    ~action:GP.Reject_completion (GP.Move_to GP.Blocked)

(* --- 3-4. manual escapes ------------------------------ *)

let test_pause_moves_to_paused () =
  assert_ok
    ~msg:"Pause moves to Paused"
    ~phase:GP.Awaiting_verification
    ~action:GP.Pause (GP.Move_to GP.Paused)

let test_operator_block_moves_to_blocked () =
  assert_ok
    ~msg:"Operator_block moves to Blocked"
    ~phase:GP.Awaiting_verification
    ~action:GP.Operator_block (GP.Move_to GP.Blocked)

(* --- 5. existing Drop still works --------------------- *)

let test_drop_still_works () =
  assert_ok
    ~msg:"Drop still moves to Dropped (regression)"
    ~phase:GP.Awaiting_verification
    ~action:GP.Drop (GP.Move_to GP.Dropped)

(* --- 6. invalid actions still rejected ---------------- *)

let test_invalid_actions_rejected () =
  assert_error
    ~msg:"Resume from Awaiting_verification is invalid"
    ~phase:GP.Awaiting_verification ~action:GP.Resume;
  assert_error
    ~msg:"Reopen from Awaiting_verification is invalid"
    ~phase:GP.Awaiting_verification ~action:GP.Reopen;
  assert_error
    ~msg:"Request_complete from Awaiting_verification is invalid"
    ~phase:GP.Awaiting_verification ~action:GP.Request_complete

(* --- 7. escapability invariant ------------------------ *)

(* Every non-terminal phase must have at least one outgoing
   transition — otherwise a goal landing there is dead-locked.
   [Completed] is terminal-but-revisitable via [Reopen] /
   [Drop], so it counts.  No phase should be a sink. *)
let all_phases =
  [ GP.Executing; GP.Awaiting_verification; GP.Awaiting_approval;
    GP.Blocked; GP.Paused; GP.Completed; GP.Dropped ]

let all_actions =
  [ GP.Request_complete; GP.Approve_completion;
    GP.Reject_completion; GP.Pause; GP.Resume; GP.Operator_block;
    GP.Operator_unblock; GP.Drop; GP.Reopen ]

let test_every_phase_has_at_least_one_exit () =
  List.iter
    (fun phase ->
      let any_ok =
        List.exists
          (fun action -> Result.is_ok (decide ~phase ~action))
          all_actions
      in
      check bool
        (Printf.sprintf "phase %s has at least one outgoing transition"
           (GP.to_string phase))
        true any_ok)
    all_phases

let () =
  run "goal_phase_awaiting_verification_10411"
    [
      ( "verification-verdicts",
        [
          test_case "Approve_completion → Complete" `Quick
            test_approve_completes_goal;
          test_case "Reject_completion → Blocked" `Quick
            test_reject_blocks_goal;
        ] );
      ( "manual-escapes",
        [
          test_case "Pause → Paused" `Quick test_pause_moves_to_paused;
          test_case "Operator_block → Blocked" `Quick
            test_operator_block_moves_to_blocked;
        ] );
      ( "regressions",
        [
          test_case "Drop → Dropped still works" `Quick
            test_drop_still_works;
          test_case "invalid actions still rejected" `Quick
            test_invalid_actions_rejected;
        ] );
      ( "escapability",
        [
          test_case "every phase has ≥1 outgoing transition" `Quick
            test_every_phase_has_at_least_one_exit;
        ] );
    ]
