(* What Enter does in the Keeper chat composer. The send path and the footer
   read this one answer; before they worked it out separately and disagreed
   about a request being reconciled or cleaned up. *)

let check = Alcotest.check
let bool = Alcotest.bool
let d = Masc_tui_send_disposition.of_state

(* A running turn is not a refusal. This is the case the footer got wrong:
   the send path queued while the footer said [Enter:blocked]. *)
let test_a_turn_in_flight_queues () =
  check bool "a turn in flight queues" true
    (d ~inflight:(Some "req-1") ~waiting:None
     = Masc_tui_send_disposition.Queues_behind "req-1")

let test_nothing_standing_sends () =
  check bool "a clear state sends" true
    (d ~inflight:None ~waiting:None = Masc_tui_send_disposition.Sends)

(* No turn is running, but a line is already waiting -- held because the
   operator is still composing the next. Enter joins that line rather than
   dispatching past it, so the free-keeper path cannot overtake a queued line. *)
let test_a_waiting_line_queues () =
  check bool "a waiting line queues" true
    (d ~inflight:None ~waiting:(Some "wait-1")
     = Masc_tui_send_disposition.Queues_behind "wait-1")

(* When both stand, the in-flight turn is the one named as the block: it is the
   turn Enter's line will follow, and the waiting line is already behind it. *)
let test_inflight_wins_over_waiting () =
  check bool "inflight names the block" true
    (d ~inflight:(Some "req-1") ~waiting:(Some "wait-1")
     = Masc_tui_send_disposition.Queues_behind "req-1")

let () =
  Alcotest.run "tui_send_disposition"
    [ ( "disposition"
      , [ Alcotest.test_case "a turn in flight queues" `Quick
            test_a_turn_in_flight_queues
        ; Alcotest.test_case "nothing standing sends" `Quick
            test_nothing_standing_sends
        ; Alcotest.test_case "a waiting line queues" `Quick
            test_a_waiting_line_queues
        ; Alcotest.test_case "inflight wins over waiting" `Quick
            test_inflight_wins_over_waiting
        ] )
    ]
