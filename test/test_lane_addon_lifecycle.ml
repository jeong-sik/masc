(** Lifecycle states and failures are closed types with total codecs. What a
    failure makes the runtime do is decided in one function, [heal], and its
    behaviour is covered where the runtime acts on it, in the reconcile tests. *)
open Alcotest
module L = Masc.Lane_addon_lifecycle
module Types = Masc.Lane_addon_types

let engine_a = L.Docker_engine "engine-a"
let engine_b = L.Docker_engine "engine-b"
let apple = L.Apple_app_root "/Users/example/Library/Application Support/com.apple.container/"

let failures = [
  L.Engine_unreachable "daemon down";
  L.Engine_mismatch { recorded = engine_a; observed = L.Other_engine engine_b };
  L.Engine_mismatch { recorded = apple; observed = L.Unreadable_engine "blank ID" };
  L.Slot_foreign { container_id = String.make 64 'f'; instance = Some "live-sibling"; state_owner = Some "owner" };
  L.Slot_foreign { container_id = String.make 64 'e'; instance = None; state_owner = None };
  L.Slot_predecessor_unremovable { instance_id = "dead-writer"; detail = "removal refused" };
  L.Worker_failed "start refused";
  L.Cleanup_unconfirmed "remove refused";
  L.Persistence_failed "disk full";
  L.Previous_process;
  L.Effect_outcome_unknown "call cancelled";
]

let releases = [
  L.Never_created;
  L.Released { engine = engine_a; container_id = Some (String.make 64 'a') };
  L.Released { engine = apple; container_id = None };
  L.Native_released { installation_id = "browser-work"; instance_id = "released-instance" };
  L.Native_retained { installation_id = "browser-work"; instance_id = "retained-instance" };
]

let states =
  [L.Attached; L.Observing; L.Detaching None;
   L.Detaching (Some { L.cause = L.Worker_failed "start refused"; first = None });
   L.Failed (L.failed L.Previous_process);
   L.Failed { L.cause = L.Cleanup_unconfirmed "remove refused"; first = Some (L.Worker_failed "start refused") }]
  @ List.map (fun release -> L.Detached release) releases
  @ List.map (fun failure -> L.Failed (L.failed failure)) failures

let test_every_state_round_trips () =
  List.iter (fun state ->
    match L.state_of_json (L.state_to_json state) with
    | Ok decoded -> check bool "state survives its own JSON" true (decoded = state)
    | Error message -> failf "state did not decode: %s" message) states

let test_older_and_malformed_shapes_are_errors () =
  let rejected label json =
    check bool label true (Result.is_error (L.state_of_json json)) in
  rejected "a detached state with no release evidence is the older shape"
    (`Assoc ["kind", `String "detached"]);
  rejected "release evidence without an engine"
    (`Assoc ["kind", `String "detached"; "release", `Assoc ["kind", `String "released"; "container_id", `Null]]);
  rejected "release evidence with a blank container"
    (`Assoc ["kind", `String "detached";
             "release", `Assoc ["kind", `String "released"; "engine", L.engine_to_json engine_a;
                                "container_id", `String " "]]);
  rejected "a failed phase with only a message is the older shape"
    (`Assoc ["kind", `String "failed"; "message", `String "cleanup incomplete"]);
  rejected "a failed state needs both causes" (`Assoc ["kind", `String "failed"]);
  rejected "an unknown kind" (`Assoc ["kind", `String "released"]);
  rejected "retained release evidence without its installation"
    (`Assoc ["kind", `String "detached";
             "release", `Assoc ["kind", `String "native_retained"; "instance_id", `String "retained-instance"]]);
  rejected "an unknown failure"
    (`Assoc ["kind", `String "failed"; "failed", `Assoc ["cause", `Assoc ["kind", `String "mystery"]; "first", `Null]]);
  rejected "extra fields are not ignored"
    (`Assoc ["kind", `String "attached"; "extra", `Null]);
  rejected "not an object" (`String "attached")

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

(* The display phase is derived from the state and never read back. Each
   state projects to the phase of the same name. *)
let test_display_phase_follows_the_state () =
  let failed = { L.cause = L.Cleanup_unconfirmed "remove refused"; first = Some (L.Worker_failed "start refused") } in
  check bool "attached" true (L.project L.Attached = Types.Attached);
  check bool "observing" true (L.project L.Observing = Types.Observing);
  check bool "detaching, with or without an earlier failure" true
    (L.project (L.Detaching None) = Types.Detaching && L.project (L.Detaching (Some failed)) = Types.Detaching);
  check bool "detached, whatever the release stands on" true
    (List.for_all (fun release -> L.project (L.Detached release) = Types.Detached) releases);
  List.iter (fun failure ->
    match L.project (L.Failed (L.failed failure)) with
    | Types.Failed _ -> ()
    | Types.Attached | Types.Observing | Types.Detaching | Types.Detached ->
        fail "a failed state projects to a failed phase") failures

let test_engines_are_equal_only_by_identity () =
  check bool "same Docker ID" true (L.engine_equal engine_a (L.Docker_engine "engine-a"));
  check bool "different Docker ID" false (L.engine_equal engine_a engine_b);
  check bool "an Apple root never equals a Docker ID of the same text" false
    (L.engine_equal (L.Docker_engine "x") (L.Apple_app_root "x"));
  List.iter (fun engine ->
    check bool "engine survives its JSON" true (L.engine_of_json (L.engine_to_json engine) = Ok engine))
    [engine_a; apple];
  check bool "blank Docker ID is not an engine" true
    (Result.is_error (L.engine_of_json (`Assoc ["kind", `String "docker"; "id", `String " "])));
  check bool "unknown engine kind is not an engine" true
    (Result.is_error (L.engine_of_json (`Assoc ["kind", `String "podman"; "id", `String "x"])))

let () =
  run "lane_addon_lifecycle" [
    "lifecycle", [
      test_case "every state round-trips" `Quick test_every_state_round_trips;
      test_case "older and malformed shapes are errors" `Quick test_older_and_malformed_shapes_are_errors;
      test_case "a later failure keeps the first different cause" `Quick test_a_later_failure_keeps_the_first_different_cause;
      test_case "the display phase follows the state" `Quick test_display_phase_follows_the_state;
      test_case "engines are equal only by identity" `Quick test_engines_are_equal_only_by_identity;
    ]]
