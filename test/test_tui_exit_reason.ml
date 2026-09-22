(* The vocabulary the TUI writes its exit line in. The line is the only record
   of why a session ended -- the per-PID stderr log held the boot lines and
   nothing else -- so the split it carries (normal vs abnormal), the one-row
   flattening, and the bound on a runaway cause are pinned here, apart from
   the loop. *)

open Alcotest
module Reason = Masc_tui_exit_reason

let contains haystack needle =
  let needle_length = String.length needle
  and haystack_length = String.length haystack in
  let rec scan index =
    if index + needle_length > haystack_length then false
    else if String.equal (String.sub haystack index needle_length) needle then
      true
    else scan (index + 1)
  in
  scan 0

let test_normal_ends_are_the_ones_asked_for () =
  check bool "q is normal" true (Reason.is_normal Reason.Quit_key);
  check bool "a second Ctrl-C is normal" true (Reason.is_normal Reason.Interrupt);
  check bool "a terminate signal is normal" true
    (Reason.is_normal (Reason.Terminate "SIGTERM"));
  check bool "an uncaught exception is abnormal" false
    (Reason.is_normal (Reason.Exception "Failure(\"boom\")"));
  check bool "an end with no recorded cause is abnormal" false
    (Reason.is_normal Reason.Unrecorded)

let test_line_names_the_split_and_the_cause () =
  check string "the quit key" "exit: normal (quit key)"
    (Reason.line Reason.Quit_key);
  check string "the interrupt" "exit: normal (interrupt)"
    (Reason.line Reason.Interrupt);
  check string "the signal" "exit: normal (signal SIGHUP)"
    (Reason.line (Reason.Terminate "SIGHUP"));
  check string "the exception" "exit: abnormal (exception Failure(\"boom\"))"
    (Reason.line (Reason.Exception "Failure(\"boom\")"))

(* [Unrecorded] is abnormal, but it is not an exception: nothing here observed
   one. A row that says "exception" where none was seen sends whoever reads
   the log looking for a failure that did not happen. *)
let test_an_unrecorded_end_does_not_claim_an_exception () =
  check string "it names itself" "exit: abnormal (no cause was recorded)"
    (Reason.line Reason.Unrecorded);
  check bool "and never says exception" false
    (contains (Reason.line Reason.Unrecorded) "exception")

(* The log is read a line at a time, so a detail carrying a newline or another
   control byte must not break one record into two. *)
let test_a_detail_is_flattened_to_one_row () =
  check string "a newline becomes a space"
    "exit: abnormal (exception Failure(\"a b\"))"
    (Reason.line (Reason.Exception "Failure(\"a\nb\")"));
  check string "a carriage return becomes a space"
    "exit: abnormal (exception x y)"
    (Reason.line (Reason.Exception "x\ry"));
  check string "a tab becomes a space" "exit: abnormal (exception x y)"
    (Reason.line (Reason.Exception "x\ty"))

let test_a_cause_inside_the_bound_is_left_whole () =
  check string "nothing is appended to a short cause"
    "exit: abnormal (exception boom)"
    (Reason.line (Reason.Exception "boom"))

(* An uncaught exception's message can carry a whole backtrace. The row is cut
   so a reader can still scan these lines side by side, and the cut says how
   many bytes it dropped -- an ellipsis would say the text continues but not
   whether the rest is worth finding. *)
let test_a_runaway_cause_is_cut_and_says_what_it_dropped () =
  let detail = String.concat "" (List.init 100 (fun _ -> "글")) in
  check int "the fixture is past the bound" 300 (String.length detail);
  let row = Reason.line (Reason.Exception detail) in
  (* The bound is 200 bytes of cause; the framing and the dropped-byte note
     are the rest. Well under the 327 an uncut row would take. *)
  check bool "the row does not carry the whole backtrace" true
    (String.length row < 260);
  check bool "the row says how many bytes it dropped" true
    (contains row "[+" && contains row " bytes]")

(* Cutting on a byte would leave half a character in the log, and the reader
   that greps these rows decodes them as text. *)
let test_the_cut_lands_on_a_character_boundary () =
  let detail = String.concat "" (List.init 100 (fun _ -> "글")) in
  let row = Reason.line (Reason.Exception detail) in
  check bool "what the row kept is still valid UTF-8" true
    (String.is_valid_utf_8 row);
  (* A one-byte cause cut at the same place proves the boundary walk does not
     simply refuse every cut. *)
  let ascii = String.make 300 'x' in
  check bool "an ASCII cause is cut too" true
    (contains (Reason.line (Reason.Exception ascii)) " bytes]")

let () =
  run "tui exit reason"
    [
      ( "split",
        [
          test_case "normal ends are the ones asked for" `Quick
            test_normal_ends_are_the_ones_asked_for;
          test_case "an unrecorded end does not claim an exception" `Quick
            test_an_unrecorded_end_does_not_claim_an_exception;
        ] );
      ( "line",
        [
          test_case "the line names the split and the cause" `Quick
            test_line_names_the_split_and_the_cause;
          test_case "a detail is flattened to one row" `Quick
            test_a_detail_is_flattened_to_one_row;
        ] );
      ( "bound",
        [
          test_case "a cause inside the bound is left whole" `Quick
            test_a_cause_inside_the_bound_is_left_whole;
          test_case "a runaway cause is cut and says what it dropped" `Quick
            test_a_runaway_cause_is_cut_and_says_what_it_dropped;
          test_case "the cut lands on a character boundary" `Quick
            test_the_cut_lands_on_a_character_boundary;
        ] );
    ]
