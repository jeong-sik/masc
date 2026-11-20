(* What the reading slot decides (RFC tui-one-screen-grammar §8). Checked are
   the decisions only: when the slot turns on, what length it names, how long
   it waits after the last slow read, and what cancels the wait. No screen is
   drawn. *)

open Alcotest
module R = Masc_tui_reading
module Mono = Masc_tui_wake.Mono

(* Instants on the main loop's clock, [seconds] after this test began. Every
   instant below is a whole number of seconds or a half, which the clock's
   nanoseconds hold exactly, so the bar is hit exactly where a test says. *)
let start = Mono.now ()
let at seconds = Mono.after start seconds

let pp_shown ppf (shown : R.shown) =
  match shown with
  | Hidden -> Format.pp_print_string ppf "Hidden"
  | Showing (Growing { began }) -> Format.fprintf ppf "Growing from %Ld ns" (began :> int64)
  | Showing (Frozen { age_s }) -> Format.fprintf ppf "Frozen at %.3f s" age_s

let shown_t = testable pp_shown ( = )
let growing_from seconds : R.shown = Showing (Growing { began = at seconds })
let frozen_at age_s : R.shown = Showing (Frozen { age_s })

let board = "board"
let keepers = "keepers"
let begin_read ?(scope = board) t seconds = R.started t ~scope ~now:(at seconds)
let step_at ?(scope = board) t seconds = R.step t ~scope ~now:(at seconds)
let end_read ?(outcome = R.Succeeded) t read = R.finished t read ~outcome

let test_a_read_inside_the_bar_draws_nothing () =
  let t, read = begin_read R.empty 0.0 in
  let t, shown = step_at t 0.5 in
  check shown_t "in flight inside the bar" R.Hidden shown;
  let t = end_read t read in
  let _, shown = step_at t 0.5 in
  check shown_t "ended inside the bar" R.Hidden shown

let test_the_slot_turns_on_at_the_bar () =
  let t, _ = begin_read R.empty 0.0 in
  let t, shown = step_at t 0.5 in
  check shown_t "half a bar" R.Hidden shown;
  let _, shown = step_at t 1.0 in
  check shown_t "at the bar" (growing_from 0.0) shown

let test_the_length_is_the_oldest_read_past_the_bar () =
  let t, oldest = begin_read R.empty 0.0 in
  let t, _newer = begin_read t 0.5 in
  let t, shown = step_at t 2.0 in
  check shown_t "the older read names the length" (growing_from 0.0) shown;
  let t = end_read t oldest in
  let _, shown = step_at t 2.0 in
  check shown_t "the newer read names it once the older one ended" (growing_from 0.5) shown

let test_the_slot_waits_one_bar_after_a_slow_read_succeeds () =
  let t, read = begin_read R.empty 0.0 in
  let t, _ = step_at t 1.5 in
  let t = end_read t read in
  let t, shown = step_at t 3.0 in
  check shown_t "the length it had" (frozen_at 3.0) shown;
  let t, shown = step_at t 3.5 in
  check shown_t "inside the wait" (frozen_at 3.0) shown;
  let _, shown = step_at t 4.0 in
  check shown_t "the wait is over" R.Hidden shown

let test_a_read_inside_the_bar_changes_nothing_while_the_slot_waits () =
  let t, read = begin_read R.empty 0.0 in
  let t, _ = step_at t 1.5 in
  let t = end_read t read in
  let t, _ = step_at t 3.0 in
  let t, quick = begin_read t 3.0 in
  let t, shown = step_at t 3.5 in
  check shown_t "in flight: the length stays" (frozen_at 3.0) shown;
  let t = end_read t quick in
  let t, shown = step_at t 3.5 in
  check shown_t "ended: the length stays" (frozen_at 3.0) shown;
  let _, shown = step_at t 4.0 in
  check shown_t "and the wait still ends one bar after the slow read" R.Hidden shown

let test_a_read_that_started_in_the_wait_keeps_the_slot_on_until_it_ends () =
  let t, read = begin_read R.empty 0.0 in
  let t, _ = step_at t 1.5 in
  let t = end_read t read in
  let t, _ = step_at t 3.0 in
  let t, next = begin_read t 3.5 in
  let t, shown = step_at t 4.0 in
  check shown_t "the wait is over and the read has not passed the bar" (frozen_at 3.0) shown;
  let t' = end_read t next in
  let _, shown = step_at t' 4.25 in
  check shown_t "it ended inside the bar" R.Hidden shown;
  let _, shown = step_at t 4.5 in
  check shown_t "it passed the bar" (growing_from 3.5) shown

