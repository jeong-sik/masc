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
  Channel_gate_telegram_state.record_error "network unreachable";
  check int "the same error on the next attempt does not" 2 !notified;
  Channel_gate_telegram_state.record_error "HTTP 401";
  check int "another error does" 3 !notified;
  Channel_gate_telegram_state.record_poll_ok ~bot_user_id:7L ~next_offset:(Some 43L);
  check int "polling again announces" 4 !notified;
  Channel_gate_telegram_state.record_not_configured ();
  Channel_gate_telegram_state.record_not_configured ();
  check int "a missing token announces once" 5 !notified
;;

let test_imessage_polls_announce_only_a_state_change () =
  with_counter @@ fun notified ->
  Channel_gate_imessage_state.record_poll_error "chat.db locked";
  check int "a poll error announces" 1 !notified;
  Channel_gate_imessage_state.record_poll_error "chat.db locked";
  check int "the same error on the next poll does not" 1 !notified;
  Channel_gate_imessage_state.record_poll_ok ~cursor_rowid:10;
  check int "recovering announces" 2 !notified;
  Channel_gate_imessage_state.record_poll_ok ~cursor_rowid:11;
  check int "a moved cursor does not" 2 !notified;
  Channel_gate_imessage_state.record_startup_error "no Full Disk Access";
  Channel_gate_imessage_state.record_startup_error "no Full Disk Access";
  check int "a startup error announces once" 3 !notified;
  Channel_gate_imessage_state.clear_startup_error ();
  Channel_gate_imessage_state.clear_startup_error ();
  check int "clearing it announces once" 4 !notified
;;

(* Slack records the workspace id from every inbound message and ambient
   event; only a different id is a change. *)
let test_slack_workspace_id_announces_only_a_new_id () =
  with_counter @@ fun notified ->
  Channel_gate_slack_state.clear_workspace_id ();
  let before = !notified in
  Channel_gate_slack_state.record_workspace_id "T01";
  check int "a first id announces" (before + 1) !notified;
  Channel_gate_slack_state.record_workspace_id " T01 ";
  check int "the same id from the next message does not" (before + 1) !notified;
  Channel_gate_slack_state.record_workspace_id "T02";
  check int "another workspace does" (before + 2) !notified;
  Channel_gate_slack_state.record_workspace_id "";
  check int "a blank id records nothing" (before + 2) !notified
;;

let test_trigger_parameters_alone_are_connector_changes () =
  with_counter @@ fun notified ->
  Connector_trigger_params.announce_param_change
    ~key:(Runtime_params.key Connector_trigger_params.slack);
  Connector_trigger_params.announce_param_change
    ~key:(Runtime_params.key Connector_trigger_params.discord);
  check int "each trigger policy announces" 2 !notified;
  Connector_trigger_params.announce_param_change ~key:"keeper.turn_timeout_s";
  check int "another parameter does not" 2 !notified
;;

let () =
  run "gate_change_notify"
    [ ( "polls"
      , [ test_case "Telegram announces only a new bot" `Quick
            test_telegram_polls_announce_only_a_new_bot
        ; test_case "iMessage announces only a state change" `Quick
            test_imessage_polls_announce_only_a_state_change
        ; test_case "Slack announces only a new workspace id" `Quick
            test_slack_workspace_id_announces_only_a_new_id
        ; test_case "only trigger parameters are connector changes" `Quick
            test_trigger_parameters_alone_are_connector_changes
        ] )
    ]
;;
