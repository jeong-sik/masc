(* Known terminal loss must skip the remaining exit output. Unknown setter
   and output errors remain visible. No attached terminal is required. *)

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

let test_einval_propagates () =
  check_raises "EINVAL is not a lost terminal"
    (Unix.Unix_error (Unix.EINVAL, "tcsetattr", ""))
    (fun () -> Restore.finish_after_restore
      ~restore:(fun () -> Restore.put_back ~set:(raising Unix.EINVAL))
      ~finish:(fun () -> fail "invalid settings must not reach final output"))

let test_successful_restore_finishes_in_order () =
  let calls = ref [] in
  Restore.finish_after_restore
    ~restore:(fun () -> Restore.put_back ~set:(fun () -> calls := ["restore"]))
    ~finish:(fun () -> calls := !calls @ ["finish"]);
  check (list string) "restoration precedes final terminal output"
    ["restore"; "finish"] !calls

let test_known_loss_skips_output_and_continues () =
  List.iter (fun error ->
    let calls = ref 0 in
    Restore.finish_after_restore
      ~restore:(fun () -> incr calls; Restore.put_back ~set:(raising error))
      ~finish:(fun () -> raise (Sys_error "lost terminal output must not run"));
    check int "known-loss cleanup returned after one restore" 1 !calls)
    [Unix.ENOTTY; Unix.EIO]

let test_output_failure_after_success_propagates () =
  check_raises "stdout failure is not inferred to be terminal loss"
    (Sys_error "output failed")
    (fun () -> Restore.finish_after_restore
      ~restore:(fun () -> Restore.Restored)
      ~finish:(fun () -> raise (Sys_error "output failed")))

let test_real_nonterminal_descriptor_skips_output () =
  let read_fd, write_fd = Unix.pipe ~cloexec:true () in
  Fun.protect ~finally:(fun () -> Unix.close read_fd; Unix.close write_fd)
    (fun () ->
      let settings : Unix.terminal_io =
        { c_ignbrk = false; c_brkint = false; c_ignpar = false; c_parmrk = false
        ; c_inpck = false; c_istrip = false; c_inlcr = false; c_igncr = false
        ; c_icrnl = false; c_ixon = false; c_ixoff = false; c_opost = false
        ; c_obaud = 9600; c_ibaud = 9600; c_csize = 8; c_cstopb = 1
        ; c_cread = true; c_parenb = false; c_parodd = false; c_hupcl = false
        ; c_clocal = true; c_isig = false; c_icanon = false; c_noflsh = false
        ; c_echo = false; c_echoe = false; c_echok = false; c_echonl = false
        ; c_vintr = '\000'; c_vquit = '\000'; c_verase = '\000'; c_vkill = '\000'
        ; c_veof = '\000'; c_veol = '\000'; c_vmin = 1; c_vtime = 0
        ; c_vstart = '\000'; c_vstop = '\000'
        }
      in
      Restore.finish_after_restore
        ~restore:(fun () ->
          let observed = Restore.put_back ~set:(fun () ->
            Unix.tcsetattr read_fd Unix.TCSANOW settings) in
          check outcome "real pipe tcsetattr returns ENOTTY"
            (Restore.Terminal_gone Unix.ENOTTY) observed;
          observed)
        ~finish:(fun () -> fail "non-terminal restore must skip final output"))

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
          test_case "EINVAL propagates" `Quick test_einval_propagates;
          test_case "successful restore finishes in order" `Quick
            test_successful_restore_finishes_in_order;
          test_case "known terminal loss skips remaining output" `Quick
            test_known_loss_skips_output_and_continues;
          test_case "output failure after successful restore propagates" `Quick
            test_output_failure_after_success_propagates;
          test_case "real pipe tcsetattr skips terminal output" `Quick
            test_real_nonterminal_descriptor_skips_output;
        ] );
    ]
