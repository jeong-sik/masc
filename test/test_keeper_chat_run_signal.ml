open Alcotest
open Masc
module S = Keeper_chat_run_signal
module E = Keeper_chat_events

let details outcome reply : E.reply_details =
  {
    reply;
    turn_outcome = outcome;
    turn_ref = Ids.Turn_ref.make ~trace_id:"run-signal-fixture" ~absolute_turn:1;
    terminal_stream_scope = None;
  }

let reply_event = details Keeper_turn_outcome.Visible_reply "hello"

let signal =
  testable
    (fun ppf -> function
      | S.Closed -> Format.pp_print_string ppf "Closed"
      | S.Reply value -> Format.fprintf ppf "Reply %S" value.E.reply
      | S.Finished -> Format.pp_print_string ppf "Finished"
      | S.Failed message -> Format.fprintf ppf "Failed %S" message
      | S.Progress -> Format.pp_print_string ppf "Progress")
    ( = )

let test_classification () =
  let expect label expected event = check signal label expected (S.of_event event) in
  expect "reply details" (S.Reply reply_event) (E.Reply_details reply_event);
  expect "run finished" S.Finished (E.Run_finished { run_id = "r" });
  expect "event error" (S.Failed "boom") (E.Event_error { message = "boom" });
  List.iter
    (fun (label, event) -> expect label S.Progress event)
    [
      ("run started", E.Run_started { run_id = "r"; thread_id = "t" });
      ("text delta", E.Text_delta { text = "x"; response = E.Unobserved_scope None });
      ("text end", E.Text_message_end);
      ("stream ping", E.Agent_core_stream_ping);
      ("stream connected", E.Agent_core_stream_connected);
      ("continuation checkpoint", E.Continuation_checkpoint { message = "m"; request_id = None });
      ("image block", E.Image_block { url = "https://example.com/i.png"; caption = None });
    ]

let test_visible_text () =
  let text outcome reply = S.visible_text (details outcome reply) in
  check (option string) "visible reply" (Some "hello") (text Keeper_turn_outcome.Visible_reply "hello");
  check (option string) "blank visible reply" None (text Keeper_turn_outcome.Visible_reply " \n");
  check (option string) "empty visible reply" None (text Keeper_turn_outcome.Visible_reply "");
  List.iter
    (fun (label, outcome) -> check (option string) label None (text outcome "hello"))
    [
      ("continuation checkpoint", Keeper_turn_outcome.Continuation_checkpoint);
      ("terminal effect settled", Keeper_turn_outcome.Terminal_effect_settled);
      ("awaiting gate approval", Keeper_turn_outcome.Awaiting_gate_approval);
      ("no visible reply", Keeper_turn_outcome.No_visible_reply);
    ]

let test_read () =
  Eio_main.run (fun _ ->
      let bus = E.create () in
      E.publish bus E.Text_message_end;
      E.publish bus (E.Reply_details reply_event);
      E.publish bus (E.Run_finished { run_id = "r" });
      E.publish bus (E.Event_error { message = "late" });
      E.close bus;
      List.iter
        (fun (label, expected) -> check signal label expected (S.read bus))
        [
          ("progress first", S.Progress);
          ("reply", S.Reply reply_event);
          ("finished", S.Finished);
          ("error", S.Failed "late");
          ("closed", S.Closed);
          ("closed stays closed", S.Closed);
        ])

let () =
  run "Keeper chat run signal"
    [
      ( "signal",
        [
          test_case "classification" `Quick test_classification;
          test_case "read" `Quick test_read;
          test_case "visible text" `Quick test_visible_text;
        ] );
    ]
