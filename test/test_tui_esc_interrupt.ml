(* Esc while the chat view shows a keeper whose turn is live.

   [Masc_tui_esc_interrupt.action] is the pure decision the dispatch arm in
   masc_tui.ml reads; these tests pin the table so the arm has no logic left
   to drift:

   - no interrupt requested yet: Esc is the first press — it launches the
     interrupt and is spent on it;
   - a signal just sent: Esc is the accidental second press the swallow was
     written for — spent, the view stays;
   - a signal older than the grace window: the turn heard the request and
     kept streaming (masc #29229: a parked turn may stream indefinitely), so
     Esc leaves the view. Leaving cancels nothing — the interrupt proceeds
     server-side and the pane can be reopened;
   - a declined or errored request: nothing is pending, so Esc leaves at
     once. Before the grace window existed, this arm trapped Esc for the
     rest of the session. *)

open Alcotest
module Esc = Masc_tui_esc_interrupt
module Transcript = Masc_tui_keeper_chat_transcript

let action_to_string = function
  | Esc.Launch_interrupt -> "launch"
  | Esc.Swallow -> "swallow"
  | Esc.Leave -> "leave"
;;

let check_action ~now interrupt expected =
  check string
    (Printf.sprintf "now=%.2f -> %s" now (action_to_string expected))
    (action_to_string expected)
    (action_to_string (Esc.action ~now interrupt))
;;

let sent ~signalled_at =
  Transcript.Signal_sent { turn_id = Some 7; signalled_at }
;;

let test_first_esc_launches_the_interrupt () =
  check_action ~now:100.0 Transcript.Not_requested Esc.Launch_interrupt
;;

let test_double_press_inside_the_grace_window_is_swallowed () =
  check_action ~now:100.0 (sent ~signalled_at:100.0) Esc.Swallow;
  check_action ~now:100.9 (sent ~signalled_at:100.0) Esc.Swallow;
  (* The boundary itself is still the guard. *)
  check_action ~now:102.0 (sent ~signalled_at:100.0) Esc.Swallow
;;

let test_esc_leaves_once_the_signal_is_older_than_the_grace_window () =
  check_action ~now:102.1 (sent ~signalled_at:100.0) Esc.Leave;
  (* The parked-turn case (masc #29229): an hour of streaming after the
     signal must not hold Esc. *)
  check_action ~now:3700.0 (sent ~signalled_at:100.0) Esc.Leave
;;

let test_clock_skew_reads_as_a_fresh_signal () =
  (* A timestamp ahead of now is a signal that has demonstrably just been
     sent; negative age stays inside the guard rather than leaving. *)
  check_action ~now:100.0 (sent ~signalled_at:101.0) Esc.Swallow
;;

let test_declined_or_errored_interrupt_lets_esc_leave_immediately () =
  check_action ~now:100.0 (Transcript.Signal_declined "no turn in flight")
    Esc.Leave;
  check_action ~now:100.0 (Transcript.Signal_error "connection refused")
    Esc.Leave
;;

let () =
  run
    "tui_esc_interrupt"
    [ ( "esc during a live turn"
      , [ test_case "first press launches the interrupt" `Quick
            test_first_esc_launches_the_interrupt
        ; test_case "double press inside the grace window is swallowed" `Quick
            test_double_press_inside_the_grace_window_is_swallowed
        ; test_case "esc leaves once the grace window has passed" `Quick
            test_esc_leaves_once_the_signal_is_older_than_the_grace_window
        ; test_case "clock skew reads as a fresh signal" `Quick
            test_clock_skew_reads_as_a_fresh_signal
        ; test_case "declined or errored interrupt lets esc leave" `Quick
            test_declined_or_errored_interrupt_lets_esc_leave_immediately
        ] )
    ]
;;
