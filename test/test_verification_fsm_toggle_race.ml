(** test_verification_fsm_toggle_race -- Race condition tests for verification FSM
    toggle during done→approve transition path.

    When [MASC_VERIFICATION_FSM_ENABLED] changes between a [done] action and a
    subsequent [approve] action, the task can land in a state that is unreachable
    or unrecoverable under the new toggle setting.  These tests pin the expected
    behaviour of [Coord_task_lifecycle.decide] under mid-flight toggle changes.

    Scenarios covered:
    1. done under verification_on → approve under verification_off
    2. done under verification_off → approve under verification_on
    3. done under verification_on → reject under verification_off
    4. done under verification_off → submit_for_verification under verification_on
    5. Toggle flip during InProgress: done with toggle A, then approve with toggle B
    6. Self-approval under toggle flip: owner done, then owner approve with toggle on
    7. Double toggle: done(on) → toggle off → toggle on → approve(on) idempotency
    8. Cancel from AwaitingVerification after toggle off
    9. Release from AwaitingVerification after toggle off *)

module L = Coord_task_lifecycle
module D = Masc_domain

let owner = "alice"
let other = "bob"
let now = "2026-05-22T18:00:00Z"

(* ── Status constructors ── *)

let mk_in_progress assignee =
  D.InProgress { assignee; started_at = now }
;;

let mk_awaiting assignee =
  D.AwaitingVerification
    { assignee; submitted_at = now; verification_id = "v1"; deadline = None }
;;

let mk_done assignee =
  D.Done { assignee; completed_at = now; notes = None }
;;

(* ── Helpers ── *)

let is_self_agent name _ = String.equal name
let owner_pred = is_self_agent owner
let other_pred = is_self_agent other
let always_false _ = false

let decide ~verification_enabled ~action ~task_status ~agent_name ~same_agent =
  L.decide
    ~verification_enabled
    ~verification_timeout_seconds:300.0
    ~new_verification_id:(fun () -> "v-toggled")
    ~same_agent
    ~agent_name
    ~task_id:"t1"
    ~task_status
    ~action
    ~now
    ~force:false
    ~notes:""
    ~reason:""

(* Assert the result is Ok and extract the new status *)
let assert_ok ~label result =
  match result with
  | Ok decision -> decision.new_status
  | Error e ->
    Printf.printf "FAIL [%s]: expected Ok, got Error (%s)\n%!" label
      (match e with
       | L.Self_approval -> "Self_approval"
       | L.Self_rejection -> "Self_rejection"
       | L.Verification_disabled -> "Verification_disabled"
       | L.Invalid_transition -> "Invalid_transition");
    exit 1

(* Assert the result is Error with a specific invalid variant *)
let assert_error ~label ~expected result =
  match result with
  | Ok _ ->
    Printf.printf "FAIL [%s]: expected Error (%s), got Ok\n%!" label
      (match expected with
       | L.Self_approval -> "Self_approval"
       | L.Self_rejection -> "Self_rejection"
       | L.Verification_disabled -> "Verification_disabled"
       | L.Invalid_transition -> "Invalid_transition");
    exit 1
  | Error e when e = expected -> ()
  | Error e ->
    Printf.printf "FAIL [%s]: expected Error (%s), got Error (%s)\n%!" label
      (match expected with
       | L.Self_approval -> "Self_approval"
       | L.Self_rejection -> "Self_rejection"
       | L.Verification_disabled -> "Verification_disabled"
       | L.Invalid_transition -> "Invalid_transition")
      (match e with
       | L.Self_approval -> "Self_approval"
       | L.Self_rejection -> "Self_rejection"
       | L.Verification_disabled -> "Verification_disabled"
       | L.Invalid_transition -> "Invalid_transition");
    exit 1