let test_a_read_that_started_after_the_wait_is_not_waited_for () =
  let t, read = begin_read R.empty 0.0 in
  let t, _ = step_at t 1.5 in
  let t = end_read t read in
  let t, _ = step_at t 3.0 in
  let t, inside = begin_read t 3.5 in
  let t, shown = step_at t 4.0 in
  check shown_t "the read from inside the wait is waited for" (frozen_at 3.0) shown;
  let t = end_read t inside in
  let t, _after = begin_read t 4.0 in
  let _, shown = step_at t 4.25 in
  check shown_t "the read that started when the wait ended is not" R.Hidden shown

let test_slow_reads_that_follow_one_another_keep_the_slot_on () =
  let t, first = begin_read R.empty 0.0 in
  let t, _ = step_at t 1.0 in
  let t = end_read t first in
  (* The pass that applies the answer steps the slot at once. *)
  let t, _ = step_at t 2.0 in
  let t, second = begin_read t 2.5 in
  let t, shown = step_at t 3.0 in
  check shown_t "the wait is over and the second read is inside the bar"
    (frozen_at 2.0) shown;
  let t, shown = step_at t 3.5 in
  check shown_t "the second read passes the bar" (growing_from 2.5) shown;
  let t = end_read t second in
  let t, _ = step_at t 5.0 in
  let t, _third = begin_read t 5.5 in
  let t, shown = step_at t 6.0 in
  check shown_t "the slot stays on across the gap again" (frozen_at 2.5) shown;
  let _, shown = step_at t 6.5 in
  check shown_t "the third read passes the bar" (growing_from 5.5) shown

let test_a_failed_slow_read_turns_the_slot_off_at_once () =
  let t, read = begin_read R.empty 0.0 in
  let t, _ = step_at t 1.5 in
  let t = end_read ~outcome:R.Failed t read in
  let _, shown = step_at t 2.0 in
  check shown_t "no wait after a failure" R.Hidden shown

let test_a_failure_cancels_the_wait () =
  let t, read = begin_read R.empty 0.0 in
  let t, _ = step_at t 1.5 in
  let t = end_read t read in
  let t, _ = step_at t 3.0 in
  let t, other = begin_read t 3.5 in
  let t = end_read ~outcome:R.Failed t other in
  let _, shown = step_at t 3.75 in
  check shown_t "the wait is cancelled" R.Hidden shown

let test_another_slow_read_keeps_the_slot_on_when_one_fails () =
  let t, first = begin_read R.empty 0.0 in
  let t, _second = begin_read t 0.5 in
  let t, _ = step_at t 2.0 in
  let t = end_read ~outcome:R.Failed t first in
  let _, shown = step_at t 2.0 in
  check shown_t "the one that is left names the length" (growing_from 0.5) shown

let test_a_failure_of_another_screens_read_cancels_nothing () =
  let t, read = begin_read R.empty 0.0 in
  let t, _ = step_at t 1.5 in
  let t = end_read t read in
  let t, _ = step_at t 3.0 in
  let t, other = begin_read ~scope:keepers t 3.25 in
  let t = end_read ~outcome:R.Failed t other in
  let _, shown = step_at t 3.5 in
  check shown_t "still waiting" (frozen_at 3.0) shown

let test_another_screens_reads_are_not_counted () =
  let t, _ = begin_read R.empty 0.0 in
  let t, shown = step_at ~scope:keepers t 2.0 in
  check shown_t "the keepers screen has no read" R.Hidden shown;
  let _, shown = step_at ~scope:board t 2.0 in
  check shown_t "the read keeps its age when its screen comes back" (growing_from 0.0) shown

let test_leaving_a_screen_starts_the_decision_over () =
  let t, read = begin_read R.empty 0.0 in
  let t, _ = step_at t 1.5 in
  let t = end_read t read in
  let t, _ = step_at ~scope:keepers t 2.0 in
  let _, shown = step_at ~scope:board t 2.25 in
  check shown_t "no wait is carried over" R.Hidden shown

