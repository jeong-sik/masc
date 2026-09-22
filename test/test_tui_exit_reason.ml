(* The vocabulary the TUI writes its exit line in. The line is the only record
   of why a session ended -- the per-PID stderr log held the boot lines and
   nothing else -- so the split it carries (normal vs abnormal) and the one-row
   flattening are pinned here, apart from the loop. *)

open Alcotest
module Reason = Masc_tui_exit_reason

let test_normal_ends_are_the_ones_asked_for () =
  check bool "q is normal" true (Reason.is_normal Reason.Quit_key);
  check bool "a second Ctrl-C is normal" true (Reason.is_normal Reason.Interrupt);
  check bool "a terminate signal is normal" true
    (Reason.is_normal (Reason.Terminate "SIGTERM"));
  check bool "an uncaught exception is abnormal" false
    (Reason.is_normal (Reason.Exception "Failure(\"boom\")"))

let test_line_names_the_split_and_the_cause () =
  check string "the quit key" "exit: normal (quit key)"
    (Reason.line Reason.Quit_key);
  check string "the interrupt" "exit: normal (interrupt)"
    (Reason.line Reason.Interrupt);
  check string "the signal" "exit: normal (signal SIGHUP)"
    (Reason.line (Reason.Terminate "SIGHUP"));
  check string "the exception" "exit: abnormal (exception Failure(\"boom\"))"
    (Reason.line (Reason.Exception "Failure(\"boom\")"))

(* The log is read a line at a time, so a detail carrying a newline or another
   control byte must not break the record into two. *)
let test_a_detail_is_flattened_to_one_row () =
  check string "a newline becomes a space"
    "exit: abnormal (exception Failure(\"a b\"))"
    (Reason.line (Reason.Exception "Failure(\"a\nb\")"));
  check string "a carriage return becomes a space"
    "exit: abnormal (exception x y)"
    (Reason.line (Reason.Exception "x\ry"));
  check string "a tab becomes a space" "exit: abnormal (exception x y)"
    (Reason.line (Reason.Exception "x\ty"))

let () =
  run "tui exit reason"
    [
      ( "split",
        [
          test_case "normal ends are the ones asked for" `Quick
            test_normal_ends_are_the_ones_asked_for;
        ] );
      ( "line",
        [
          test_case "the line names the split and the cause" `Quick
            test_line_names_the_split_and_the_cause;
          test_case "a detail is flattened to one row" `Quick
            test_a_detail_is_flattened_to_one_row;
        ] );
    ]