(* ══════════════════════════════════════════════════════════════════════════ *)
(* Scenario 1: done(on) → AwaitingVerification, then approve(off)           *)
(*                                                                           *)
(* Task is submitted for verification with FSM on. Before the verifier can   *)
(* approve, the admin toggles FSM off. Approve should return                *)
(* Verification_disabled because the verification pathway is now closed.     *)
(* ══════════════════════════════════════════════════════════════════════════ *)
let test_done_on_approve_off () =
  let status = mk_in_progress owner in
  (* Step 1: done with verification ON → AwaitingVerification *)
  let after_done =
    assert_ok ~label:"s1-done"
      (decide ~verification_enabled:true
              ~action:D.Done_action
              ~task_status:status
              ~agent_name:owner
              ~same_agent:owner_pred)
  in
  let verification_id =
    match after_done with
    | D.AwaitingVerification { verification_id; _ } -> verification_id
    | _ ->
      Printf.printf "FAIL [s1]: after done(on), expected AwaitingVerification, got %s\n%!"
        (D.status_to_string after_done);
      exit 1
  in
  (* Step 2: approve with verification OFF → should be blocked *)
  assert_error ~label:"s1-approve-off"
    ~expected:L.Verification_disabled
    (decide ~verification_enabled:false
            ~action:D.Approve_verification
            ~task_status:after_done
            ~agent_name:other
            ~same_agent:other_pred);
  (* Verify: the task is still in AwaitingVerification — stuck but consistent *)
  ignore verification_id
;;

(* ══════════════════════════════════════════════════════════════════════════ *)
(* Scenario 2: done(off) → Done, then approve(on) on a Done task            *)
(*                                                                           *)
(* Task was completed directly with FSM off. Then FSM is toggled on. Someone *)
(* tries to approve the already-Done task. Should be Invalid_transition.     *)
(* ══════════════════════════════════════════════════════════════════════════ *)
let test_done_off_approve_on () =
  let status = mk_in_progress owner in
  (* Step 1: done with verification OFF → Done *)
  let after_done =
    assert_ok ~label:"s2-done"
      (decide ~verification_enabled:false
              ~action:D.Done_action
              ~task_status:status
              ~agent_name:owner
              ~same_agent:owner_pred)
  in
  (match after_done with
   | D.Done _ -> ()
   | _ ->
     Printf.printf "FAIL [s2]: after done(off), expected Done, got %s\n%!"
       (D.status_to_string after_done);
     exit 1);
  (* Step 2: approve with verification ON → Invalid_transition from Done *)
  assert_error ~label:"s2-approve-on"
    ~expected:L.Invalid_transition
    (decide ~verification_enabled:true
            ~action:D.Approve_verification
            ~task_status:after_done
            ~agent_name:other
            ~same_agent:other_pred)
;;

(* ══════════════════════════════════════════════════════════════════════════ *)
(* Scenario 3: done(on) → AwaitingVerification, then reject(off)            *)
(*                                                                           *)
(* Same as scenario 1 but with reject instead of approve. Reject should also *)
(* be blocked when verification is disabled mid-flight.                      *)
(* ══════════════════════════════════════════════════════════════════════════ *)
let test_done_on_reject_off () =
  let status = mk_in_progress owner in
  let after_done =
    assert_ok ~label:"s3-done"
      (decide ~verification_enabled:true
              ~action:D.Done_action
              ~task_status:status
              ~agent_name:owner
              ~same_agent:owner_pred)
  in
  (match after_done with
   | D.AwaitingVerification _ -> ()
   | _ ->
     Printf.printf "FAIL [s3]: after done(on), expected AwaitingVerification\n%!";
     exit 1);
  (* Reject with verification OFF *)
  assert_error ~label:"s3-reject-off"
    ~expected:L.Verification_disabled
    (decide ~verification_enabled:false
            ~action:D.Reject_verification
            ~task_status:after_done
            ~agent_name:other
            ~same_agent:other_pred)
;;

(* ══════════════════════════════════════════════════════════════════════════ *)
(* Scenario 4: done(off) → Done, then submit_for_verification(on) on Done   *)
(*                                                                           *)
(* Task completed directly. FSM toggled on. Can someone submit for           *)
(* verification after the fact? No — Invalid_transition from Done.           *)
(* ══════════════════════════════════════════════════════════════════════════ *)
let test_done_off_submit_verification_on () =
  let status = mk_in_progress owner in
  let after_done =
    assert_ok ~label:"s4-done"
      (decide ~verification_enabled:false
              ~action:D.Done_action
              ~task_status:status
              ~agent_name:owner
              ~same_agent:owner_pred)
  in
  assert_error ~label:"s4-submit-on"
    ~expected:L.Invalid_transition
    (decide ~verification_enabled:true
            ~action:D.Submit_for_verification
            ~task_status:after_done
            ~agent_name:owner
            ~same_agent:owner_pred)
;;

