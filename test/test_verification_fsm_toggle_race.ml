(** test_verification_fsm_toggle_race.ml

    Race condition tests for the verification FSM toggle.

    These tests cover scenarios where the verification_enabled flag changes
    between transition steps, potentially leaving tasks in inconsistent states.

    Echo (telemetry/logging keeper) — downstream trace from operator-facing
    "task stuck in awaiting_verification" symptom back to the toggle race.

    Key scenarios:
    1. done → awaiting_verification, then toggle off, then approve → should fail
    2. done → awaiting_verification, concurrent approve while toggle flips
    3. CAS version mismatch during toggle flip
    4. Toggle flip during submit_for_verification
*)

open Masc_test_helpers

(* -------------------------------------------------------------------------- *)
(* Helpers                                                                    *)
(* -------------------------------------------------------------------------- *)

let make_task ?(verification_enabled = true) () =
  let open Masc_domain in
  {
    task_id = "task-race-001";
    title = "Race condition test task";
    description = "Test task for verification FSM toggle race";
    status = Todo;
    priority = 1;
    goal_id = Some "g-race-test";
    claimed_by = None;
    version = 0;
    verification_enabled;
    completion_contract = None;
    created_at = 0L;
    updated_at = 0L;
  }

let with_status task status =
  { task with Masc_domain.status = status }

let with_version task version =
  { task with Masc_domain.version = version }

let with_verification task enabled =
  { task with Masc_domain.verification_enabled = enabled }

(* -------------------------------------------------------------------------- *)
(* Scenario 1: Toggle flips off between submit_for_verification and approve  *)
(*                                                                            *)
(* Symptom (downstream): operator sees task stuck in awaiting_verification.   *)
(* Root cause: verification_enabled changed to false after submit but before  *)
(* approve, so approve returns Verification_disabled.                         *)
(* -------------------------------------------------------------------------- *)

let test_toggle_off_before_approve () =
  let open Masc_domain in
  let task =
    make_task ()
    |> with_status Claimed
    |> with_version 1
  in
  (* Step 1: Agent submits for verification → AwaitingVerification *)
  let after_submit =
    { task with status = Awaiting_verification; version = 2 }
  in
  Alcotest.(check int) "status after submit"
    (Obj.magic after_submit.status) (Obj.magic Awaiting_verification);
  Alcotest.(check int) "version after submit" after_submit.version 2;

  (* Step 2: Toggle flips — verification_enabled = false *)
  let toggled_off = with_verification after_submit false in
  Alcotest.(check bool) "verification disabled" toggled_off.verification_enabled false;

  (* Step 3: Verifier attempts approve → must be rejected
     The lifecycle decide function checks verification_enabled at decision time.
     If disabled, approve from AwaitingVerification returns Error. *)
  let result =
    Coord_task_lifecycle.decide
      ~action:Approve_verification
      ~agent_name:"verifier-1"
      ~task:toggled_off
      ~verification_enabled:false
  in
  (match result with
   | Error (`Verification_disabled _) -> ()
   | Ok _ ->
     Alcotest.fail "approve should be rejected when verification is disabled after toggle"
   | Error e ->
     Alcotest.fail (Printf.sprintf "unexpected error: %s"
       (Coord_task_lifecycle.string_of_rejection e)))

(* -------------------------------------------------------------------------- *)
(* Scenario 2: Task completes without verification when toggle flips off     *)
(*                                                                            *)
(* Symptom (downstream): task appears as Done but was never verified.         *)
(* Expected: when verification_enabled=false, Done_action bypasses verify.    *)
(* -------------------------------------------------------------------------- *)

let test_done_bypasses_verify_when_disabled () =
  let open Masc_domain in
  let task =
    make_task ~verification_enabled:false ()
    |> with_status Claimed
    |> with_version 1
  in
  let result =
    Coord_task_lifecycle.decide
      ~action:Done_action
      ~agent_name:"worker-1"
      ~task
      ~verification_enabled:false
  in
  (match result with
   | Ok { Masc_domain.status = Done; _ } -> ()
   | Ok { Masc_domain.status = s; _ } ->
     Alcotest.fail (Printf.sprintf
       "expected Done but got %s" (Coord_task_lifecycle.string_of_status s))
   | Error e ->
     Alcotest.fail (Printf.sprintf
       "done should succeed when verification disabled: %s"
       (Coord_task_lifecycle.string_of_rejection e)))

(* -------------------------------------------------------------------------- *)
(* Scenario 3: CAS version mismatch — concurrent done and approve            *)
(*                                                                            *)
(* Symptom (downstream): "Invalid task state" error in audit JSONL,           *)
///  stale version in dashboard.                                              *)
(* Root cause: two agents transition the same task with stale version.        *)
(* -------------------------------------------------------------------------- *)

let test_cas_version_mismatch_on_approve () =
  let open Masc_domain in
  let task =
    make_task ()
    |> with_status Awaiting_verification
    |> with_version 3
  in
  (* Verifier reads version 3, but another agent already bumped to 4 *)
  let stale_task = { task with version = 2 } in
  let result =
    Coord_task_lifecycle.decide
      ~action:Approve_verification
      ~agent_name:"verifier-1"
      ~task:stale_task
      ~verification_enabled:true
      ~expected_version:(Some 2)
  in
  (match result with
   | Error (`Version_mismatch _) -> ()
   | Ok _ ->
     Alcotest.fail "CAS guard should reject stale version"
   | Error e ->
     (* Version mismatch is the expected race condition signal *)
     Alcotest.fail (Printf.sprintf
       "expected version_mismatch but got: %s"
       (Coord_task_lifecycle.string_of_rejection e)))

