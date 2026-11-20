(* What Esc and Ctrl-C do in the Keeper chat while a turn streams (RFC §3.4,
   #53273): Esc leaves the chat and stops nothing; Ctrl-C asks the server to
   stop the turn. The tables in Masc_tui_esc_interrupt are pinned by
   test_tui_esc_interrupt; these tests drive the two keys through the code the
   event loop calls, [Message_keymap.handle_message_key] for Esc and
   [Queue_steer.interrupt_active_chat_turn] for Ctrl-C.

   Outside an Eio switch the interrupt request is not sent: the launch posts
   its "switch is unavailable" result to the mailbox at once. A launch is
   therefore one message in the mailbox, and a press that launched nothing
   leaves the mailbox as it was. [interrupt_active_chat_turn] answering false
   is what sends the event loop on to arming quit. *)

open Alcotest

module T = Masc_tui_types
module Keeper_chat = Masc_tui_keeper_chat_projection
module Live = Masc_tui_keeper_chat_live
module Admission = Masc_tui_transport.Workspace_admission
module Queue_steer = Masc_tui_chat_dispatch.Queue_steer

let keeper = "alpha"

let streaming_turn () : T.inflight =
  let sent_request = Keeper_chat.create_request ~keeper_name:keeper ~message:"hello" () in
  let log = T.turn_log_create ~keeper_name:keeper ~request_id:sent_request.request_id ~started_at:1. in
  T.turn_log_add ~now:1. log ~seq:(Some 0) Live.Run_started;
  { T.sent_request; submitted_at = 1.; sent_at = 1.; control_generation = 0;
    phase = T.Turn_streaming; log }

let chat_state ~turns =
  let state = T.create_state ~workspace:"test" ~port:0 () in
  state.view <- T.Keepers T.Keeper_message;
  state.keeper_message_focus <- T.Right_pane;
  state.msg_target_keeper_name <- Some keeper;
  state.msg_inflight <- turns;
  state

let mailbox () : Admission.mailbox =
  { notifications = Eio.Stream.create 64;
    workspace_results = Masc_tui_workspace_result.create () }

let launched (mailbox : Admission.mailbox) = Eio.Stream.length mailbox.notifications

let ctrl_c state mailbox = Queue_steer.interrupt_active_chat_turn state ~mailbox

let esc state =
  Masc_tui_chat_input.Message_keymap.handle_message_key
    ~terminal_size:(fun () -> (30, 100)) ~wheel_notch_rows:3 state
    ~submit_message:(fun _ -> ()) ~load_older:(fun ~cursor:_ -> ())
    ~paste_image:(fun () -> ()) ~open_named_image:(fun () -> ())
    ~inspect_context:(fun () -> ()) ~inspect_queue:(fun () -> ())
    ~load_tool_changes:(fun () -> ()) ~load_preparation:(fun () -> ())
    ~drain_queue:(fun () -> ()) ~start_voice:(fun () -> ())
    ~toggle_voice_continuous:(fun () -> ()) "esc"

let test_esc_leaves_a_streaming_turn_running () =
  let turn = streaming_turn () in
  let state = chat_state ~turns:[turn] in
  check bool "Esc is handled" true (esc state);
  check bool "Esc leaves the chat" true (state.view <> T.Keepers T.Keeper_message);
  check bool "no stop was asked for" true (state.keeper_chat_control_pending = []);
  check bool "the turn still streams" true
    (Option.is_some (T.working_chat_for_keeper state keeper))

let test_first_ctrl_c_stops_the_turn () =
  let state = chat_state ~turns:[streaming_turn ()] in
  let mailbox = mailbox () in
  check bool "Ctrl-C is spent on the turn" true (ctrl_c state mailbox);
  check int "one stop request" 1 (launched mailbox);
  check bool "the stop is pending for the Keeper" true
    (List.mem_assoc keeper state.keeper_chat_control_pending);
  check bool "the chat stays open" true (state.view = T.Keepers T.Keeper_message)

let test_second_ctrl_c_inside_the_grace_is_swallowed () =
  let state = chat_state ~turns:[streaming_turn ()] in
  let mailbox = mailbox () in
  ignore (ctrl_c state mailbox : bool);
  check bool "the second press is spent too" true (ctrl_c state mailbox);
  check int "no second stop request" 1 (launched mailbox)

let test_ctrl_c_after_the_grace_goes_on_to_quit () =
  let state = chat_state ~turns:[streaming_turn ()] in
  let mailbox = mailbox () in
  ignore (ctrl_c state mailbox : bool);
  let past_grace =
    Int64.sub (Mtime_clock.elapsed_ns ()) (Int64.succ Masc_tui_esc_interrupt.grace_window_ns) in
  state.keeper_chat_control_pending <- [ (keeper, past_grace) ];
  check bool "the press is left for quit" false (ctrl_c state mailbox);
  check int "no second stop request" 1 (launched mailbox)

let test_ctrl_c_without_a_turn_goes_on_to_quit () =
  let state = chat_state ~turns:[] in
  let mailbox = mailbox () in
  check bool "the press is left for quit" false (ctrl_c state mailbox);
  check int "no stop request" 0 (launched mailbox);
  check bool "nothing pending" true (state.keeper_chat_control_pending = [])

let () =
  Eio_main.run @@ fun _ ->
  run "chat escape and interrupt keys"
    [ ( "keys",
        [ test_case "Esc leaves a streaming turn running" `Quick
            test_esc_leaves_a_streaming_turn_running;
          test_case "the first Ctrl-C stops the turn" `Quick test_first_ctrl_c_stops_the_turn;
          test_case "a second Ctrl-C inside the grace is swallowed" `Quick
            test_second_ctrl_c_inside_the_grace_is_swallowed;
          test_case "Ctrl-C after the grace goes on to quit" `Quick
            test_ctrl_c_after_the_grace_goes_on_to_quit;
          test_case "Ctrl-C without a turn goes on to quit" `Quick
            test_ctrl_c_without_a_turn_goes_on_to_quit ] ) ]