(* ══════════════════════════════════════════════════════════════════════════ *)
(* Scenario 5: Rapid toggle during InProgress                               *)
(*                                                                           *)
(* done(on) → AwaitingVerification → done(on) again (idempotent?)            *)
(* Then toggle off and try done from AwaitingVerification.                   *)
(* ══════════════════════════════════════════════════════════════════════════ *)
let test_rapid_toggle_in_progress () =
  let status = mk_in_progress owner in
  (* done with ON → AwaitingVerification *)
  let after_done_on =
    assert_ok ~label:"s5-done-on"
      (decide ~verification_enabled:true
              ~action:D.Done_action
              ~task_status:status
              ~agent_name:owner
              ~same_agent:owner_pred)
  in
  (* done again with ON from AwaitingVerification → Invalid_transition *)
  assert_error ~label:"s5-done-on-from-awaiting"
    ~expected:L.Invalid_transition
    (decide ~verification_enabled:true
            ~action:D.Done_action
            ~task_status:after_done_on
            ~agent_name:owner
            ~same_agent:owner_pred);
  (* done with OFF from AwaitingVerification → still Invalid_transition *)
  assert_error ~label:"s5-done-off-from-awaiting"
    ~expected:L.Invalid_transition
    (decide ~verification_enabled:false
            ~action:D.Done_action
            ~task_status:after_done_on
            ~agent_name:owner
            ~same_agent:owner_pred)
;;

(* ══════════════════════════════════════════════════════════════════════════ *)
(* Scenario 6: Self-approval under toggle: owner done(on), owner approve    *)
(*                                                                           *)
(* Even with verification enabled, the same agent who submitted should not   *)
(* be able to approve their own work. Self_approval error regardless of      *)
(* toggle state during approval.                                             *)
(* ══════════════════════════════════════════════════════════════════════════ *)
let test_self_approval_toggle () =
  let status = mk_in_progress owner in
  let after_done =
    assert_ok ~label:"s6-done"
      (decide ~verification_enabled:true
              ~action:D.Done_action
              ~task_status:status
              ~agent_name:owner
              ~same_agent:owner_pred)
  in
  (* Owner tries to approve their own work *)
  assert_error ~label:"s6-self-approve"
    ~expected:L.Self_approval
    (decide ~verification_enabled:true
            ~action:D.Approve_verification
            ~task_status:after_done
            ~agent_name:owner
            ~same_agent:owner_pred);
  (* Owner self-approve also blocked when same_agent returns true *)
  assert_error ~label:"s6-self-approve-true"
    ~expected:L.Self_approval
    (decide ~verification_enabled:true
            ~action:D.Approve_verification
            ~task_status:after_done
            ~agent_name:owner
            ~same_agent:(fun _ -> true))
;;

(* ══════════════════════════════════════════════════════════════════════════ *)
(* Scenario 7: Double toggle — done(on) → off → on → approve(on)           *)
(*                                                                           *)
(* Toggle goes on→off→on during the lifecycle. After on→off blocks approve,  *)
(* toggling back on should restore the approve pathway. The task is still in *)
(* AwaitingVerification and cross-agent approve should succeed.              *)
(* ══════════════════════════════════════════════════════════════════════════ *)
let test_double_toggle_approve () =
  let status = mk_in_progress owner in
  let after_done =
    assert_ok ~label:"s7-done"
      (decide ~verification_enabled:true
              ~action:D.Done_action
              ~task_status:status
              ~agent_name:owner
              ~same_agent:owner_pred)
  in
  (* Toggle OFF: approve blocked *)
  assert_error ~label:"s7-approve-off"
    ~expected:L.Verification_disabled
    (decide ~verification_enabled:false
            ~action:D.Approve_verification
            ~task_status:after_done
            ~agent_name:other
            ~same_agent:other_pred);
  (* Toggle ON again: approve succeeds *)
  let after_approve =
    assert_ok ~label:"s7-approve-on"
      (decide ~verification_enabled:true
              ~action:D.Approve_verification
              ~task_status:after_done
              ~agent_name:other
              ~same_agent:other_pred)
  in
  (match after_approve with
   | D.Done _ -> ()
   | _ ->
     Printf.printf "FAIL [s7]: after approve(on), expected Done, got %s\n%!"
       (D.status_to_string after_approve);
     exit 1)
;;

