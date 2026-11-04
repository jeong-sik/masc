(* RFC-0480 §3.4: a connector's recording functions announce what a status
   read would show differently, and stay quiet when a poll only moves its
   offset or cursor. *)

open Alcotest

let with_counter f =
  let notified = ref 0 in
  Channel_gate_change.install (fun () -> incr notified);
  Fun.protect ~finally:(fun () -> Channel_gate_change.install (fun () -> ())) (fun () ->
    f notified)
;;

let test_telegram_polls_announce_only_a_new_bot () =
  with_counter @@ fun notified ->
  Channel_gate_telegram_state.record_poll_ok ~bot_user_id:7L ~next_offset:None;
  check int "the first poll announces" 1 !notified;
  Channel_gate_telegram_state.record_poll_ok ~bot_user_id:7L ~next_offset:(Some 42L);
  check int "a moved offset does not" 1 !notified;
  Channel_gate_telegram_state.record_error "network unreachable";
  check int "a degraded poll announces" 2 !notified;
  Channel_gate_telegram_state.record_poll_ok ~bot_user_id:7L ~next_offset:(Some 43L);
  check int "polling again announces" 3 !notified
;;

let test_imessage_polls_announce_only_a_state_change () =
  with_counter @@ fun notified ->
  Channel_gate_imessage_state.record_poll_error "chat.db locked";
  check int "a poll error announces" 1 !notified;
  Channel_gate_imessage_state.record_poll_ok ~cursor_rowid:10;
  check int "recovering announces" 2 !notified;
  Channel_gate_imessage_state.record_poll_ok ~cursor_rowid:11;
  check int "a moved cursor does not" 2 !notified
;;

let () =
  run "gate_change_notify"
    [ ( "polls"
      , [ test_case "Telegram announces only a new bot" `Quick
            test_telegram_polls_announce_only_a_new_bot
        ; test_case "iMessage announces only a state change" `Quick
            test_imessage_polls_announce_only_a_state_change
        ] )
    ]
;;
