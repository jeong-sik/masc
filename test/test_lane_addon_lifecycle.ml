(** Lifecycle states and failures are closed types with total codecs. The
    retry decision is one function that names every failure. *)
open Alcotest
module L = Masc.Lane_addon_lifecycle
module Types = Masc.Lane_addon_types

let failures = [
  L.Engine_unreachable "daemon down";
  L.Worker_failed "start refused";
  L.Cleanup_unconfirmed "remove refused";
  L.Persistence_failed "disk full";
  L.Previous_process;
  L.Effect_outcome_unknown "call cancelled";
]

let states =
  [L.Attached; L.Observing; L.Detached; L.Detaching None;
   L.Detaching (Some { L.cause = L.Worker_failed "start refused"; first = None });
   L.Failed (L.failed L.Previous_process);
   L.Failed { L.cause = L.Cleanup_unconfirmed "remove refused"; first = Some (L.Worker_failed "start refused") }]
  @ List.map (fun failure -> L.Failed (L.failed failure)) failures

let test_every_state_round_trips () =
  List.iter (fun state ->
    match L.state_of_json (L.state_to_json state) with
    | Ok decoded -> check bool "state survives its own JSON" true (decoded = state)
    | Error message -> failf "state did not decode: %s" message) states

let test_older_and_malformed_shapes_are_errors () =
  let rejected label json =
    check bool label true (Result.is_error (L.state_of_json json)) in
  rejected "a failed phase with only a message is the older shape"
    (`Assoc ["kind", `String "failed"; "message", `String "cleanup incomplete"]);
  rejected "a failed state needs both causes" (`Assoc ["kind", `String "failed"]);
  rejected "an unknown kind" (`Assoc ["kind", `String "released"]);
  rejected "an unknown failure"
    (`Assoc ["kind", `String "failed"; "failed", `Assoc ["cause", `Assoc ["kind", `String "mystery"]; "first", `Null]]);
  rejected "extra fields are not ignored"
    (`Assoc ["kind", `String "attached"; "extra", `Null]);
  rejected "not an object" (`String "attached")

(* Every failure is named with the decision it gets. Adding a failure breaks
   this table at compile time in [L.heal] and here at review time. *)
let test_retry_is_decided_per_failure () =
  let expected = function
    | L.Engine_unreachable _ -> L.Wait_until L.Engine_reachable
    | L.Worker_failed _ | L.Cleanup_unconfirmed _ | L.Persistence_failed _
    | L.Previous_process | L.Effect_outcome_unknown _ -> L.Retry in
  List.iter (fun failure ->
    check bool (L.failure_to_string failure) true (L.heal failure = expected failure)) failures

let test_a_later_failure_keeps_the_first_different_cause () =
  let start = L.Worker_failed "start refused" in
  let cleanup = L.Cleanup_unconfirmed "remove refused" in
  let after_start = L.failed start in
  let after_cleanup = L.fail_again after_start cleanup in
  check bool "the cleanup is the current cause" true (after_cleanup.cause = cleanup);
  check bool "the start failure is kept" true (after_cleanup.first = Some start);
  let again = L.fail_again after_cleanup (L.Cleanup_unconfirmed "remove refused again") in
  check bool "a retry of the same step keeps the original first cause" true (again.first = Some start);
  let repeated = L.fail_again after_start start in
  check bool "the same cause twice records no first cause" true (repeated.first = None)

let test_display_phase_names_every_cause () =
  let failed = { L.cause = L.Cleanup_unconfirmed "remove refused"; first = Some (L.Worker_failed "start refused") } in
  match L.project (L.Failed failed) with
  | Types.Failed message ->
      check bool "current cause shown" true (String_util.contains_substring message "remove refused");
      check bool "first cause shown" true (String_util.contains_substring message "start refused")
  | Types.Attached | Types.Observing | Types.Detaching | Types.Detached -> fail "a failed state projects to a failed phase"

let () =
  run "lane_addon_lifecycle" [
    "lifecycle", [
      test_case "every state round-trips" `Quick test_every_state_round_trips;
      test_case "older and malformed shapes are errors" `Quick test_older_and_malformed_shapes_are_errors;
      test_case "retry is decided per failure" `Quick test_retry_is_decided_per_failure;
      test_case "a later failure keeps the first different cause" `Quick test_a_later_failure_keeps_the_first_different_cause;
      test_case "the display phase names every cause" `Quick test_display_phase_names_every_cause;
    ]]