(* ══════════════════════════════════════════════════════════════════════════ *)
(* Scenario 8: Cancel from AwaitingVerification after toggle off            *)
(*                                                                           *)
(* Task stuck in AwaitingVerification after toggle off. Cancel should still  *)
(* work as an escape hatch regardless of verification toggle state.          *)
(* ══════════════════════════════════════════════════════════════════════════ *)
let test_cancel_after_toggle_off () =
  let status = mk_in_progress owner in
  let after_done =
    assert_ok ~label:"s8-done"
      (decide ~verification_enabled:true
              ~action:D.Done_action
              ~task_status:status
              ~agent_name:owner
              ~same_agent:owner_pred)
  in
  (* Cancel with verification OFF *)
  let after_cancel =
    assert_ok ~label:"s8-cancel-off"
      (decide ~verification_enabled:false
              ~action:D.Cancel
              ~task_status:after_done
              ~agent_name:owner
              ~same_agent:owner_pred)
  in
  (match after_cancel with
   | D.Cancelled _ -> ()
   | _ ->
     Printf.printf "FAIL [s8]: after cancel from AwaitingVerification, expected Cancelled, got %s\n%!"
       (D.status_to_string after_cancel);
     exit 1)
;;

(* ══════════════════════════════════════════════════════════════════════════ *)
(* Scenario 9: Release from AwaitingVerification after toggle off           *)
(*                                                                           *)
(* Task stuck in AwaitingVerification after toggle off. Release should       *)
(* return to the backlog (Todo) as an escape hatch.                          *)
(* ══════════════════════════════════════════════════════════════════════════ *)
let test_release_after_toggle_off () =
  let status = mk_in_progress owner in
  let after_done =
    assert_ok ~label:"s9-done"
      (decide ~verification_enabled:true
              ~action:D.Done_action
              ~task_status:status
              ~agent_name:owner
              ~same_agent:owner_pred)
  in
  (* Release with verification OFF *)
  let after_release =
    assert_ok ~label:"s9-release-off"
      (decide ~verification_enabled:false
              ~action:D.Release
              ~task_status:after_done
              ~agent_name:owner
              ~same_agent:owner_pred)
  in
  (match after_release with
   | D.Todo -> ()
   | _ ->
     Printf.printf "FAIL [s9]: after release from AwaitingVerification, expected Todo, got %s\n%!"
       (D.status_to_string after_release);
     exit 1)
;;

(* ══════════════════════════════════════════════════════════════════════════ *)
(* Scenario 10: submit_pr_evidence bypass when toggle flips                 *)
(*                                                                           *)
(* submit_pr_evidence goes directly to AwaitingVerification from any status  *)
(* (except Cancelled). Verify it works regardless of toggle state during the *)
(* done step.                                                                *)
(* ══════════════════════════════════════════════════════════════════════════ *)
let test_submit_pr_evidence_toggle () =
  let status = mk_in_progress owner in
  (* done with verification OFF → Done *)
  let after_done =
    assert_ok ~label:"s10-done-off"
      (decide ~verification_enabled:false
              ~action:D.Done_action
              ~task_status:status
              ~agent_name:owner
              ~same_agent:owner_pred)
  in
  (* submit_pr_evidence with verification ON from Done → should go to AwaitingVerification *)
  let after_spe =
    assert_ok ~label:"s10-spe-on-from-done"
      (decide ~verification_enabled:true
              ~action:D.Submit_pr_evidence
              ~task_status:after_done
              ~agent_name:owner
              ~same_agent:owner_pred)
  in
  (match after_spe with
   | D.AwaitingVerification _ -> ()
   | _ ->
     Printf.printf "FAIL [s10]: after submit_pr_evidence, expected AwaitingVerification, got %s\n%!"
       (D.status_to_string after_spe);
     exit 1)
;;

(* ══════════════════════════════════════════════════════════════════════════ *)
(* Scenario 11: Reject under toggle flip returns to InProgress              *)
(*                                                                           *)
(* After done(on) → AwaitingVerification, a cross-agent reject with          *)
(* verification ON should return InProgress. Then verify the task can be     *)
(* re-done with verification OFF this time.                                  *)
(* ══════════════════════════════════════════════════════════════════════════ *)
let test_reject_then_redone_toggle () =
  let status = mk_in_progress owner in
  let after_done =
    assert_ok ~label:"s11-done-on"
      (decide ~verification_enabled:true
              ~action:D.Done_action
              ~task_status:status
              ~agent_name:owner
              ~same_agent:owner_pred)
  in
  (* Cross-agent reject with verification ON *)
  let after_reject =
    assert_ok ~label:"s11-reject-on"
      (decide ~verification_enabled:true
              ~action:D.Reject_verification
              ~task_status:after_done
              ~agent_name:other
              ~same_agent:other_pred)
  in
  (match after_reject with
   | D.InProgress _ -> ()
   | _ ->
     Printf.printf "FAIL [s11]: after reject, expected InProgress, got %s\n%!"
       (D.status_to_string after_reject);
     exit 1);
  (* Re-done with verification OFF → Done directly *)
  let after_redone =
    assert_ok ~label:"s11-redone-off"
      (decide ~verification_enabled:false
              ~action:D.Done_action
              ~task_status:after_reject
              ~agent_name:owner
              ~same_agent:owner_pred)
  in
  (match after_redone with
   | D.Done _ -> ()
   | _ ->
     Printf.printf "FAIL [s11]: after redone(off), expected Done, got %s\n%!"
       (D.status_to_string after_redone);
     exit 1)