(* -------------------------------------------------------------------------- *)
(* Scenario 4: Toggle flips during submit_for_verification                   *)
(*                                                                            *)
(* Symptom (downstream): task goes to Done instead of AwaitingVerification.  *)
(* Root cause: toggle flips off between the agent's read and the write.      *)
(* -------------------------------------------------------------------------- *)

let test_submit_for_verification_toggle_race () =
  let open Masc_domain in
  (* Agent reads task with verification_enabled=true *)
  let task =
    make_task ()
    |> with_status Claimed
    |> with_version 1
  in
  (* By the time decide runs, toggle has flipped to false *)
  let result =
    Coord_task_lifecycle.decide
      ~action:Done_action
      ~agent_name:"worker-1"
      ~task
      ~verification_enabled:false
  in
  (* When verification is disabled, Done_action goes directly to Done.
     This is the correct behavior — but the operator needs to see this
     in telemetry as "verification bypassed" not just "task completed". *)
  (match result with
   | Ok { Masc_domain.status = Done; _ } -> ()
   | Ok { Masc_domain.status = s; _ } ->
     Alcotest.fail (Printf.sprintf
       "expected Done (verification bypassed) but got %s"
       (Coord_task_lifecycle.string_of_status s))
   | Error e ->
     Alcotest.fail (Printf.sprintf
       "done should succeed with verification disabled: %s"
       (Coord_task_lifecycle.string_of_rejection e)))

(* -------------------------------------------------------------------------- *)
(* Scenario 5: Reject from AwaitingVerification after toggle flip            *)
(*                                                                            *)
(* Symptom (downstream): task returns to In_progress, verifier confused.     *)
(* -------------------------------------------------------------------------- *)

let test_reject_returns_to_in_progress () =
  let open Masc_domain in
  let task =
    make_task ()
    |> with_status Awaiting_verification
    |> with_version 3
    |> with_verification true
  in
  let result =
    Coord_task_lifecycle.decide
      ~action:Reject_verification
      ~agent_name:"verifier-1"
      ~task
      ~verification_enabled:true
  in
  (match result with
   | Ok { Masc_domain.status = In_progress; _ } -> ()
   | Ok { Masc_domain.status = s; _ } ->
     Alcotest.fail (Printf.sprintf
       "expected In_progress after reject but got %s"
       (Coord_task_lifecycle.string_of_status s))
   | Error e ->
     Alcotest.fail (Printf.sprintf
       "reject should succeed: %s"
       (Coord_task_lifecycle.string_of_rejection e)))

(* -------------------------------------------------------------------------- *)
(* Scenario 6: Double-approve race                                           *)
(*                                                                            *)
(* Symptom (downstream): second approve on already-Done task errors.          *)
(* -------------------------------------------------------------------------- *)

let test_double_approve_race () =
  let open Masc_domain in
  let task =
    make_task ()
    |> with_status Done
    |> with_version 4
  in
  let result =
    Coord_task_lifecycle.decide
      ~action:Approve_verification
      ~agent_name:"verifier-2"
      ~task
      ~verification_enabled:true
  in
  (match result with
   | Error (`Invalid_transition _) -> ()
   | Ok _ ->
     Alcotest.fail "approve on already-Done task should be rejected"
   | Error e ->
     Alcotest.fail (Printf.sprintf
       "expected invalid_transition but got: %s"
       (Coord_task_lifecycle.string_of_rejection e)))

(* -------------------------------------------------------------------------- *)
(* Test suite                                                                 *)
(* -------------------------------------------------------------------------- *)

let () =
  Alcotest.run "verification_fsm_toggle_race" [
    "toggle_race", [
      Alcotest.test_case "toggle off before approve blocks approval"
        `Quick test_toggle_off_before_approve;
      Alcotest.test_case "done bypasses verify when disabled"
        `Quick test_done_bypasses_verify_when_disabled;
      Alcotest.test_case "CAS version mismatch on approve"
        `Quick test_cas_version_mismatch_on_approve;
      Alcotest.test_case "submit_for_verification toggle race"
        `Quick test_submit_for_verification_toggle_race;
      Alcotest.test_case "reject returns to in_progress"
        `Quick test_reject_returns_to_in_progress;
      Alcotest.test_case "double approve race"
        `Quick test_double_approve_race;
    ]
  ]