let test_an_id_ends_once () =
  let t, read = begin_read R.empty 0.0 in
  let t = end_read t read in
  let t' = end_read ~outcome:R.Failed t read in
  check bool "the second end changes nothing" true (t == t')

let wall_now = 1_000.0
let mark = Masc_tui_value.Unknown.glyph Masc_tui_value.Unknown.Unread

let test_the_slot_text_keeps_its_width () =
  let text shown = R.text ~now:(at 100.0) ~wall_now shown in
  check string "hidden is blanks" "     " (text R.Hidden);
  check string "a growing length" (mark ^ "  6s") (R.text ~now:(at 6.0) ~wall_now (growing_from 0.0));
  check string "whole seconds below a minute" (mark ^ " 59s") (text (frozen_at 59.9));
  check string "a minute" (mark ^ "  1m") (text (frozen_at 60.0));
  check string "an hour" (mark ^ "  3h") (text (frozen_at (3.0 *. 3600.0)));
  check string "a hundred days read 99d" (mark ^ " 99d") (text (frozen_at (100.0 *. 86_400.0)));
  check string "and so do more"
    (mark ^ " 99d") (text (frozen_at (1_000.0 *. 86_400.0)))

let test_the_slot_notes_when_a_read_passes_the_bar () =
  Masc_tui_wake.Pass.begin_pass ();
  let t, _ = begin_read R.empty 0.0 in
  ignore (step_at t 0.25);
  match Masc_tui_wake.Pass.noted () with
  | None -> fail "nothing noted"
  | Some deadline ->
      check bool "for the slot" true
        (deadline.reason = Masc_tui_wake.Monotonic Masc_tui_wake.Reading_slot);
      check int64 "at the bar" (at 1.0 :> int64) deadline.at_ns

let test_the_slot_notes_when_its_wait_ends () =
  let t, read = begin_read R.empty 0.0 in
  let t, _ = step_at t 1.5 in
  let t = end_read t read in
  Masc_tui_wake.Pass.begin_pass ();
  ignore (step_at t 3.0);
  match Masc_tui_wake.Pass.noted () with
  | None -> fail "nothing noted"
  | Some deadline -> check int64 "one bar after the read ended" (at 4.0 :> int64) deadline.at_ns

let () =
  run "tui_reading"
    [ ( "bar"
      , [ test_case "a read inside the bar draws nothing" `Quick
            test_a_read_inside_the_bar_draws_nothing
        ; test_case "the slot turns on at the bar" `Quick test_the_slot_turns_on_at_the_bar
        ; test_case "the length is the oldest read past the bar" `Quick
            test_the_length_is_the_oldest_read_past_the_bar
        ] )
    ; ( "wait"
      , [ test_case "one bar after a slow read succeeds" `Quick
            test_the_slot_waits_one_bar_after_a_slow_read_succeeds
        ; test_case "a read inside the bar changes nothing" `Quick
            test_a_read_inside_the_bar_changes_nothing_while_the_slot_waits
        ; test_case "a read that started in the wait keeps the slot on" `Quick
            test_a_read_that_started_in_the_wait_keeps_the_slot_on_until_it_ends
        ; test_case "a read that started after the wait is not waited for" `Quick
            test_a_read_that_started_after_the_wait_is_not_waited_for
        ; test_case "slow reads that follow one another" `Quick
            test_slow_reads_that_follow_one_another_keep_the_slot_on
        ] )
    ; ( "failure"
      , [ test_case "a failed slow read turns the slot off at once" `Quick
            test_a_failed_slow_read_turns_the_slot_off_at_once
        ; test_case "a failure cancels the wait" `Quick test_a_failure_cancels_the_wait
        ; test_case "another slow read keeps the slot on" `Quick
            test_another_slow_read_keeps_the_slot_on_when_one_fails
        ; test_case "another screen's failure cancels nothing" `Quick
            test_a_failure_of_another_screens_read_cancels_nothing
        ] )
    ; ( "screen"
      , [ test_case "another screen's reads are not counted" `Quick
            test_another_screens_reads_are_not_counted
        ; test_case "leaving a screen starts over" `Quick
            test_leaving_a_screen_starts_the_decision_over
        ; test_case "an id ends once" `Quick test_an_id_ends_once
        ] )
    ; ( "text"
      , [ test_case "the width holds" `Quick test_the_slot_text_keeps_its_width ] )
    ; ( "wake"
      , [ test_case "a read passes the bar" `Quick test_the_slot_notes_when_a_read_passes_the_bar
        ; test_case "the wait ends" `Quick test_the_slot_notes_when_its_wait_ends
        ] )
    ]
