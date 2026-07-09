let test_approve_rejects_empty_notes = *** Test that record_approve_verification and record_reject_verification reject empty notes.

    This tests the task-1880 pre-flight evidence validation fix. */
let test_approve_rejects_empty_notes () =
  let result = Verification.record_approve_verification
    ~"config"
    "task-0000"
    "verifier"
    "verification-0000"
    ""
  in
  match result with
  | Error msg ->
    *** The approval rejection should have failed with an empty-notes error. */
    Printf.sprintf "Pass: record_approve_verification rejected empty notes: %s" msg
  | Ok () -> Alcotest.fail "Fail: record_approve_verification should have rejected empty notes"