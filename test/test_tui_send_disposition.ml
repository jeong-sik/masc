(* What Enter does in the Keeper chat composer. The send path and the footer
   read this one answer; before they worked it out separately and disagreed
   about a request being reconciled or cleaned up. *)

let check = Alcotest.check
let bool = Alcotest.bool
let d = Masc_tui_send_disposition.of_state

let clear =
  d ~prepared:None ~cleanup_pending:None ~recovery_blocked:None ~inflight:None
    ~unverified:None

(* A running turn is not a refusal. This is the case the footer got wrong:
   reconciliation and durable cleanup both leave the request in flight with no
   fence standing, and Enter queues in all three. *)
let test_a_turn_in_flight_queues () =
  (* Which kind of work is in flight -- a dispatch claim, an operation read,
     a durable cleanup -- is not an input here, which is the whole point: the
     footer read the kind and answered [Enter:blocked] for three of them while
     the send path, which does not see the kind, queued. *)
  check bool "a turn in flight queues" true
    (d ~prepared:None ~cleanup_pending:None ~recovery_blocked:None
       ~inflight:(Some "req-1") ~unverified:None
     = Masc_tui_send_disposition.Queues_behind "req-1");
  (* An unverified outcome does not turn a watched turn into a refusal: the
     turn is being watched and the queue drains when it settles. *)
  check bool "a turn outranks an unverified outcome" true
    (d ~prepared:None ~cleanup_pending:None ~recovery_blocked:None
       ~inflight:(Some "req-1") ~unverified:(Some "req-0")
     = Masc_tui_send_disposition.Queues_behind "req-1")

(* A durable fence says no further POST is authorized, so it outranks a
   running turn. *)
let test_durable_fences_outrank_a_turn () =
  check bool "prepared wins" true
    (d ~prepared:(Some "req-p") ~cleanup_pending:(Some "req-c")
       ~recovery_blocked:(Some "why") ~inflight:(Some "req-i")
       ~unverified:(Some "req-u")
     = Masc_tui_send_disposition.Refused_prepared "req-p");
  check bool "cleanup wins over a turn" true
    (d ~prepared:None ~cleanup_pending:(Some "req-c") ~recovery_blocked:None
       ~inflight:(Some "req-i") ~unverified:None
     = Masc_tui_send_disposition.Refused_cleanup "req-c");
  check bool "blocked recovery wins over a turn" true
    (d ~prepared:None ~cleanup_pending:None ~recovery_blocked:(Some "why")
       ~inflight:(Some "req-i") ~unverified:None
     = Masc_tui_send_disposition.Refused_recovery_blocked "why")

let test_nothing_standing_sends () =
  check bool "a clear state sends" true (clear = Masc_tui_send_disposition.Sends);
  check bool "an unverified outcome alone refuses" true
    (d ~prepared:None ~cleanup_pending:None ~recovery_blocked:None
       ~inflight:None ~unverified:(Some "req-u")
     = Masc_tui_send_disposition.Refused_unverified "req-u")

let () =
  Alcotest.run "tui_send_disposition"
    [ ( "disposition"
      , [ Alcotest.test_case "a turn in flight queues" `Quick
            test_a_turn_in_flight_queues
        ; Alcotest.test_case "durable fences outrank a turn" `Quick
            test_durable_fences_outrank_a_turn
        ; Alcotest.test_case "nothing standing sends" `Quick
            test_nothing_standing_sends
        ] )
    ]
