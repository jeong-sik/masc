(* The rule the TUI loop reads once per pass to decide whether this pass is
   the last: a terminate signal ends the session, a first Ctrl-C only arms, a
   second one asks the loop to validate the displayed confirmation, and any
   key in between withdraws the first. Explicit termination stays immediate. *)

open Alcotest
module Signals = Masc_tui_exit_signals

let verdict : Signals.verdict testable =
  testable
    (fun fmt v ->
      Format.pp_print_string fmt
        (match v with
         | Signals.Continue -> "Continue"
         | Signals.Interrupt_armed -> "Interrupt_armed"
         | Signals.Interrupt_again -> "Interrupt_again"
         | Signals.Quit -> "Quit"))
    (fun a b -> a = b)

let test_quiet_session_keeps_running () =
  let t = Signals.create () in
  check verdict "nothing requested" Signals.Continue (Signals.poll t);
  check verdict "still nothing on the next pass" Signals.Continue
    (Signals.poll t)

let test_terminate_quits_on_the_next_pass () =
  let t = Signals.create () in
  Signals.request_terminate t ~signal:"SIGTERM";
  check verdict "a terminate signal ends the session" Signals.Quit
    (Signals.poll t);
  check verdict "and is never withdrawn" Signals.Quit (Signals.poll t);
  check (option string) "the cause is the signal that asked" (Some "SIGTERM")
    (Signals.terminate_signal t)

let test_terminate_outranks_a_first_ctrl_c () =
  let t = Signals.create () in
  Signals.request_interrupt t;
  Signals.request_terminate t ~signal:"SIGHUP";
  check verdict "terminate wins over arming" Signals.Quit (Signals.poll t);
  check (option string) "and the cause is the terminate, not the Ctrl-C"
    (Some "SIGHUP") (Signals.terminate_signal t)

(* A second Ctrl-C is not an explicit terminate signal. *)
let test_a_second_ctrl_c_leaves_no_terminate_signal () =
  let t = Signals.create () in
  Signals.request_interrupt t;
  ignore (Signals.poll t);
  Signals.request_interrupt t;
  check verdict "second Ctrl-C requires display admission" Signals.Interrupt_again (Signals.poll t);
  check (option string) "no signal asked for this end" None
    (Signals.terminate_signal t)

let test_first_ctrl_c_arms_and_second_needs_admission () =
  let t = Signals.create () in
  Signals.request_interrupt t;
  check verdict "first Ctrl-C arms" Signals.Interrupt_armed (Signals.poll t);
  check verdict "the request is consumed" Signals.Continue (Signals.poll t);
  Signals.request_interrupt t;
  check verdict "second Ctrl-C requires display admission" Signals.Interrupt_again (Signals.poll t)

let test_interrupt_pending_is_not_consumed_by_observation () =
  let t = Signals.create () in
  check bool "initially clear" false (Signals.interrupt_pending t);
  Signals.request_interrupt t;
  check bool "interrupt is pending" true (Signals.interrupt_pending t);
  check bool "a second observation is read-only" true (Signals.interrupt_pending t);
  check verdict "poll consumes and arms" Signals.Interrupt_armed (Signals.poll t);
  check bool "poll consumed the request" false (Signals.interrupt_pending t)

let test_input_withdraws_a_standing_ctrl_c () =
  let t = Signals.create () in
  Signals.request_interrupt t;
  check verdict "first Ctrl-C arms" Signals.Interrupt_armed (Signals.poll t);
  Signals.withdraw_interrupt t;
  Signals.request_interrupt t;
  check verdict "a Ctrl-C after a key arms again rather than quitting"
    Signals.Interrupt_armed (Signals.poll t)

(* The handlers the TUI installs are [Sys.Signal_handle] closures over
   [request_terminate]. A SIGTERM the process sends itself has to reach
   [Quit] with the loop doing nothing but poll: the handler runs at the next
   poll point, and [Unix.sleepf] is one. *)
let test_a_delivered_sigterm_reaches_quit () =
  let t = Signals.create () in
  let previous =
    Sys.signal Sys.sigterm
      (Sys.Signal_handle (fun _ -> Signals.request_terminate t ~signal:"SIGTERM"))
  in
  Fun.protect
    ~finally:(fun () -> Sys.set_signal Sys.sigterm previous)
    (fun () ->
      Unix.kill (Unix.getpid ()) Sys.sigterm;
      let rec settle passes =
        match Signals.poll t with
        | Signals.Quit -> ()
        | Signals.Continue | Signals.Interrupt_armed | Signals.Interrupt_again ->
            if passes = 0 then fail "SIGTERM never reached the loop's poll"
            else begin
              Unix.sleepf 0.001;
              settle (passes - 1)
            end
      in
      settle 1000)

let () =
  run "tui exit signals"
    [
      ( "verdict",
        [
          test_case "a quiet session keeps running" `Quick
            test_quiet_session_keeps_running;
          test_case "a terminate request quits on the next pass" `Quick
            test_terminate_quits_on_the_next_pass;
          test_case "a terminate request outranks a first Ctrl-C" `Quick
            test_terminate_outranks_a_first_ctrl_c;
          test_case "a second Ctrl-C leaves no terminate signal" `Quick
            test_a_second_ctrl_c_leaves_no_terminate_signal;
          test_case "a second Ctrl-C requires admission" `Quick
            test_first_ctrl_c_arms_and_second_needs_admission;
          test_case "input withdraws a standing Ctrl-C" `Quick
            test_input_withdraws_a_standing_ctrl_c;
          test_case "pending observation does not consume an interrupt" `Quick
            test_interrupt_pending_is_not_consumed_by_observation;
        ] );
      ( "delivery",
        [
          test_case "a delivered SIGTERM reaches Quit" `Quick
            test_a_delivered_sigterm_reaches_quit;
        ] );
    ]
