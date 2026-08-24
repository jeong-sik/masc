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
    (d ~inflight:(Some "req-1")
     = Masc_tui_send_disposition.Queues_behind "req-1")

let test_nothing_standing_sends () =
  check bool "a clear state sends" true
    (d ~inflight:None = Masc_tui_send_disposition.Sends)

let () =
  Alcotest.run "tui_send_disposition"
    [ ( "disposition"
      , [ Alcotest.test_case "a turn in flight queues" `Quick
            test_a_turn_in_flight_queues
        ; Alcotest.test_case "nothing standing sends" `Quick
            test_nothing_standing_sends
        ] )
    ]
