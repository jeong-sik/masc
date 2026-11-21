(* What ends a counted read (RFC tui-one-screen-grammar §8). A launcher that
   counts a read gets three functions from [track_reading]: one for a job that
   never ran, one for the result, one for the job's release. Checked are the
   decisions only: which of them ends the read, with what outcome, and that
   the first end wins. The outcome is read through the slot the way the main
   loop reads it: a success keeps the slot on for one more bar, a failure
   turns it off at once. No screen is drawn and no server is called. *)

open Alcotest
module T = Masc_tui_types
module Wake = Masc_tui_wake
module Job = Masc_tui_workspace_job
module Admission = Masc_tui_transport.Workspace_admission

let drawn =
  testable
    (fun formatter -> function
       | T.Drawn_changed -> Format.pp_print_string formatter "changed"
       | T.Drawn_unchanged -> Format.pp_print_string formatter "unchanged")
    ( = )

let at start seconds = Wake.Mono.after start seconds

let draw_frame state =
  T.begin_drawn_reads ();
  T.note_drawn_reads state

(* A read of the open screen began and is on the wire past the bar. Returned
   are the three ends and what the launcher's own callbacks were given, so a
   test sees them run. *)
let launch () =
  let state = T.create_state ~workspace:"reading-track" ~port:8935 () in
  draw_frame state;
  let start = Wake.Mono.now () in
  let not_run_calls = ref 0 in
  let delivered = ref [] in
  let on_not_run, deliver, released =
    Admission.track_reading state
      ~on_not_run:(fun () -> incr not_run_calls)
      ~deliver:(fun (result : (unit, string) result) ->
        delivered := result :: !delivered)
  in
  check drawn "the read passes the bar" T.Drawn_changed
    (T.step_reading_slot state ~now:(at start 1.5));
  draw_frame state;
  (state, start, on_not_run, deliver, released, not_run_calls, delivered)

(* A failure turns the slot off at once; no wait follows. *)
let expect_failure state start =
  check drawn "a failure turns the slot off at once" T.Drawn_changed
    (T.step_reading_slot state ~now:(at start 2.0));
  draw_frame state;
  check drawn "and no wait follows" T.Drawn_unchanged
    (T.step_reading_slot state ~now:(at start 3.5))

(* A success freezes the length and keeps the slot on for one more bar. *)
let expect_success state start =
  check drawn "a success freezes the length" T.Drawn_changed
    (T.step_reading_slot state ~now:(at start 2.0));
  draw_frame state;
  check drawn "the slot stays on inside the bar" T.Drawn_unchanged
    (T.step_reading_slot state ~now:(at start 2.5));
  check drawn "and goes off after it" T.Drawn_changed
    (T.step_reading_slot state ~now:(at start 3.5))

let test_a_result_that_succeeded_ends_the_read_as_a_success () =
  let state, start, _, deliver, _, _, delivered = launch () in
  deliver (Ok ());
  expect_success state start;
  check int "the launcher's deliver ran once" 1 (List.length !delivered)

let test_a_result_that_failed_ends_the_read_as_a_failure () =
  let state, start, _, deliver, _, _, delivered = launch () in
  deliver (Error "unreachable");
  expect_failure state start;
  check int "the launcher's deliver ran once" 1 (List.length !delivered)

let test_a_job_that_never_ran_ends_the_read_as_a_failure () =
  let state, start, on_not_run, _, _, not_run_calls, _ = launch () in
  on_not_run ();
  expect_failure state start;
  check int "the launcher's on_not_run ran once" 1 !not_run_calls

let test_a_released_job_ends_the_read_as_a_failure () =
  let state, start, _, _, released, _, _ = launch () in
  released Job.Registration_released;
  expect_failure state start

(* A cancellation is only asked for. The job still ends by one of the other
   ends, so the read is not over yet. *)
let test_a_cancellation_request_does_not_end_the_read () =
  let state, start, _, deliver, released, _, _ = launch () in
  released Job.Cancellation_requested;
  check drawn "the read is still on the wire" T.Drawn_unchanged
    (T.step_reading_slot state ~now:(at start 2.5));
  deliver (Ok ());
  check drawn "its result ends it" T.Drawn_changed
    (T.step_reading_slot state ~now:(at start 3.0))

(* The first end counts. A release first makes the read a failure that a
   later result cannot turn into a success; a result first makes it a success
   that a later release cannot turn into a failure that cancels the wait. *)
let test_the_first_end_wins () =
  let state, start, _, deliver, released, _, _ = launch () in
  released Job.Registration_released;
  deliver (Ok ());
  expect_failure state start;
  let state, start, _, deliver, released, _, _ = launch () in
  deliver (Ok ());
  released Job.Registration_released;
  expect_success state start

let () =
  run "tui_reading_track"
    [ ( "ends of a counted read",
        [ test_case "a result that succeeded" `Quick
            test_a_result_that_succeeded_ends_the_read_as_a_success;
          test_case "a result that failed" `Quick
            test_a_result_that_failed_ends_the_read_as_a_failure;
          test_case "a job that never ran" `Quick
            test_a_job_that_never_ran_ends_the_read_as_a_failure;
          test_case "a released job" `Quick
            test_a_released_job_ends_the_read_as_a_failure;
          test_case "a cancellation request" `Quick
            test_a_cancellation_request_does_not_end_the_read;
          test_case "the first end wins" `Quick test_the_first_end_wins ] ) ]