;;

(* ══════════════════════════════════════════════════════════════════════════ *)
(* Scenario 12: valid_next_actions consistency under toggle                  *)
(*                                                                           *)
(* [valid_next_actions] should reflect the current toggle state, not the     *)
(* state under which the task entered AwaitingVerification.                  *)
(* ══════════════════════════════════════════════════════════════════════════ *)
let test_valid_next_actions_toggle_consistency () =
  let status = mk_in_progress owner in
  let after_done =
    assert_ok ~label:"s12-done"
      (decide ~verification_enabled:true
              ~action:D.Done_action
              ~task_status:status
              ~agent_name:owner
              ~same_agent:owner_pred)
  in
  (* With verification ON: approve and reject should be valid for other agent *)
  let actions_on =
    L.valid_next_actions
      ~verification_enabled:true
      ~same_agent:false
      ~force:false
      ~task_status:after_done
  in
  let has_approve_on = List.mem D.Approve_verification actions_on in
  let has_reject_on = List.mem D.Reject_verification actions_on in
  if not has_approve_on then (
    Printf.printf "FAIL [s12]: approve missing from valid_next_actions with verification ON\n%!";
    exit 1);
  if not has_reject_on then (
    Printf.printf "FAIL [s12]: reject missing from valid_next_actions with verification ON\n%!";
    exit 1);
  (* With verification OFF: approve and reject should NOT be valid *)
  let actions_off =
    L.valid_next_actions
      ~verification_enabled:false
      ~same_agent:false
      ~force:false
      ~task_status:after_done
  in
  let has_approve_off = List.mem D.Approve_verification actions_off in
  let has_reject_off = List.mem D.Reject_verification actions_off in
  if has_approve_off then (
    Printf.printf "FAIL [s12]: approve present in valid_next_actions with verification OFF\n%!";
    exit 1);
  if has_reject_off then (
    Printf.printf "FAIL [s12]: reject present in valid_next_actions with verification OFF\n%!";
    exit 1);
  (* Cancel and Release should always be valid escape hatches *)
  let has_cancel = List.mem D.Cancel actions_off in
  let has_release = List.mem D.Release actions_off in
  if not has_cancel then (
    Printf.printf "FAIL [s12]: cancel missing from valid_next_actions with verification OFF\n%!";
    exit 1);
  if not has_release then (
    Printf.printf "FAIL [s12]: release missing from valid_next_actions with verification OFF\n%!";
    exit 1)
;;

(* ── Test runner ── *)

let tests =
  [ ("done(on)->approve(off): blocked by Verification_disabled", `Quick, test_done_on_approve_off)
  ; ("done(off)->approve(on): Invalid_transition from Done", `Quick, test_done_off_approve_on)
  ; ("done(on)->reject(off): blocked by Verification_disabled", `Quick, test_done_on_reject_off)
  ; ("done(off)->submit_verification(on): Invalid_transition from Done", `Quick, test_done_off_submit_verification_on)
  ; ("rapid toggle during InProgress: done stuck from AwaitingVerification", `Quick, test_rapid_toggle_in_progress)
  ; ("self-approval under toggle: always blocked", `Quick, test_self_approval_toggle)
  ; ("double toggle: on->off->on approve restores pathway", `Quick, test_double_toggle_approve)
  ; ("cancel from AwaitingVerification after toggle off", `Quick, test_cancel_after_toggle_off)
  ; ("release from AwaitingVerification after toggle off", `Quick, test_release_after_toggle_off)
  ; ("submit_pr_evidence bypass across toggle flip", `Quick, test_submit_pr_evidence_toggle)
  ; ("reject then redone with toggle flip", `Quick, test_reject_then_redone_toggle)
  ; ("valid_next_actions consistency under toggle flip", `Quick, test_valid_next_actions_toggle_consistency)
  ]
;;

let () =
  let suite = [("verification FSM toggle race conditions", tests)] in
  Alcotest.test suite
;;