(** A deadline must not be movable by the wall clock, and must not be
    confusable with one.

    The property that matters -- an NTP step does not retire a deadline --
    is not tested here, and cannot be cheaply: stepping the clock needs
    privileges and would move it for everything else on the machine. Nor can
    it be shown indirectly. Both clocks answer [remaining_seconds] with the
    same span, so a test written against that passes on either -- the first
    version of this file had one, and swapping the implementation back to
    [Unix.gettimeofday] left it green.

    Reading a monotonic source is therefore a choice checked by reading the
    module, not by a case below. What these cover is the arithmetic around
    it, including the edges, and the type carries the rest: a wall-clock
    instant no longer compiles where a deadline goes. *)

open Alcotest

module Deadline = Monotonic_deadline

let test_a_fresh_deadline_has_its_span_left () =
  let d = Deadline.after ~seconds:5. in
  let left = Deadline.remaining_seconds d in
  check bool "close to the span asked for" true (left > 4.9 && left <= 5.);
  check bool "not passed" false (Deadline.passed d)
;;

let test_a_zero_deadline_is_already_passed () =
  List.iter
    (fun seconds ->
      let d = Deadline.after ~seconds in
      check bool
        (Printf.sprintf "%.1fs is passed" seconds)
        true (Deadline.passed d);
      (* Never negative: this value is handed to select/poll, which reads a
         negative timeout as "block forever" -- the opposite of expired. *)
      check (float 0.)
        (Printf.sprintf "%.1fs has no time left" seconds)
        0.
        (Deadline.remaining_seconds d))
    [ 0.; -1.; -3600. ]
;;

let test_remaining_falls_as_time_passes () =
  let d = Deadline.after ~seconds:1. in
  let first = Deadline.remaining_seconds d in
  Unix.sleepf 0.05;
  let second = Deadline.remaining_seconds d in
  check bool "the second reading is smaller" true (second < first);
  check bool "and both are inside the span" true (second > 0. && first <= 1.)
;;

(* A span far enough out to exhaust Int64 nanoseconds still answers as the
   far future. It does so through a wraparound rather than by being guarded
   against one, which is a thing worth knowing: the arithmetic wraps twice
   and lands on the same answer, so a saturating add changes nothing here and
   this case would pass with or without it. It pins the interface's answer,
   not an implementation choice, and no caller passes such a span anyway --
   these deadlines are seconds and milliseconds. *)
let test_a_far_future_span_does_not_wrap () =
  List.iter
    (fun seconds ->
      let d = Deadline.after ~seconds in
      check bool
        (Printf.sprintf "%g s is not already passed" seconds)
        false (Deadline.passed d);
      check bool
        (Printf.sprintf "%g s has time left" seconds)
        true
        (Deadline.remaining_seconds d > 0.))
    [ 1e9; 1e10; 1e19 ]
;;

let () =
  run "monotonic_deadline"
    [ ( "deadline"
      , [ test_case "a fresh deadline has its span left" `Quick
            test_a_fresh_deadline_has_its_span_left
        ; test_case "zero and negative spans are already passed" `Quick
            test_a_zero_deadline_is_already_passed
        ; test_case "remaining falls as time passes" `Quick
            test_remaining_falls_as_time_passes
        ; test_case "a far-future span does not wrap" `Quick
            test_a_far_future_span_does_not_wrap
        ] )
    ]
;;
