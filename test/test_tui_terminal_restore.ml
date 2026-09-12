(* The exit-time terminal restore on a descriptor that is no longer a
   terminal. [Unix.tcsetattr] raises there, and before this module the raise
   left [restore_terminal] and stopped the [at_exit] chain: 22 TUI logs ended
   with 'Fatal error: exception Unix.Unix_error(Unix.ENOTTY, "tcsetattr", "")'
   between 2026-08-25 and 2026-09-12. The setter is passed in so the rule --
   ENOTTY and EIO mean the terminal is gone, everything else is still an
   error -- runs with no terminal at all. *)

open Alcotest
module Restore = Masc_tui_terminal_restore

let outcome : Restore.outcome testable =
  testable
    (fun fmt v ->
      Format.pp_print_string fmt
        (match v with
         | Restore.Restored -> "Restored"
         | Restore.Terminal_gone err ->
           "Terminal_gone " ^ Unix.error_message err))
    (fun a b -> a = b)

let raising err () = raise (Unix.Unix_error (err, "tcsetattr", ""))

let test_a_setter_that_returns_is_restored () =
  let calls = ref 0 in
  check outcome "the setter ran and returned" Restore.Restored
    (Restore.put_back ~set:(fun () -> incr calls));
  check int "the setter ran exactly once" 1 !calls

let test_enotty_is_the_terminal_gone () =
  check outcome "ENOTTY: stdin is no longer a terminal"
    (Restore.Terminal_gone Unix.ENOTTY)
    (Restore.put_back ~set:(raising Unix.ENOTTY))

let test_eio_is_the_terminal_gone () =
  check outcome "EIO: the pty behind stdin hung up"
    (Restore.Terminal_gone Unix.EIO)
    (Restore.put_back ~set:(raising Unix.EIO))

(* A refusal that does not mean a lost terminal is a caller bug, and it must
   still reach the log as the exception it was. *)
let test_another_unix_error_propagates () =
  check_raises "EBADF is not a lost terminal"
    (Unix.Unix_error (Unix.EBADF, "tcsetattr", ""))
    (fun () ->
      ignore (Restore.put_back ~set:(raising Unix.EBADF) : Restore.outcome))

let test_a_non_unix_exception_propagates () =
  check_raises "a Failure is not a lost terminal" (Failure "tcsetattr")
    (fun () ->
      ignore
        (Restore.put_back ~set:(fun () -> failwith "tcsetattr")
          : Restore.outcome))

let () =
  run "tui_terminal_restore"
    [
      ( "put_back",
        [
          test_case "a setter that returns is Restored" `Quick
            test_a_setter_that_returns_is_restored;
          test_case "ENOTTY is the terminal gone" `Quick
            test_enotty_is_the_terminal_gone;
          test_case "EIO is the terminal gone" `Quick
            test_eio_is_the_terminal_gone;
          test_case "another Unix error propagates" `Quick
            test_another_unix_error_propagates;
          test_case "a non-Unix exception propagates" `Quick
            test_a_non_unix_exception_propagates;
        ] );
    ]
