(* The rule the TUI loop reads once per pass to decide whether this pass is
   the last: a terminate signal ends the session, a first Ctrl-C only arms, a
   second one ends it, and any key in between withdraws the first. The loop
   turns [Quit] into [Break], the exit the q key takes, so this is the one
   place every signal's way out is decided. *)

open Alcotest
module Signals = Masc_tui_exit_signals

let verdict : Signals.verdict testable =
  testable
    (fun fmt v ->
      Format.pp_print_string fmt
        (match v with
         | Signals.Continue -> "Continue"
         | Signals.Interrupt_armed -> "Interrupt_armed"
         | Signals.Quit -> "Quit"))
    (fun a b -> a = b)

let test_quiet_session_keeps_running () =
  let t = Signals.create () in
  check verdict "nothing requested" Signals.Continue (Signals.poll t);
  check verdict "still nothing on the next pass" Signals.Continue
    (Signals.poll t)

let test_terminate_quits_on_the_next_pass () =
  let t = Signals.create () in
  Signals.request_terminate t;
  check verdict "a terminate signal ends the session" Signals.Quit
    (Signals.poll t);
  check verdict "and is never withdrawn" Signals.Quit (Signals.poll t)

let test_terminate_outranks_a_first_ctrl_c () =
  let t = Signals.create () in
  Signals.request_interrupt t;
  Signals.request_terminate t;
  check verdict "terminate wins over arming" Signals.Quit (Signals.poll t)

let test_first_ctrl_c_arms_and_second_quits () =
  let t = Signals.create () in
  Signals.request_interrupt t;
  check verdict "first Ctrl-C arms" Signals.Interrupt_armed (Signals.poll t);
  check verdict "the request is consumed" Signals.Continue (Signals.poll t);
  Signals.request_interrupt t;
  check verdict "second Ctrl-C quits" Signals.Quit (Signals.poll t)

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
      (Sys.Signal_handle (fun _ -> Signals.request_terminate t))
  in
  Fun.protect
    ~finally:(fun () -> Sys.set_signal Sys.sigterm previous)
    (fun () ->
      Unix.kill (Unix.getpid ()) Sys.sigterm;
      let rec settle passes =
        match Signals.poll t with
        | Signals.Quit -> ()
        | Signals.Continue | Signals.Interrupt_armed ->
            if passes = 0 then fail "SIGTERM never reached the loop's poll"
            else begin
              Unix.sleepf 0.001;
              settle (passes - 1)
            end
      in
      settle 1000)

(* A message waiting behind a running turn is held by this process, so the
   first quit key says what the second one drops -- count first, because the
   events pane cuts a notice short. *)
let test_quit_notice_names_what_a_second_press_drops () =
  check string "nothing waiting"
    "q: press again to quit, or any other key to stay"
    (Signals.quit_notice ~key:"q" ~waiting:0);
  check string "one waiting"
    "q: 1 unsent message is dropped if you press again to quit, or any other key to stay"
    (Signals.quit_notice ~key:"q" ~waiting:1);
  check string "several waiting, from Ctrl-C"
    "Ctrl-C: 3 unsent messages are dropped if you press again to quit, or any other key to stay"
    (Signals.quit_notice ~key:"Ctrl-C" ~waiting:3)

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
          test_case "a first Ctrl-C arms and a second quits" `Quick
            test_first_ctrl_c_arms_and_second_quits;
          test_case "input withdraws a standing Ctrl-C" `Quick
            test_input_withdraws_a_standing_ctrl_c;
        ] );
      ( "notice",
        [
          test_case "the quit notice names what a second press drops" `Quick
            test_quit_notice_names_what_a_second_press_drops;
        ] );
      ( "delivery",
        [
          test_case "a delivered SIGTERM reaches Quit" `Quick
            test_a_delivered_sigterm_reaches_quit;
        ] );
    ]
